package Comserv::Util::PublicCache;

use strict;
use warnings;

=head1 NAME

Comserv::Util::PublicCache - keep anonymous public GETs cache-safe

=head1 DESCRIPTION

Cloudflare cache rules (see L<Comserv::Util::CloudflareCache>) cache anonymous
GETs for the public path prefixes below. A cached response that carries a
C<Set-Cookie> header would hand one visitor's session to the next, so for those
requests the application must not create or send a session cookie.

C<is_public_anonymous_get> is the single decision used by the C<finalize_cookies>
and C<finalize_session> hooks in L<Comserv>. It is true only when ALL hold:

  * request is GET or HEAD
  * path is under a public prefix (ENCY, marketplace, membership, faq,
    newsletters, jobs, workshop, page) and not an add/edit/delete/login path
  * the browser sent no cookie whose name starts with C<comserv_session>
  * the request is not a dev-preview request (C<_dvpt>)
  * the response is 200 with no error and no action opted out via
    C<< $c->stash->{no_public_cache} >>

Logged-in users always send the session cookie, so they are never affected.

=cut

our @PREFIXES = qw(ENCY marketplace membership faq newsletters jobs workshop page);
our $CACHE_CONTROL = 'public, max-age=3600';

sub _prefix_match {
    my ($path) = @_;
    $path = '' unless defined $path;
    $path =~ s{^/+}{};
    return 0 if $path =~ m{(?:^|/)(?:add|edit|delete|remove|login|logout|save|update|create)(?:[_/.-]|$)}i;
    for my $p (@PREFIXES) {
        return 1 if $p eq 'ENCY' ? $path =~ m{^ENCY/} : $path =~ m{^\Q$p\E};
    }
    return 0;
}

# Pure request-side test (no response state): usable before the response exists.
sub request_is_public_anonymous_get {
    my ($c) = @_;
    my $req = $c->req;
    return 0 unless $req->method =~ /^(?:GET|HEAD)$/;
    return 0 unless _prefix_match($req->path);
    my $cookies = $req->cookies || {};
    return 0 if grep { /^comserv_session/ } keys %$cookies;
    my $hdr = $req->header('Cookie');
    return 0 if defined $hdr && $hdr =~ /comserv_session/;
    my $params = eval { $req->query_parameters } || {};
    return 0 if exists $params->{_dvpt};
    return 1;
}

sub is_public_anonymous_get {
    my ($c) = @_;
    return 0 unless request_is_public_anonymous_get($c);
    return 0 if $c->stash && $c->stash->{no_public_cache};
    my $errors = $c->error;
    return 0 if ref $errors eq 'ARRAY' && @$errors;
    return 0 unless ($c->res->status || 200) == 200;
    return 1;
}

# Remove the session cookie from the response and mark it publicly cacheable.
sub apply {
    my ($c) = @_;
    return 0 unless is_public_anonymous_get($c);
    my $cookies = $c->res->cookies;
    delete $cookies->{$_} for grep { /^comserv_session/ } keys %$cookies;
    $c->res->headers->remove_header('Set-Cookie');
    $c->res->headers->header('Cache-Control' => $CACHE_CONTROL);
    return 1;
}

1;
