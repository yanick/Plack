package HTTP::Message::PSGI;
use strict;
use warnings;
use parent qw(Exporter);
our @EXPORT = qw( req_to_psgi res_from_psgi );

use Carp ();
use URI::Escape ();
use Plack::Util;
use Try::Tiny;

my $TRUE  = (1 == 1);
my $FALSE = !$TRUE;

sub req_to_psgi {
    my $req = shift;

    unless (try { $req->isa('HTTP::Request') }) {
        Carp::croak("Request is not HTTP::Request: $req");
    }

    # from HTTP::Request::AsCGI
    my $host = $req->header('Host');
    my $uri  = $req->uri->clone;
    $uri->scheme('http')    unless $uri->scheme;
    $uri->host('localhost') unless $uri->host;
    $uri->port(80)          unless $uri->port;
    $uri->host_port($host)  unless !$host || ( $host eq $uri->host_port );

    # STUPID: If the request URI is utf-8 decoded, methods like ->path
    # and ->host returns decoded strings in ascii, which causes double
    # encoded strings in uri_unescape and URI concatenation in
    # Plack::Request :/
    utf8::downgrade $$uri;

    open my $input, "<", \do { $req->content };

    my $env = {
        PATH_INFO         => URI::Escape::uri_unescape($uri->path),
        QUERY_STRING      => $uri->query || '',
        SCRIPT_NAME       => '',
        SERVER_NAME       => $uri->host,
        SERVER_PORT       => $uri->port,
        SERVER_PROTOCOL   => $req->protocol || 'HTTP/1.1',
        REMOTE_ADDR       => '127.0.0.1',
        REMOTE_HOST       => 'localhost',
        REMOTE_PORT       => int( rand(64000) + 1000 ),                   # not in RFC 3875
        REQUEST_URI       => $uri->path_query,                            # not in RFC 3875
        REQUEST_METHOD    => $req->method,
        'psgi.version'      => [ 1, 1 ],
        'psgi.url_scheme'   => $uri->scheme eq 'https' ? 'https' : 'http',
        'psgi.input'        => $input,
        'psgi.errors'       => *STDERR,
        'psgi.multithread'  => $FALSE,
        'psgi.multiprocess' => $FALSE,
        'psgi.run_once'     => $TRUE,
        'psgi.streaming'    => $TRUE,
        'psgi.nonblocking'  => $FALSE,
        @_,
    };

    for my $field ( $req->headers->header_field_names ) {
        my $key = uc("HTTP_$field");
        $key =~ tr/-/_/;
        $key =~ s/^HTTP_// if $field =~ /^Content-(Length|Type)$/;

        unless ( exists $env->{$key} ) {
            $env->{$key} = $req->headers->header($field);
        }
    }

    if ($env->{SCRIPT_NAME}) {
        $env->{PATH_INFO} =~ s/^\Q$env->{SCRIPT_NAME}\E/\//;
        $env->{PATH_INFO} =~ s/^\/+/\//;
    }

    return $env;
}

sub res_from_psgi {
    my ($psgi_res) = @_;

    my $res;
    if (ref $psgi_res eq 'ARRAY') {
        _res_from_psgi($psgi_res, \$res);
    }
    elsif (ref $psgi_res eq 'CODE') {
        $psgi_res->(sub {
            _res_from_psgi($_[0], \$res);
        });
    }

    return $res;
}

sub _res_from_psgi {
    my ($status, $headers, $body) = @{+shift};
    my $res_ref = shift;

    my $convert_resp = sub {
        my $res = HTTP::Response->new($status);
        $res->headers->header(@$headers) if @$headers;

        if (ref $body eq 'ARRAY') {
            $res->content(join '', @$body);
        } else {
            local $/ = \4096;
            my $content;
            while (defined(my $buf = $body->getline)) {
                $content .= $buf;
            }
            $body->close;
            $res->content($content);
        }

        ${ $res_ref } = $res;

        return;
    };

    if (!defined $body) {
        my $o = Plack::Util::inline_object
            write => sub { push @{ $body ||= [] }, @_ },
            close => $convert_resp;

        return $o;
    }

    $convert_resp->();
}

sub HTTP::Request::to_psgi {
    req_to_psgi(@_);
}

sub HTTP::Response::from_psgi {
    my $class = shift;
    res_from_psgi(@_);
}

1;

__END__

=head1 NAME

HTTP::Message::PSGI - Converts HTTP::Request and HTTP::Response from/to PSGI env and response

=head1 SYNOPSIS

  use HTTP::Message::PSGI;

  # $req is HTTP::Request, $res is HTTP::Response
  my $env = req_to_psgi($req);
  my $res = res_from_psgi([ $status, $headers, $body ]);

  # Adds methods to HTTP::Request/Response class as well
  my $env = $req->to_psgi;
  my $res = HTTP::Response->from_psgi([ $status, $headers, $body ]);

=head1 DESCRIPTION

HTTP::Message::PSGI gives you convenient methods convert HTTP::Request
object to PSGI env hash and convert PSGI response array ref to
HTTP::Response object.

If you want the other way round, see L<Plack::Request> and
L<Plack::Response>.

=head1 METHODS

=over 4

=item req_to_psgi

  my $env = req_to_psgi($req [, $key => $val ... ]);

Converts HTTP::Request object into PSGI env hash reference.

=item HTTP::Request::to_psgi

  my $env = $req->to_psgi;

Same as C<req_to_psgi> but an instance method in L<HTTP::Request>.

=item res_from_psgi

  my $res = res_from_psgi([ $status, $headers, $body ]);

Creates HTTP::Response object from PSGI response array ref.

=item HTTP::Response->from_psgi

  my $res = HTTP::Response->from_psgi([ $status, $headers, $body ]);

Same as C<res_from_psgi> but a class method in L<HTTP::Response>.

=back

=head1 AUTHOR

Tatsuhiko Miyagawa

=head1 SEE ALSO

L<HTTP::Request::AsCGI> L<HTTP::Message> L<Plack::Test>

=cut

