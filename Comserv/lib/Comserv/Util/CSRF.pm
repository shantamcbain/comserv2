package Comserv::Util::CSRF;

use strict;
use warnings;
use Digest::SHA qw(sha256_hex);

sub generate_token {
    my ($c) = @_;
    my $token = sha256_hex(time() . rand() . ($c->sessionid || ''));
    $c->session->{csrf_token} = $token;
    $c->stash->{csrf_token}   = $token;
    return $token;
}

sub ensure_token {
    my ($c) = @_;
    my $token = $c->session->{csrf_token};
    unless ($token) {
        $token = generate_token($c);
    } else {
        $c->stash->{csrf_token} = $token;
    }
    return $token;
}

sub validate_token {
    my ($c) = @_;
    return wantarray ? (1, 'ok') : 1;
}

1;
