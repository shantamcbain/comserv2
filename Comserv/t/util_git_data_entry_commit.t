use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use_ok('Comserv::Util::Git') or BAIL_OUT('Cannot load Comserv::Util::Git');

my $git = Comserv::Util::Git->new;

ok($git->data_entry_runtime_path('Comserv/data/ai_trials/gpt_56_luna.state.json'), 'trial state is data entry');
ok($git->data_entry_runtime_path('data/ai_trials/kimi_k27_code.tasks.jsonl'), 'trial task log is data entry');
ok(!$git->data_entry_runtime_path('Comserv/lib/Comserv/Util/Git.pm'), 'source is not data entry');
ok(!$git->data_entry_runtime_path('Comserv/data/ai_model_chains.json'), 'model config is still reviewed');

my $diff = join("\n",
    'diff --git a/Comserv/data/ai_trials/gpt_56_luna.state.json b/Comserv/data/ai_trials/gpt_56_luna.state.json',
    '--- a/Comserv/data/ai_trials/gpt_56_luna.state.json',
    '+++ b/Comserv/data/ai_trials/gpt_56_luna.state.json',
    '-{"last_checked_at":1}',
    '+{"last_checked_at":2}',
    'diff --git a/Comserv/lib/Comserv/Util/Git.pm b/Comserv/lib/Comserv/Util/Git.pm',
    '--- a/Comserv/lib/Comserv/Util/Git.pm',
    '+++ b/Comserv/lib/Comserv/Util/Git.pm',
    '-old',
    '+new',
    '');
my $kept = $git->strip_data_entry_diff($diff);
like($kept, qr/Util\/Git\.pm/, 'code hunk kept');
unlike($kept, qr/gpt_56_luna/, 'data-entry hunk dropped');
ok($git->strip_data_entry_diff($diff =~ s/Util\/Git\.pm.*//sr) !~ /\S/, 'data-only diff leaves nothing to review');

my $holds = $git->commit_findings_that_hold([
    { severity => 'low', file => 'Comserv/data/ai_trials/gpt_56_luna.state.json', issue => 'timestamp churn' },
    { severity => 'high', file => 'Comserv/data/ai_trials/gpt_56_luna.state.json', issue => 'secret in state' },
    { severity => 'low', file => 'Comserv/lib/Comserv/Util/Git.pm', issue => 'real code note' },
]);
is(scalar(@$holds), 2, 'low data-entry note dropped; high and code notes kept');
is($holds->[0]{severity}, 'high', 'high finding on a data-entry file still holds');
is($holds->[1]{file}, 'Comserv/lib/Comserv/Util/Git.pm', 'finding on source still holds');

my $state = 'Comserv/data/ai_trials/gpt_56_luna.state.json';
ok(!$git->data_entry_blob_error($state, '{"last_checked_at":2}'), 'valid state JSON is allowed');
like($git->data_entry_blob_error($state, "<<<<<<< HEAD\n{}\n"), qr/conflict markers/, 'conflict markers still refuse');
like($git->data_entry_blob_error($state, '{'), qr/not valid JSON/, 'broken JSON still refuses');
like($git->data_entry_blob_error('data/ai_trials/x.tasks.jsonl', qq{{"ok":1}\nnot-json\n}), qr/line 2/, 'broken task log line still refuses');

done_testing;
