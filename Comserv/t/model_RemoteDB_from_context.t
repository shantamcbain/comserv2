#!/usr/bin/env perl
# Regression for error todo #2343:
# $c->model('RemoteDB') returns the bare class-name string (NOT a ref) because
# Comserv::Model::RemoteDB is plain Moose, not Catalyst::Model. Moose accessors
# then die with "Can't use string (...) as a HASH ref". from_context() must always
# return a real object. Also covers SCPG-REMOTEDB postgresql acceptance.

use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

BEGIN { use_ok('Comserv::Model::RemoteDB'); }

# Fake context whose model() returns the class-name string (Catalyst behaviour)
{
    package t::FakeC;
    sub new { bless {}, shift }
    sub model { return 'Comserv::Model::RemoteDB' }
}

subtest 'class-name string crashes Moose config accessor' => sub {
    plan tests => 1;
    eval { my $x = 'Comserv::Model::RemoteDB'->config };
    like($@, qr/HASH ref/, 'bare class-name ->config dies (the #2343 failure mode)');
};

subtest 'from_context always returns a real object' => sub {
    plan tests => 3;
    my $obj = Comserv::Model::RemoteDB->from_context(t::FakeC->new);
    ok(ref $obj, 'from_context returns a reference');
    isa_ok($obj, 'Comserv::Model::RemoteDB');
    eval { my $c = $obj->config };
    ok(!$@, 'object->config does not die');
};

subtest 'controller _remote_db uses from_context' => sub {
    plan tests => 2;
    require Comserv::Controller::RemoteDB;
    my $ctl = Comserv::Controller::RemoteDB->new;
    my $rdb = $ctl->_remote_db(t::FakeC->new);
    ok(ref $rdb, '_remote_db returns a reference');
    my $conns = eval { $rdb->get_all_connections() };
    ok(!$@ && ref($conns) eq 'HASH', 'get_all_connections works (index path)');
};

subtest 'select_connection accepts postgresql db_type' => sub {
    plan tests => 2;
    my $obj = Comserv::Model::RemoteDB->new;
    $obj->_load_config();
    my $all = $obj->get_all_connections();
    my @pg = grep { ($all->{$_}{db_type} // '') =~ /postgres/i } keys %$all;
    ok(@pg >= 1, 'at least one postgresql slot in secrets')
        or diag('keys: ' . join(', ', sort keys %$all));

    # Must not die with "Invalid db_type" for postgresql
    eval { $obj->get_connection_info('csc') };
    my $err = $@ // '';
    unlike($err, qr/Invalid db_type/, 'postgresql not rejected as Invalid db_type')
        or diag("err=$err");
};

done_testing();
