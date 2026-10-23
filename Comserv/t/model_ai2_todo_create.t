use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

BEGIN { use_ok('Comserv::Model::AI2::TodoCreate'); }

my $m = Comserv::Model::AI2::TodoCreate->new;
ok($m, 'TodoCreate model instantiates');

my $ranked = $m->rank_projects('AISYSTEM', [
    { id => 1,   name => 'CSC Home',       project_code => 'CSC',      parent_id => undef },
    { id => 280, name => 'AI System Use',  project_code => 'AISYSTEM', parent_id => 114 },
    { id => 282, name => 'AISYS-W1',       project_code => 'AISYS-W1', parent_id => 280 },
]);
ok($ranked && @$ranked, 'ranked some projects');
is($ranked->[0]{id}, 280, 'exact project_code AISYSTEM wins');

my $sub = $m->rank_projects('W1 shortlists', [
    { id => 114, name => 'AIC-ENH',                 project_code => 'AIC-ENH' },
    { id => 282, name => 'AISYS-W1 Right model',    project_code => 'AISYS-W1', parent_id => 280 },
]);
ok($sub && @$sub, 'ranked W1 query');
is($sub->[0]{id}, 282, 'sub-project matching W1 ranks first');

my $none = $m->rank_projects('zzzz-no-such-project', [
    { id => 1, name => 'CSC Home', project_code => 'CSC' },
]);
is(scalar @$none, 0, 'unrelated query scores zero');

my $intent = $m->detect_create_intent(
    'Please add a new todo to the ai system to test the new Chat with ai ability to create a new todo'
);
ok($intent, 'detects add-a-todo prompt');
is($intent->{project_name}, 'ai system', 'project hint from "to the ai system"');
like($intent->{subject}, qr/test the new Chat/i, 'subject is the test phrase');

ok($m->detect_create_intent('add a todo Test new Chat-with-AI todo creation'),
    'detects short add-a-todo');
ok(!$m->detect_create_intent('how do I add a todo'), 'ignores how-to questions');
ok(!$m->detect_create_intent('what are my top 5 todos'), 'ignores focus-tune questions');

my $enr = $m->enrich_parse({
    subject => 'wire the hive graph',
    description => 'add a todo to wire the hive graph urgent',
});
is($enr->{priority}, 1, 'urgent language → P1');
ok($enr->{scheduled_date}, 'scheduled_date inferred for planning queue');
ok($enr->{comments} =~ /Inferred by Todo-create parse/, 'inferred note stored for later agents');
ok($m->subject_needs_clarify('it'), 'vague subject asks the user');
ok(!$m->subject_needs_clarify('wire the hive graph'), 'real subject is enough');

# #2344 — subject longer than varchar(255) must not blow the INSERT.
{
    my $long = 'add to time tracking the ability to keep your start stop todo but also to be able to use the done to add a comment to the log and mark the todo as done. We have buttons on the todo system to do that one is start the other is active (stop) here and done. the active and done both give a dialog to the user of what was done that get recored in the todo, Not sure how ai deals with this.';
    ok(length($long) > 255, 'fixture subject is longer than column');
    my ($subj, $desc) = $m->normalize_subject_description($long, '');
    ok(length($subj) <= 255, 'normalized subject fits varchar(255)');
    ok(length($subj) >= 3, 'normalized subject still usable');
    like($desc, qr/dialog|recored|ai deals/i, 'overflow moved into description');
    my ($s2, $d2) = $m->normalize_subject_description($long, 'existing body');
    like($d2, qr/existing body/, 'existing description preserved after overflow');
    my ($s3, $d3) = $m->normalize_subject_description('short title', 'body');
    is($s3, 'short title', 'short subject unchanged');
    is($d3, 'body', 'short path leaves description alone');
}


# 3D-20260907-3180 / 6510 — HelpDesk ticket prompts that mention "todo" must
# not be stolen into TodoCreate (which asks "which 3d project").
ok(!$m->detect_create_intent(
    'Create a HelpDesk ticket: Chat-with-AI todo-create asked which 3d project'),
    'ticket prompt mentioning todo-create is not a todo intent');
ok(!$m->detect_create_intent(
    'create a support ticket about the todo create flow failing'),
    'support-ticket about todo flow is not a todo intent');
ok(!$m->detect_create_intent('file a ticket: AI Editor create-todo hijack'),
    'file-a-ticket mentioning create-todo is not a todo intent');
ok($m->detect_create_intent('add a todo to fix helpdesk ticket create'),
    'explicit create-todo about tickets still matches');
ok($m->detect_create_intent('create a todo for the helpdesk ticket create bug'),
    'explicit create-todo for ticket bug still matches');

ok($m->detect_create_intent('can you add a todo to wire chat ACTION contract'),
    'can-you add-a-todo is create intent');
ok($m->detect_create_intent('I need a todo for the editor SuperGrok picker'),
    'need-a-todo is create intent');
ok($m->detect_create_intent('put this on the todo list: pin SuperGrok in editor'),
    'put-on-todo-list is create intent');
ok(!$m->detect_create_intent('analyze the code and mention todos in the plan'),
    'analysis mentioning todos is not create intent');

require Comserv::Model::AI2::ChatIntent;
ok(Comserv::Model::AI2::ChatIntent::is_editor_agent('programming'), 'programming is editor');
ok(!Comserv::Model::AI2::ChatIntent::looks_like_todo_create('plan the refactor and create todos later'),
    'plan-create-todos-later is not explicit');
ok(Comserv::Model::AI2::ChatIntent::looks_like_todo_create('add a todo pin SuperGrok'),
    'explicit add-a-todo still matches in editor context');

done_testing();
