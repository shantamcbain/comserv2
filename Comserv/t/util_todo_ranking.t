#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use POSIX ();
use FindBin;
use lib "$FindBin::Bin/../lib";

use Comserv::Util::TodoRanking;
use Comserv::Util::FocusRanking;

my $now = time();

sub score {
    my (%h) = @_;
    Comserv::Util::TodoRanking::score_todo(\%h, { now_epoch => $now });
    return \%h;
}

{
    my $schema = score(
        subject => 'Design new schema',
        priority => 1,
        status => 1,
        last_mod_by => 'reschedule',
        last_mod_date => '2026-08-18',
        date_time_posted => '2026-05-01',
    );
    ok($schema->{p1_dampened}, 'inflated P1 is dampened');
    is($schema->{rank_priority}, 5, 'inflated P1 scores as planned backlog');
}

{
    my $err = score(
        subject => "[Error] git_merge merge of 'planning' failed (conflict): Auto-merging",
        priority => 2,
        status => 1,
        last_mod_date => POSIX::strftime('%Y-%m-%d', localtime($now)),
        date_time_posted => POSIX::strftime('%Y-%m-%d', localtime($now)),
    );
    ok(!$err->{p1_dampened}, 'recent error is not dampened');
    ok(($err->{incident_bonus} // 0) < 0, 'recent incident gets a boost');
}

{
    my $outage = score(
        subject => 'deploy.sh monitor recovery removes container and cannot restore it',
        description => 'Outage 2026-08-07. container removed, port 5000 dead',
        priority => 1,
        status => 2,
        last_mod_date => POSIX::strftime('%Y-%m-%d', localtime($now)),
    );
    ok(!$outage->{p1_dampened}, 'cannot-restore outage keeps P1');
    is($outage->{rank_priority}, 1, 'real blocker rank_priority stays 1');
}

{
    my $noise = score(
        subject => 'Design new schema',
        priority => 1,
        status => 1,
        last_mod_by => 'reschedule',
        last_mod_date => POSIX::strftime('%Y-%m-%d', localtime($now)),
        date_time_posted => '2026-05-01',
    );
    my $live = score(
        subject => "[Error] git checkout main -> exit=128",
        priority => 2,
        status => 2,
        last_mod_date => POSIX::strftime('%Y-%m-%d', localtime($now)),
        date_time_posted => POSIX::strftime('%Y-%m-%d', localtime($now)),
    );
    ok($live->{ap_score} < $noise->{ap_score}, 'live error outranks inflated P1');
}

{
    my $ok = Comserv::Util::FocusRanking::passes_filters(
        { project_id => 273, parent_id => 272, role_cats => 'general', sitename => 'CSC' },
        { proj_filtered => 1, checked_projects => { 272 => 1 }, is_csc_admin => 1 },
    );
    ok($ok, 'filter on parent project includes phase child');
    my $no = Comserv::Util::FocusRanking::passes_filters(
        { project_id => 273, parent_id => 272, role_cats => 'general', sitename => 'CSC' },
        { proj_filtered => 1, checked_projects => { 999 => 1 }, is_csc_admin => 1 },
    );
    ok(!$no, 'unrelated project filter excludes the child');
}

{
    my $scope = {
        branch_project_ids     => { 138 => 1, 234 => 1 },
        blocked_by_ids         => { 99 => 1 },
        cross_blocker_projects => { 201 => [138] },
    };
    ok(Comserv::Util::FocusRanking::in_branch_scope(
        { record_id => 1, project_id => 138 }, $scope
    ), 'branch project todo is in scope');
    ok(Comserv::Util::FocusRanking::in_branch_scope(
        { record_id => 2, project_id => 234 }, $scope
    ), 'phase child of branch project is in scope');
    ok(!Comserv::Util::FocusRanking::in_branch_scope(
        { record_id => 3, project_id => 272 }, $scope
    ), 'unrelated project todo is out of scope');
    ok(Comserv::Util::FocusRanking::in_branch_scope(
        { record_id => 99, project_id => 201 }, $scope
    ), 'todo that blocks a branch todo is in scope');
    ok(Comserv::Util::FocusRanking::in_branch_scope(
        { record_id => 4, project_id => 201, is_blocking => 1, is_cross_blocker => 1 },
        $scope
    ), 'cross-project blocker of the branch project is in scope');
    ok(!Comserv::Util::FocusRanking::in_branch_scope(
        { record_id => 5, project_id => 201, is_blocking => 1, is_cross_blocker => 1 },
        { branch_project_ids => { 138 => 1 }, cross_blocker_projects => { 201 => [999] } }
    ), 'blocker of a different project is out of scope');
    ok(!Comserv::Util::FocusRanking::in_branch_scope(
        { record_id => 6, project_id => 138 }, { branch_project_ids => {} }
    ), 'empty scope matches nothing');
    ok(Comserv::Util::FocusRanking::in_branch_scope(
        { record_id => 7, project_id => 999, status => '5', in_progress => 1 },
        { branch_project_ids => { 138 => 1 }, keep_active => 1 }
    ), 'active todo from another branch is kept as a safeguard');
    ok(!Comserv::Util::FocusRanking::in_branch_scope(
        { record_id => 8, project_id => 999, status => '1' },
        { branch_project_ids => { 138 => 1 }, keep_active => 1 }
    ), 'idle todo from another branch is still excluded');
}

{
    use Comserv::Util::TodoTypes qw(is_calendar_fixture);
    ok(is_calendar_fixture({ subject => "\x{1F957} Lunch", todo_type => 'task' }), 'emoji lunch is a fixture');
    ok(is_calendar_fixture({ subject => 'Morning Break', is_fixed => 1 }), 'morning break is a fixture');
    ok(is_calendar_fixture({ subject => 'Dentist', todo_type => 'appointment' }), 'appointment type is a fixture');
    ok(!is_calendar_fixture({ subject => 'Fix merge conflict', todo_type => 'task' }), 'real work is not a fixture');
}

{
    ok(Comserv::Util::FocusRanking::is_active_work({ status => '5' }), 'status 5 is Active');
    ok(!Comserv::Util::FocusRanking::is_active_work({ status => '2', in_progress => 1 }), 'in-progress 2 is not Active');
    ok(Comserv::Util::FocusRanking::todo_matches_branch(
        { project_id => 280, project_code => 'AISYSTEM' }, 'aisystem', {}
    ), 'aisystem matches AISYSTEM code');
    ok(Comserv::Util::FocusRanking::todo_matches_branch(
        { project_id => 272, project_code => 'DRYER-INT' }, '3d', { 272 => 1 }
    ), '3d matches dryer project id');
    ok(Comserv::Util::FocusRanking::todo_matches_branch(
        { project_id => 138, project_code => 'PLANNING' }, 'planning', {}
    ), 'planning matches PLANNING code');
    ok(!Comserv::Util::FocusRanking::todo_matches_branch(
        { project_id => 272, project_code => 'DRYER-INT' }, 'planning', { 138 => 1 }
    ), 'dryer is not a planning todo');

    my $ctx = { branch => 'planning', branch_project_ids => { 138 => 1 } };
    my $active = { status => '5', project_id => 999, ap_score => 50, priority => 5 };
    my $plan   = { status => '1', project_id => 138, project_code => 'PLANNING', ap_score => 10, priority => 2 };
    my $other  = { status => '1', project_id => 272, project_code => 'DRYER-INT', ap_score => 1, priority => 1 };
    ok(Comserv::Util::FocusRanking::cmp_branch_focus($active, $plan, $ctx) < 0, 'Active ranks above branch work');
    ok(Comserv::Util::FocusRanking::cmp_branch_focus($plan, $other, $ctx) < 0, 'planning ranks above 3d on planning branch');
}

done_testing();
