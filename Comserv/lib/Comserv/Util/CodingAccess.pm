package Comserv::Util::CodingAccess;
use strict;
use warnings;

# Shanta-only coding terminal / HTTP CLI on the dev workstation.
sub workstation_allowed {
    my ($c) = @_;
    my $username = $c->session->{username} || ($c->user ? $c->user->username : '') || '';
    return 0 unless lc($username) eq 'shanta';
    my $req = $c->can('req') ? $c->req : $c->request;
    my $host = lc(($req && $req->uri ? $req->uri->host : '') || '');
    $host =~ s/:\d+\z//;
    return 1 if $host eq '172.30.131.126';
    return 1 if $host =~ /^(127\.0\.0\.1|localhost|workstation\.local|workstation\.zero)$/;
    return 0;
}

1;