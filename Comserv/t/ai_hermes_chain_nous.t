# Nov 20 2026 (Shanta): Nous Portal free models stay in the Hermes fallback chain.
# The guard's Nov 19 rebuild of ~/.hermes/config.yaml fallback_providers (from
# data/ai_model_chains.json) dropped the provider-nous steps. Pure: no network,
# no ~/.hermes access.
use strict; use warnings; use Test::More;
use FindBin; use lib "$FindBin::Bin/../lib";
use Comserv::Util::AI::ModelChains;
use Comserv::Util::AI::HermesOverrunGuard;

my $M = 'Comserv::Util::AI::ModelChains';
my $G = 'Comserv::Util::AI::HermesOverrunGuard';
my @NOUS = ('qwen/qwen4-max:free', 'tencent/hy4-flash:free', 'meituan/longcat-2.5:free', 'stepfun/step-3.7-flash:free');

# 1) tiers
is($M->slug_tier('nous|qwen/qwen4-max:free'), 'free', 'nous :free is a free step');
is($M->slug_tier('nous|some/paid-model'), 'paid', 'nous without :free stays paid');
is($M->slug_tier('openrouter|baidu/ernie-5.5-flash-preview:free'), 'free', 'openrouter :free unchanged');

# 2) the repo chain file validates and is used (not the Perl defaults)
my $ld = $M->load(undef, path => "$FindBin::Bin/../data/ai_model_chains.json", logger => sub { });
is($ld->{source}, 'file', 'chain file loaded (not Perl defaults)');
my ($ok, $errs) = $M->validate_structure($ld->{data});
ok($ok, 'ai_model_chains.json validates') or diag join "\n", @$errs;
is_deeply($errs, [], 'no validation errors');
is_deeply($ld->{data}{hermes_fallback_chain}, [
    'supergrok|grok-4.7', 'openrouter|particle-ai/particle-1', 'openrouter|openai/gpt-5.6-luna',
    (map { "nous|$_" } @NOUS), 'openrouter|baidu/ernie-5.5-flash-preview:free' ], 'hermes_fallback_chain as set Nov 20');
is($ld->{data}{hermes_emergency_chain}[-1], 'nous|upstage/solar-mini4:free', 'solar-mini4 at the end of the emergency chain');
ok(!grep({ /north-mini/ } @{ $ld->{data}{hermes_fallback_chain} }), 'north-mini removed from the Hermes chain');

# 3) nous is accepted only in the Hermes chains, not in the Router chains
my ($ok2, $e2) = $M->validate_structure({ chain_coding => ['nous|qwen/qwen4-max:free'] });
ok(!$ok2 && grep({ /chain_coding: bad slug/ } @$e2), 'nous slug still refused in chain_coding (Router cannot dispatch it)');
my ($ok3) = $M->validate_structure({ hermes_fallback_chain => ['supergrok|grok-4.7', 'nous|qwen/qwen4-max:free'] });
ok($ok3, 'nous slug accepted in hermes_fallback_chain');
my ($ok4, $e4) = $M->validate_structure({ hermes_fallback_chain => ['nous|qwen/qwen4-max:free', 'openrouter|openai/gpt-5.6-luna'] });
ok(!$ok4 && grep({ /paid step .* after a free step/ } @$e4), 'a nous free step counts as free in the paid-first rule');

# 4) guard: chain steps keep provider nous
my @chain = $M->hermes_chain($ld);
my @em    = $M->hermes_chain($ld, emergency => 1);
my @nous_steps = grep { $_->{provider} eq 'nous' } @chain;
is_deeply([ map { $_->{tier} } @nous_steps ], [ ('free') x 4 ], 'hermes_chain tiers nous steps free');
my @cands = grep { ($_->{provider} // '') eq 'nous' } $G->can('chain_candidates')->(chain => \@chain, emergency => \@em);
is_deeply([ map { $_->{default} } @cands ], [ @NOUS, 'upstage/solar-mini4:free' ], 'chain_candidates: nous steps in order, provider nous');
ok(!grep({ $_->{paid} } @cands), 'nous candidates are not paid');
ok(!grep({ ($_->{base_url} // '') =~ /openrouter/ } @cands), 'nous candidates do not point at OpenRouter');
is($cands[0]{base_url}, 'https://inference-api.nousresearch.com/v1', 'nous base_url is Nous Portal');
ok($G->can('candidate_ok')->($cands[0], paid_ok => 0, or_ids => {}), 'candidate_ok accepts a nous step with no OpenRouter room and no OpenRouter id');

my $or_ids = { map { $_ => 1 } 'baidu/ernie-5.5-flash-preview:free', 'nvidia/nemotron-3.5-lightning:free' };
my $fc = $G->can('fallback_chain')->(chain => \@chain, emergency => \@em, or_ids => $or_ids, paid_ok => 0);
my @fn = grep { $_->{provider} eq 'nous' } @$fc;
is_deeply([ map { $_->{model} } @fn[0 .. 3] ], \@NOUS, 'fallback_chain lists the 4 nous steps in order');
is_deeply([ map { $_->{provider} } @fn[0 .. 3] ], [ ('nous') x 4 ], 'fallback_chain nous steps have provider nous');
is_deeply([ map { "$_->{provider}/$_->{model}" } @$fc[0 .. 4] ],
    [ (map { "nous/$_" } @NOUS), 'openrouter/baidu/ernie-5.5-flash-preview:free' ],
    'with no paid room: the nous steps lead, then ernie');
ok(!grep({ $_->{provider} eq 'openrouter' && $_->{model} =~ m{^(?:qwen/qwen4|tencent/|meituan/|stepfun/|upstage/)} } @$fc),
   'no nous model is rewritten to an openrouter step');
# the "one bad id" case: ernie gone from OpenRouter, the nous steps stay
my $fc2 = $G->can('fallback_chain')->(chain => \@chain, emergency => \@em, or_ids => { 'nvidia/nemotron-3.5-lightning:free' => 1 }, paid_ok => 0);
is(scalar(grep { $_->{provider} eq 'nous' } @$fc2), 5, 'an OpenRouter id leaving does not drop the nous steps');

done_testing;
