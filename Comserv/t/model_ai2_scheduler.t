use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use DateTime;

BEGIN { use_ok('Comserv::Model::AI2::Scheduler'); }

my $m = Comserv::Model::AI2::Scheduler->new;
ok($m, 'Scheduler instantiates');

ok(!$m->detect_intent('how do I schedule a todo'), 'ignores how-to');
ok(!$m->detect_intent('add a todo wire the hive graph'), 'does not steal todo-create');

my $p = $m->detect_intent('schedule todo #2218 after the queue');
ok($p, 'detects schedule todo #N');
is($p->{todo_id}, 2218, 'todo id 2218');
ok(!$p->{apply}, 'preview by default');

my $a = $m->detect_intent('apply schedule for todo #2218');
ok($a && $a->{apply}, 'apply when asked');

my $b = $m->detect_intent('schedule todo #10 blocked by #9');
ok($b, 'detects blocker');
is($b->{blocker_id}, 9, 'blocker id');

my $prev = $m->preview(
    { todo_id => 10 },
    [ { scheduled_date => '2026-09-20' }, { due_date => '2026-09-22' } ],
);
is($prev->{proposed_start}, '2026-09-23', 'start is day after latest queue date');
ok(!$prev->{bulk}, 'never bulk');

is($m->queue_tail_date([]), DateTime->now->add(days => 1)->ymd, 'empty queue = tomorrow');

done_testing();
