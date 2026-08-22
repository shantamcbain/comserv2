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

done_testing();
