#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

BEGIN {
    use_ok('Comserv::Controller::Root')
        or BAIL_OUT('Failed to load Root controller');
}

ok(!Comserv::Controller::Root::_is_shared_host('3d.usbm.ca'), 'public domain is not shared');
ok(Comserv::Controller::Root::_is_shared_host('workstation.local'), 'workstation.local is shared');
ok(Comserv::Controller::Root::_is_shared_host('dev.computersystemconsulting.ca'), 'dev.computersystemconsulting.ca is shared');
ok(Comserv::Controller::Root::_is_shared_host('127.0.0.1'), 'loopback IP is shared');
ok(Comserv::Controller::Root::_is_shared_host('printer.zero'), '*.zero is shared');

{
    package MockLog;
    sub new { bless {}, shift }
    sub log_with_details { }
}

{
    package MockSiteRow;
    sub new { my ($class, %a) = @_; bless \%a, $class }
    sub site_id { $_[0]->{site_id} }
    sub name { $_[0]->{name} }
    sub home_view { $_[0]->{home_view} // '' }
    sub get_columns { %{ $_[0] } }
}

{
    package MockSite;
    sub new { bless $_[1], shift }
    sub get_site_details_by_name {
        my ($self, $c, $name) = @_;
        return undef unless defined $name && $self->{valid}{lc $name};
        return MockSiteRow->new(name => $self->{valid}{lc $name});
    }
    sub get_site_domain {
        my ($self, $c, $host) = @_;
        $host = lc($host // '');
        my $id = $self->{domains}{$host} or return undef;
        return MockSiteRow->new(site_id => $id);
    }
    sub get_site_details {
        my ($self, $c, $id) = @_;
        my $name = $self->{sites}{$id} or return undef;
        return MockSiteRow->new(name => $name, home_view => 'SiteHome');
    }
    sub get_default_site { return undef }
}

{
    package MockURI;
    sub new { my ($class, $host) = @_; bless { host => $host }, $class }
    sub host { $_[0]->{host} }
}

{
    package MockReq;
    sub new { bless $_[1], shift }
    sub query_parameters { $_[0]->{qp} }
    sub header {
        my ($self, $name) = @_;
        return $self->{headers}{$name};
    }
    sub uri { $_[0]->{uri} }
}

{
    package MockDBH;
    sub new { bless $_[1] // {}, shift }
    sub selectrow_array { return $_[0]->{ok} ? 1 : undef }
}

{
    package MockStorage;
    sub new { bless $_[1] // {}, shift }
    sub dbh { $_[0]->{dbh} }
}

{
    package MockDB;
    sub new { bless $_[1] // {}, shift }
    sub storage { $_[0]->{storage} }
}

{
    package MockC;
    sub new { bless $_[1], shift }
    sub req { $_[0]->{req} }
    sub session { $_[0]->{session} }
    sub stash { $_[0]->{stash} }
    sub model { $_[0]->{models}{$_[1]} }
    sub controller { return undef }
}

my $ctrl = Comserv::Controller::Root->new(logging => MockLog->new);
ok($ctrl, 'Root controller instantiated');

sub _site_model {
    return MockSite->new({
        valid => { shanta => 'Shanta', '3d' => '3d', forager => 'Forager', csc => 'CSC' },
        domains => {
            '3d.usbm.ca' => 9,
            'workstation.local' => 1,
        },
        sites => { 9 => '3d', 1 => 'CSC' },
    });
}

sub _ctx {
    my (%args) = @_;
    my $session = {
        user_id => 7,
        username => 'Shanta',
        SiteName => 'Shanta',
        site_locked => 1,
        is_csc_admin => $args{admin} ? 1 : 0,
    };
    my $req = MockReq->new({
        qp => $args{param} ? { SiteName => $args{param} } : {},
        headers => {},
        uri => MockURI->new($args{host}),
    });
    return MockC->new({
        req => $req,
        session => $session,
        stash => {},
        models => {
            Site => _site_model(),
            DBEncy => MockDB->new({
                storage => MockStorage->new({ dbh => MockDBH->new({ ok => 1 }) }),
            }),
        },
    });
}

subtest 'specific host plus locked session: host wins' => sub {
    my $c = _ctx(host => '3d.usbm.ca');
    my $name = $ctrl->fetch_and_set($c, 'SiteName');
    is($name, '3d', 'returned site is the host site');
    is($c->stash->{SiteName}, '3d', 'stash is the host site');
    is($c->session->{SiteName}, '3d', 'locked session SiteName is overwritten');
};

subtest 'shared host plus locked session: lock wins' => sub {
    my $c = _ctx(host => 'workstation.local');
    $ctrl->fetch_and_set($c, 'SiteName');
    is($c->stash->{SiteName}, 'Shanta', 'stash keeps the lock');
    is($c->session->{SiteName}, 'Shanta', 'session is not replaced by CSC');
};

subtest '?SiteName on a specific host: the param wins' => sub {
    my $c = _ctx(host => '3d.usbm.ca', param => 'Forager');
    my $name = $ctrl->fetch_and_set($c, 'SiteName');
    is($name, 'Forager', 'explicit SiteName beats the host');
    is($c->stash->{SiteName}, 'Forager', 'stash is the param');
    is($c->session->{SiteName}, 'Forager', 'session follows the param');
};

subtest 'admin on a specific host: host wins' => sub {
    my $c = _ctx(host => '3d.usbm.ca', admin => 1);
    my $name = $ctrl->fetch_and_set($c, 'SiteName');
    is($name, '3d', 'admin lock does not beat a specific host');
    is($c->stash->{SiteName}, '3d', 'stash is the host site');
    is($c->session->{SiteName}, '3d', 'admin session SiteName is overwritten');
};

done_testing;
