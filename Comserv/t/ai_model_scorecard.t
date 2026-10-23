use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Comserv::Util::AI::ModelScorecard;
use Comserv::Util::AI::ProposalFormat;
use Comserv::Util::AI::HermesOverrunGuard;

my $M = 'Comserv::Util::AI::ModelScorecard';
# task classification (heuristic)
is $M->can('classify_task')->(title => 'Fix xorg.conf missing after upgrade', source => 'cli'), 'runtime_debug';
is $M->can('classify_task')->(title => 'Git upstream not showing on github'), 'runtime_debug';
is $M->can('classify_task')->(title => 'Compute decision rank weight content'), 'todo_rank';
is $M->can('classify_task')->(title => 'OllamaModelResolver module create', source => 'oneshot'), 'coding';
is $M->can('classify_task')->(title => 'Hello there', source => 'tui'), 'chat';
is $M->can('classify_task')->(title => 'x', cwd => '/tmp/r2/bench/glm'), 'benchmark';
is $M->can('classify_task')->(title => 'x', aux_task => 'title_generation'), 'aux';
# signals
is Comserv::Util::AI::ModelScorecard::correction_count('no, that is wrong', 'thanks', "still not working"), 2;
is Comserv::Util::AI::ModelScorecard::clarify_count('Should I restart the server?', 'Done.'), 1;
is Comserv::Util::AI::ModelScorecard::thrash_episodes(qw(a a a a b b b c)), 2, 'two runs of >=3';
is_deeply [Comserv::Util::AI::ModelScorecard::test_signals('Result: PASS', 'Failed 2/10 test programs')], [1, 1];
is Comserv::Util::AI::ModelScorecard::outcome(commits => 1), 'committed';
is Comserv::Util::AI::ModelScorecard::outcome(stop_turns => 0), 'abandoned';
is Comserv::Util::AI::ModelScorecard::outcome(stop_turns => 2, last_role => 'assistant', corrections => 3), 'user_corrected';
is Comserv::Util::AI::ModelScorecard::outcome(stop_turns => 2, last_role => 'assistant'), 'completed';
# aggregate + rating with weights
my @segs = (
  { session => 's1', model => 'fast', provider => 'openrouter', task => 'coding', calls => 10, tokens_in => 1e6, tokens_out => 1e4,
    active_s => 600, turns => [60, 60, 60], stop_turns => 3, usd => 0.5, outcome => 'completed' },
  { session => 's2', model => 'slow', provider => 'openrouter', task => 'coding', calls => 30, tokens_in => 3e6, tokens_out => 3e4,
    active_s => 3600, turns => [300, 300, 300], stop_turns => 3, usd => 0.5, outcome => 'completed' },
  { session => 's3', model => 'grok-4.7', provider => 'xai-oauth', task => 'coding', calls => 5, tokens_in => 1e6, tokens_out => 0,
    weighted_mtok => 1, active_s => 600, turns => [60, 60, 60], stop_turns => 3, outcome => 'committed', commits => 1 },
);
my $a = Comserv::Util::AI::ModelScorecard::aggregate(segments => \@segs, cfg => { weights => { time => 1, cost => 0, quality => 0 } });
my %r = map { $_->{model} => $_ } @{ $a->{rows} };
is $r{fast}{rating}, 100, 'fastest = 100 on time-only weights';
cmp_ok $r{slow}{rating}, '<', 30, 'slow rated low';
is $r{'grok-4.7'}{quota_pct}, '0.6', 'quota % from weighted Mtok (0.57/M)';
is $r{'grok-4.7'}{usd}, '0.00', 'Super Grok: no cash';
is $r{fast}{median_turn_s}, 60;
my $b = Comserv::Util::AI::ModelScorecard::aggregate(segments => [ @segs[0, 1] ], cfg => { weights => { time => 0, cost => 1, quality => 0 } });
is((grep { $_->{model} eq 'slow' } @{ $b->{rows} })[0]{rating}, 100, 'equal cost -> both 100 on cost-only');
my $cf = Comserv::Util::AI::ModelScorecard::cfg_merge({ weights => { time => 'x', cost => 3 }, days => 999 });
is $cf->{weights}{time}, 1, 'bad weight ignored'; is $cf->{weights}{cost}, 3; is $cf->{days}, 60, 'days capped';

# proposal format
my $f = Comserv::Util::AI::ProposalFormat::normalize({ title => 'Lower cap', rationale => 'Burned 40% quota Thursday. Undo: set back to 90.', target => 'x.json:cap', change_type => 'config' }, { value => 80 });
like $f->{impact}, qr/40% quota/, 'impact derived from rationale';
like $f->{solution}, qr/x\.json:cap -> 80/, 'solution from target/value';
like $f->{risk}, qr/Undo: set back/, 'risk from undo sentence';
is_deeply $f->{derived}, [qw(problem impact solution risk)];
my $g = Comserv::Util::AI::ProposalFormat::normalize({ title => 't', problem => 'P', impact => 'I', solution => 'S', risk => 'R' }, undef);
is_deeply [ @$g{qw(problem impact solution risk)} ], [qw(P I S R)]; is_deeply $g->{derived}, [];
my ($pl) = Comserv::Util::AI::ProposalFormat::fold_into_payload({ title => 't', problem => 'P' }, { value => 1 });
is $pl->{value}, 1, 'payload value kept'; is $pl->{format}{problem}, 'P';
my ($arr) = Comserv::Util::AI::ProposalFormat::fold_into_payload({ title => 't' }, [1]);
is_deeply $arr, [1], 'non-hash payload untouched';

# Ollama 64K rule
my $G = 'Comserv::Util::AI::HermesOverrunGuard';
my $ctx = { 'gemma4-64k:latest' => 65536, 'qwen2.5-coder:14b' => 4096 };
ok  Comserv::Util::AI::HermesOverrunGuard::ollama_ctx_ok('gemma4-64k:latest', $ctx);
ok !Comserv::Util::AI::HermesOverrunGuard::ollama_ctx_ok('qwen2.5-coder:14b', $ctx);
ok  Comserv::Util::AI::HermesOverrunGuard::ollama_ctx_ok('gemma4-64k:latest', undef), 'known-good when Ollama down';
ok !Comserv::Util::AI::HermesOverrunGuard::ollama_ctx_ok('phi4:14b', undef), 'unknown model refused';
my ($k, $d) = Comserv::Util::AI::HermesOverrunGuard::filter_ollama_ctx(
  [ { provider => 'openrouter', model => 'cohere/north-mini-code:free' }, { provider => 'ollama-launch', model => 'gemma4-64k:latest' },
    { provider => 'ollama-launch', model => 'qwen2.5-coder:14b' } ], $ctx);
is scalar(@$k), 2; is $d->[0]{model}, 'qwen2.5-coder:14b';
my $bad = Comserv::Util::AI::HermesOverrunGuard::fallback_bad(current => [ { provider => 'ollama-launch', model => 'qwen2.5-coder:14b' } ], ollama_ctx => $ctx);
like $bad->[0], qr/context below 65536/, 'self-heal flags small-context Ollama fallback';
my $chain = Comserv::Util::AI::HermesOverrunGuard::fallback_chain(ollama_ctx => $ctx, ollama_models => [keys %$ctx], or_ids => {});
ok !(grep { $_->{model} eq 'qwen2.5-coder:14b' } @$chain), 'chain excludes qwen 4K/32K';
ok( (grep { $_->{model} eq 'gemma4-64k:latest' } @$chain) ? 1 : 0, "chain keeps gemma4-64k");
done_testing;
