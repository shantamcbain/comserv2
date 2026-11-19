use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use File::Temp qw(tempdir);
use JSON;

# ---------------------------------------------------------------------------
# Todo #2564 — REAL path: ai2_chat's context (agent+phase) must survive every
# select_model hop and reach ModelPick's Hermes-chain pick.
#
# This drives the production call chain:
#     Controller::AI2::ai2_chat context  (stash ai2_agent_ctx)
#   -> Router::select_model              (no agent_id passed: the drift hop that
#                                         dispatch_chat / GitFix used to make)
#   -> classify_prompt_for_routing       (LLM classify must be skipped)
#   -> ModelPick::coding_pick -> hermes_chain -> pick_from_chain
# Only environment leaves (guard, spend, live catalog, logging sink) are stubbed;
# the routing logic under test is the real code.
# ---------------------------------------------------------------------------

use Comserv::Model::AI2::Router;
use Comserv::Model::AI2::ModelPick;
no warnings 'redefine';

# --- logging sink: record every log_with_details call ----------------------
my @LOG;
*Comserv::Util::Logging::log_with_details = sub {
    my ($self, $c, $level, $file, $line, $method, $msg) = @_;
    push @LOG, { level => $level, file => $file, line => $line, method => $method, msg => $msg // '' };
    return 1;
};
sub log_text  { join("\n", map { "$_->{method}: $_->{msg}" } @LOG) }
sub log_find  { my ($re) = @_; join("\n", map { "$_->{method}: $_->{msg}" } grep { $_->{method} =~ $re || $_->{msg} =~ $re } @LOG) }
sub log_clear { @LOG = () }

# --- the live catalog the providers would report right now ----------------
my $CATALOG = [
    { id => 'particle-ai/particle-1',                  name => 'particle-ai/particle-1',
      provider => 'openrouter', free => 0 },
    { id => 'baidu/ernie-5.5-flash-preview:free',      name => 'baidu/ernie-5.5-flash-preview:free',
      provider => 'openrouter', free => 1 },
    { id => 'cohere/north-mini-code:free',             name => 'cohere/north-mini-code:free',
      provider => 'openrouter', free => 1 },
    { id => 'nvidia/nemotron-3.5-lightning:free',      name => 'nvidia/nemotron-3.5-lightning:free',
      provider => 'openrouter', free => 1 },
    { id => 'qwen2.5vl:3b',                            name => 'qwen2.5vl:3b',
      provider => 'ollama', local => 1 },
];

{ package FakeC;
  sub new { my ($class, %o) = @_; bless { s => $o{session} || { username => 'Shanta', roles => ['admin'] },
                                          st => $o{stash} || {}, catalog => $o{catalog} }, $class }
  sub session { $_[0]{s} }
  sub stash   { $_[0]{st} }
  sub req     { undef }
  sub path_to { '/nonexistent' }
  sub model {
      my ($self, $name) = @_;
      return $main::ROUTER if defined $name && $name eq 'AI2::Router';
      return undef;
  }
}

# --- Router environment stubs (leaves only) -------------------------------
our $GUARD = { locked => 1, reason => 'daily 11.0% >= budget 9.7%' };
our $ROUTER;
*Comserv::Model::AI2::Router::supergrok_guard            = sub { $GUARD };
our $SG_GUARD_LOCKED = 1;
*Comserv::Model::AI2::Router::_external_default_available = sub { $SG_GUARD_LOCKED ? 0 : 1 };
*Comserv::Model::AI2::Router::route_override_allowed      = sub { 1 };
*Comserv::Model::AI2::Router::openrouter_spend            = sub { { pct => 12, over_daily => 0 } };
*Comserv::Model::AI2::Router::capable_chain_pick          = sub { undef };
*Comserv::Model::AI2::Router::get_available_models        = sub { $CATALOG };
*Comserv::Model::AI2::ModelPick::available_groups         = sub {
    my ($self, $c) = @_;
    return { supergrok => [], openrouter => [
        { model => 'particle-ai/particle-1', free => 0 },
        { model => 'baidu/ernie-5.5-flash-preview:free', free => 1 },
    ], ollama => [ { model => 'qwen2.5vl:3b', local => 1 } ] };
};

$ROUTER = Comserv::Model::AI2::Router->new;

# --- Hermes chain fixture (same order as the operator's live files) -------
my $dir = tempdir(CLEANUP => 1);
open my $cf, '>', "$dir/config.yaml" or die $!;
print $cf <<'YAML';
model:
  default: particle-ai/particle-1
  provider: openrouter
fallback_providers:
  - provider: openrouter
    model: baidu/ernie-5.5-flash-preview:free
  - provider: openrouter
    model: cohere/north-mini-code:free
  - provider: ollama-launch
    model: gemma4-64k:latest
  - provider: openrouter
    model: nvidia/nemotron-3.5-lightning:free
YAML
close $cf;
open my $sf, '>', "$dir/switch.json" or die $!;
print $sf JSON::encode_json({ from => 'xai-oauth/grok-4.7', to => 'openrouter/particle-ai/particle-1',
                              reason => 'daily_budget' });
close $sf;
$ENV{HERMES_CONFIG}       = "$dir/config.yaml";
$ENV{HERMES_GUARD_SWITCH} = "$dir/switch.json";

# ===========================================================================
# 1. The drift hop: no agent_id passed, context inherited from ai2_agent_ctx
#    (exactly what Router::dispatch_chat / GitFix do after the controller runs)
# ===========================================================================
log_clear();
my $c1 = FakeC->new(stash => { ai2_agent_ctx => { agent_id => 'programming', phase => 'analyze' } });
my ($prov, $model) = $ROUTER->select_model($c1,
    prompt => 'add a validate_path() helper and cover it with a test',
);
is($prov,  'openrouter',                     'drift hop: provider is openrouter (SG locked)');
is($model, 'particle-ai/particle-1',         'drift hop: particle-1 chosen with SG locked');
isnt($model, 'qwen2.5vl:3b',                 'drift hop: the 3B vision model is NOT chosen');

my $chain_log = log_find(qr/coding_chain_pick/);
like($chain_log, qr/agent=programming phase=analyze/,
    'coding_chain_pick logged the original agent+phase (not agent=(none))')
    or diag("LOG:\n" . log_text());
like($chain_log, qr/supergrok\|grok-4\.7 \(guard locked/,
    'the locked SuperGrok hop is logged with its skip reason') or diag($chain_log);
like($chain_log, qr/chose=openrouter\|particle-ai\/particle-1/,
    'the chosen model is logged') or diag($chain_log);

# ===========================================================================
# 2. The LLM classifier is skipped for a coding agent (no 125s Ollama call)
# ===========================================================================
my $cls = log_find(qr/ai2_classify_timing/);
like($cls, qr/llm_classify=0/, 'LLM classify skipped for the coding agent') or diag($cls);
like($c1->stash->{ai2_route_cl}{notes} // '', qr/llm-classify skipped \(coding agent programming\)/,
    'classifier notes name the coding agent as the reason it was skipped')
    or diag('notes: ' . ($c1->stash->{ai2_route_cl}{notes} // '(none)'));

# ===========================================================================
# 3. Explicit agent_id given (Chat::select_provider_and_model path)
# ===========================================================================
log_clear();
my ($p2, $m2) = $ROUTER->select_model(
    FakeC->new, prompt => 'fix the git path validation', agent_id => 'gitfix-analysis', phase => 'analyze');
is($m2, 'particle-ai/particle-1', 'gitfix-analysis is routed through the chain too');
like(log_find(qr/coding_chain_pick/), qr/agent=gitfix-analysis phase=analyze/,
    'gitfix-analysis is logged with its agent name (no longer agent=(none))') or diag(log_text());

# ===========================================================================
# 4. SuperGrok unlocked -> grok-4.7 head
# ===========================================================================
$GUARD = { locked => 0 };
$SG_GUARD_LOCKED = 0;
log_clear();
my ($p3, $m3) = $ROUTER->select_model(
    FakeC->new(stash => { ai2_agent_ctx => { agent_id => 'programming', phase => 'plan' } }),
    prompt => 'refactor the traveler BOM builder');
is($p3, 'supergrok', 'SG unlocked: provider supergrok');
is($m3, 'grok-4.7',  'SG unlocked: grok-4.7 (never grok-build)');
isnt($m3, 'grok-build-0.1', 'never grok-build');

# ===========================================================================
# 5. particle-1 not live -> ernie (chain advances, still no vision model)
# ===========================================================================
$GUARD = { locked => 1 };
$SG_GUARD_LOCKED = 1;
@$CATALOG = grep { ($_->{name} // '') ne 'particle-ai/particle-1' } @$CATALOG;
log_clear();
my ($p4, $m4) = $ROUTER->select_model(
    FakeC->new(stash => { ai2_agent_ctx => { agent_id => 'programming', phase => 'analyze' } }),
    prompt => 'explain the schema compare flow');
is($m4, 'baidu/ernie-5.5-flash-preview:free', 'particle-1 absent: ernie is next in the chain');
unlike(log_find(qr/coding_chain_pick/), qr/chose=ollama\|qwen2\.5vl/, 'still never qwen2.5vl:3b') or diag(log_text());

# ===========================================================================
# 6. GitFix path (the "=== Router Analysis (...) ===" surface): its analysis
#    model comes from select_model, so it must be particle-1 too.
# ===========================================================================
$GUARD = { locked => 1 };
$SG_GUARD_LOCKED = 1;
@$CATALOG = (
    { id => 'particle-ai/particle-1',             name => 'particle-ai/particle-1', provider => 'openrouter', free => 0 },
    { id => 'baidu/ernie-5.5-flash-preview:free', name => 'baidu/ernie-5.5-flash-preview:free', provider => 'openrouter', free => 1 },
    { id => 'cohere/north-mini-code:free',        name => 'cohere/north-mini-code:free', provider => 'openrouter', free => 1 },
    { id => 'qwen2.5vl:3b',                       name => 'qwen2.5vl:3b', provider => 'ollama', local => 1 },
);
my @DISPATCH;
*Comserv::Model::AI2::Router::dispatch_chat = sub {
    my ($self, $c, $requested) = @_;
    push @DISPATCH, $requested;
    return { success => 1, response => 'ok', provider => 'stub', model => $requested };
};
require Comserv::Model::AI2::GitFix;
my $gitfix = Comserv::Model::AI2::GitFix->new;
my $res = $gitfix->try_chat_fix(
    FakeC->new(stash => { ai2_agent_ctx => { agent_id => 'programming', phase => 'analyze' } }),
    prompt => 'Rejected unsafe or unknown path(s): data/ai_trials/particle_1.state.json',
);
ok($res && $res->{handled}, 'GitFix handled the git-rejection prompt');
is($DISPATCH[0], 'particle-ai/particle-1',
    'GitFix analysis model is particle-1 (its "=== Router Analysis (...) ===" header)')
    or diag('dispatch got: ' . ($DISPATCH[0] // 'none'));
like($res->{model} // '', qr/particle-ai\/particle-1/, 'the returned label names particle-1')
    or diag($res->{model} // '');
unlike($res->{model} // '', qr/north-mini/, 'label no longer says north-mini') or diag($res->{model} // '');
like($DISPATCH[1] // '', qr/^openrouter\|particle-ai\/particle-1$/,
    'the decision stage now uses the chain too (the 0.8B local model echoed prompts)')
    or diag('decision dispatch got: ' . ($DISPATCH[1] // 'none'));
like($res->{response} // '', qr/Structured Recommendation \(particle-ai\/particle-1 via Router\)/,
    'the recommendation header names the real decision model') or diag(substr($res->{response}//'',0,200));


done_testing();
