use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

BEGIN {
    use_ok('Comserv::Util::ProjectDependencies')
        or BAIL_OUT('Failed to load Comserv::Util::ProjectDependencies');
}

subtest 'is_audit_panel_todo excludes error and audit items' => sub {
    ok Comserv::Util::ProjectDependencies::is_audit_panel_todo('[Error] Controller::Todo::modify', undef),
        '[Error] subject excluded';
    ok Comserv::Util::ProjectDependencies::is_audit_panel_todo('Morning Audit scan', undef),
        'Morning Audit excluded';
    ok Comserv::Util::ProjectDependencies::is_audit_panel_todo('Fix login bug', 42),
        'child todo excluded';
    ok !Comserv::Util::ProjectDependencies::is_audit_panel_todo('Ship feature X', undef),
        'normal todo included';
};

subtest 'todo_is_done recognises numeric and string statuses' => sub {
    {
        package MockTodo;
        sub new { my ($class, $status) = @_; bless { status => $status }, $class }
        sub status { $_[0]->{status} }
    }
    ok Comserv::Util::ProjectDependencies::todo_is_done(MockTodo->new(3)),
        'status 3 is done';
    ok Comserv::Util::ProjectDependencies::todo_is_done(MockTodo->new('completed')),
        'completed string is done';
    ok !Comserv::Util::ProjectDependencies::todo_is_done(MockTodo->new(1)),
        'status 1 is open';
    ok !Comserv::Util::ProjectDependencies::todo_is_done(undef),
        'undef todo is not done';
};

subtest 'FOCUS_QUEUE_LIMIT is a sensible cap' => sub {
    cmp_ok($Comserv::Util::ProjectDependencies::FOCUS_QUEUE_LIMIT, '==', 20,
        'focus queue capped at 20');
};

done_testing;