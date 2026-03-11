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
    my $submitted = $c->req->body_parameters->{csrf_token}
                 || $c->req->param('csrf_token')
                 || '';
    my $expected  = $c->session->{csrf_token} || '';

    $c->log->info("CSRF VALIDATION: Submitted='$submitted', Expected='$expected'") if $c->can('log');

    return 0 unless $submitted && $expected;
    return ($submitted eq $expected) ? 1 : 0;
}

1;
