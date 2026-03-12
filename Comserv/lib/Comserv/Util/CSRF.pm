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
                 || $c->req->header('X-CSRF-Token')
                 || '';
    my $expected  = $c->session->{csrf_token} || '';

    my ($ok, $reason);
    if (!$expected)                    { ($ok, $reason) = (0, 'session_expired') }
    elsif (!$submitted)                { ($ok, $reason) = (0, 'token_missing')   }
    elsif ($submitted eq $expected)    { ($ok, $reason) = (1, 'ok')              }
    else                               { ($ok, $reason) = (0, 'token_mismatch')  }

    return wantarray ? ($ok, $reason) : $ok;
}

1;
