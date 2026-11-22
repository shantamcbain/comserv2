#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Comserv::Util::FocusRanking;

# Shared todo fixtures
my $others_general = {
    record_id => 10, role_cats => 'general', sitename => 'CSC',
    developer => 'Shanta', username_of_poster => 'Shanta',
};
my $others_dev = {
    record_id => 11, role_cats => 'developer', sitename => 'CSC',
    developer => 'Shanta', username_of_poster => 'Shanta',
};
my $others_admin = {
    record_id => 12, role_cats => 'admin', sitename => 'CSC',
    developer => 'Shanta', username_of_poster => 'Shanta',
};
my $mine_general = {
    record_id => 13, role_cats => 'general', sitename => 'CSC',
    developer => 'pat', username_of_poster => 'pat',
};

sub ctx {
    my (%e) = @_;
    return {
        role_filtered => 1,
        is_csc_admin  => 0,
        sitename      => 'CSC',
        site_filtered => 1,
        checked_sites => { CSC => 1 },
        %e,
    };
}

# CSC admin still sees the owner-scale list.
ok(Comserv::Util::FocusRanking::passes_filters($others_dev, { is_csc_admin => 1 }),
    'csc admin sees programming todos');
ok(Comserv::Util::FocusRanking::passes_filters($others_admin, { is_csc_admin => 1, role_filtered => 0 }),
    'csc admin sees helpdesk/admin todos');

# Members / normal must not see the owner-scale dump.
my $member = ctx(viewer_username => 'pat', viewer_roles => { member => 1, user => 1 });
ok(!Comserv::Util::FocusRanking::passes_filters($others_general, $member),
    'member does not see someone else\'s general todo');
ok(!Comserv::Util::FocusRanking::passes_filters($others_dev, $member),
    'member does not see someone else\'s developer todo');
ok(Comserv::Util::FocusRanking::passes_filters($mine_general, $member),
    'member sees their own todo');

my $normal = ctx(viewer_username => 'pat', viewer_roles => { normal => 1 });
ok(!Comserv::Util::FocusRanking::passes_filters($others_general, $normal),
    'normal role does not see owner-scale general dump');
ok(Comserv::Util::FocusRanking::passes_filters($mine_general, $normal),
    'normal role sees own todo');

# Developers: programming-only (developer role_cats) or own, not ops/admin dump.
my $dev = ctx(viewer_username => 'dev1', viewer_roles => { developer => 1 });
ok(Comserv::Util::FocusRanking::passes_filters($others_dev, $dev),
    'developer sees programming todos');
ok(!Comserv::Util::FocusRanking::passes_filters($others_admin, $dev),
    'developer does not see helpdesk/admin-classified todos');
ok(!Comserv::Util::FocusRanking::passes_filters($others_general, $dev),
    'developer does not see unclassified general dump');
ok(Comserv::Util::FocusRanking::passes_filters(
    { record_id => 14, role_cats => 'general', sitename => 'CSC', developer => 'dev1' },
    $dev
), 'developer sees their own general todo');

# HelpDesk staff: admin-classified or own, not the full programming dump.
my $staff = ctx(viewer_username => 'helpdesksupport', viewer_roles => { helpdesksupport => 1 });
ok(Comserv::Util::FocusRanking::passes_filters($others_admin, $staff),
    'helpdesk staff sees admin/helpdesk-classified todos');
ok(!Comserv::Util::FocusRanking::passes_filters($others_dev, $staff),
    'helpdesk staff does not see the programming dump');
ok(!Comserv::Util::FocusRanking::passes_filters($others_general, $staff),
    'helpdesk staff does not see owner-scale general dump');

is(Comserv::Util::FocusRanking::viewer_kind({ is_csc_admin => 1 }), 'csc_admin', 'viewer_kind csc_admin');
is(Comserv::Util::FocusRanking::viewer_kind({ viewer_roles => { helpdesksupport => 1 } }), 'staff', 'viewer_kind staff');
is(Comserv::Util::FocusRanking::viewer_kind({ viewer_roles => { developer => 1 } }), 'developer', 'viewer_kind developer');
is(Comserv::Util::FocusRanking::viewer_kind({ viewer_roles => { member => 1 } }), 'member', 'viewer_kind member');


# Calendar stash leftover (CSC-20260915-9174): attrs_from_todo + Planning helper
# so /planning/daily `todos` uses the same own-only ACL as the Focus queue.
{
    package t::FakeTodoRow;
    sub new { my ($class, %h) = @_; bless { %h }, $class }
    sub get_columns { my ($self) = @_; return %$self }
}

{
    package t::FakeC;
    sub new { my ($class, %h) = @_; bless { %h }, $class }
    sub session { $_[0]{session} ||= {} }
    sub stash   { $_[0]{stash}   ||= {} }
}

my $cal_own = t::FakeTodoRow->new(
    record_id => 21, sitename => 'CSC', subject => 'My calendar item',
    developer => 'pat', role_cats => 'general',
);
my $cal_other = t::FakeTodoRow->new(
    record_id => 22, sitename => 'CSC', subject => 'Ops dump',
    developer => 'admin', role_cats => 'general',
);
my $cal_attrs = Comserv::Util::FocusRanking::attrs_from_todo($cal_own);
is($cal_attrs->{developer}, 'pat', 'attrs_from_todo reads get_columns');
ok(Comserv::Util::FocusRanking::passes_filters($cal_attrs, $member),
    'calendar row of own todo is visible to member');
ok(!Comserv::Util::FocusRanking::passes_filters(
        Comserv::Util::FocusRanking::attrs_from_todo($cal_other), $member),
    'calendar row of someone else is hidden from member');

require Comserv::Controller::Planning;
my $ctl = bless {}, 'Comserv::Controller::Planning';
my $cal_c = t::FakeC->new(
    session => { username => 'pat', roles => ['member'] },
    stash   => { user_roles => ['member'], SiteName => 'CSC' },
);
my $filtered = $ctl->_filter_calendar_todos($cal_c, [$cal_own, $cal_other], 0, ['CSC']);
is(scalar @$filtered, 1, 'calendar helper keeps only own todo for member');
is($filtered->[0]{record_id}, 21, 'calendar helper kept the member\'s own row');

my $staff_c = t::FakeC->new(
    session => { username => 'helpdesksupport', roles => ['helpdesksupport'] },
    stash   => { user_roles => ['helpdesksupport'], SiteName => 'CSC' },
);
my $cal_admin = t::FakeTodoRow->new(
    record_id => 23, sitename => 'CSC', subject => 'HD queue',
    developer => 'other', role_cats => 'admin',
);
my $staff_filtered = $ctl->_filter_calendar_todos(
    $staff_c, [$cal_own, $cal_other, $cal_admin], 0, ['CSC']
);
is(scalar @$staff_filtered, 1, 'helpdesk calendar is not an owner-scale dump');
is($staff_filtered->[0]{record_id}, 23, 'helpdesk calendar keeps admin-classified todo');

my $admin_filtered = $ctl->_filter_calendar_todos(
    $cal_c, [$cal_own, $cal_other], 1, ['CSC']
);
is(scalar @$admin_filtered, 2, 'csc admin calendar bypasses own-only filter');


done_testing();
