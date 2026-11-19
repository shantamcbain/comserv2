use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use File::Temp qw(tempdir);
use JSON;

use_ok('Comserv::Model::AI2::ModelPick') or BAIL_OUT('cannot load ModelPick');

# ---------------------------------------------------------------------------
# Todo #2564: code-editing agents must walk the Hermes chain (read live from
# ~/.hermes/config.yaml + ~/.hermes/guard_model_switch.json) and only pick
# models that exist right now. Never a vision-only / sub-7B model while any
# chain entry is live.
# ---------------------------------------------------------------------------

{
    package FakeLog;
    sub new { bless { lines => [] }, shift }
    sub log_with_details {
        my ($self, $c, $level, $file, $line, $method, $msg) = @_;
        push @{ $self->{lines} }, { level => $level, method => $method, msg => $msg };
        return 1;
    }
    sub lines  { $_[0]->{lines} }
    sub joined { join("\n", map { $_->{method} . ': ' . $_->{msg} } @{ $_[0]->{lines} }) }
}

{
    package FakeRouter;
    sub new { my ($class, $catalog, $guard) = @_; bless { catalog => $catalog, guard => $guard || {} }, $class }
    sub get_available_models { $_[0]->{catalog} }
    sub supergrok_guard      { $_[0]->{guard} }
}

{
    package FakeCtx;
    sub new {
        my ($class, %o) = @_;
        bless { catalog => $o{catalog} || [], guard => $o{guard} || {}, stash => {} }, $class;
    }
    sub model {
        my ($self, $name) = @_;
        return undef unless defined $name && $name eq 'AI2::Router';
        $self->{router} ||= FakeRouter->new($self->{catalog}, $self->{guard});
        return $self->{router};
    }
    sub stash   { $_[0]->{stash} }
    sub session { { roles => 'admin' } }
    sub config  { {} }
    sub can     { my ($self, $m) = @_; return ($m eq 'stash' || $m eq 'model' || $m eq 'session' || $m eq 'config') ? 1 : 0 }
}

sub mp {
    my $log = FakeLog->new;
    my $obj = Comserv::Model::AI2::ModelPick->new(logging => $log);
    return ($obj, $log);
}

# Live-iness helpers -------------------------------------------------------
my %LIVE_SG   = ('supergrok|grok-4.7' => 1);
my %LIVE_P1   = (%LIVE_SG, 'openrouter|particle-ai/particle-1' => 1);
my %LIVE_ERN  = ('openrouter|baidu/ernie-5.5-flash-preview:free' => 1, 'openrouter|cohere/north-mini-code:free' => 1);
my %LIVE_NONE = ();

# Chain entries in Hermes order (as hermes_chain() yields them).
sub chain_entries {
    return [
        { raw => 'xai-oauth/grok-4.7',           provider => 'supergrok',  model => 'grok-4.7',                            source => 'supergrok-head' },
        { raw => 'openrouter/particle-ai/particle-1', provider => 'openrouter', model => 'particle-ai/particle-1',          source => 'guard-switch' },
        { raw => 'openrouter/baidu/ernie-5.5-flash-preview:free', provider => 'openrouter', model => 'baidu/ernie-5.5-flash-preview:free', source => 'fallback' },
        { raw => 'openrouter/cohere/north-mini-code:free', provider => 'openrouter', model => 'cohere/north-mini-code:free',  source => 'fallback' },
        { raw => 'ollama-launch/gemma4-64k:latest', provider => 'ollama',     model => 'gemma4-64k:latest',                   source => 'fallback' },
        { raw => 'openrouter/nvidia/nemotron-3.5-lightning:free', provider => 'openrouter', model => 'nvidia/nemotron-3.5-lightning:free', source => 'fallback' },
    ];
}

# --- 1. hermes_chain reads the real files at request time -------------------
my $dir = tempdir(CLEANUP => 1);
open my $cf, '>', "$dir/config.yaml" or die $!;
print $cf <<'YAML';
model:
  default: particle-ai/particle-1
  provider: openrouter
fallback_providers:
  - provider: openrouter
    model: particle-ai/particle-1
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
open my $sf, '>', "$dir/guard_model_switch.json" or die $!;
print $sf encode_json({
    from => 'xai-oauth/grok-4.7',
    to   => 'openrouter/particle-ai/particle-1',
    reason => 'daily_budget',
});
close $sf;

local $ENV{HERMES_CONFIG}       = "$dir/config.yaml";
local $ENV{HERMES_GUARD_SWITCH} = "$dir/guard_model_switch.json";

my ($obj, $log) = mp();
my $chain = $obj->hermes_chain(FakeCtx->new);
is_deeply([ map { "$_->{provider}|$_->{model}" } @$chain ],
    [ 'supergrok|grok-4.7',
      'openrouter|particle-ai/particle-1',
      'openrouter|baidu/ernie-5.5-flash-preview:free',
      'openrouter|cohere/north-mini-code:free',
      'ollama|gemma4-64k:latest',
      'openrouter|nvidia/nemotron-3.5-lightning:free' ],
    'hermes_chain() reads config.yaml + guard switch in Hermes order (no hardcoded copy)');

# --- 2. SuperGrok unlocked -> grok-4.7 -------------------------------------
{
    ($obj, $log) = mp();
    my ($res, $line) = $obj->pick_from_chain(FakeCtx->new,
        chain => chain_entries(), live => \%LIVE_P1, guard => { locked => 0 },
        agent => 'programming', phase => 'plan');
    ok($res && $res->{provider} eq 'supergrok' && $res->{model} eq 'grok-4.7',
        'SG unlocked -> supergrok|grok-4.7') or diag($line);
    isnt($res->{model}, 'grok-build-0.1', 'never grok-build');
}

# --- 3. SuperGrok locked -> particle-1 -------------------------------------
{
    ($obj, $log) = mp();
    my ($res, $line) = $obj->pick_from_chain(FakeCtx->new,
        chain => chain_entries(), live => \%LIVE_P1, guard => { locked => 1, reason => 'daily 11% >= 9.7%' },
        agent => 'programming', phase => 'plan');
    ok($res && $res->{provider} eq 'openrouter' && $res->{model} eq 'particle-ai/particle-1',
        'SG locked -> openrouter|particle-ai/particle-1') or diag($line);
    like($line, qr/supergrok\|grok-4\.7 \(guard locked/, 'skip reason for the locked SuperGrok hop is logged');
}

# --- 4. particle-1 not live -> ernie --------------------------------------
{
    ($obj, $log) = mp();
    my ($res, $line) = $obj->pick_from_chain(FakeCtx->new,
        chain => chain_entries(), live => \%LIVE_ERN, guard => { locked => 1 },
        agent => 'programming', phase => 'implement');
    ok($res && $res->{model} eq 'baidu/ernie-5.5-flash-preview:free',
        'particle-1 absent from live catalog -> baidu/ernie-5.5-flash-preview:free') or diag($line);
    like($line, qr/particle-ai\/particle-1 \(not in live catalog\)/, 'skip reason for a non-live OpenRouter id is logged');
}

# --- 5. Ollama model absent from /api/tags -> skipped ---------------------
{
    ($obj, $log) = mp();
    my $live = { %LIVE_ERN };   # no ollama entries at all
    my ($res, $line) = $obj->pick_from_chain(FakeCtx->new,
        chain => chain_entries(), live => $live, guard => { locked => 1 },
        agent => 'gitfix-analysis', phase => 'analyze');
    isnt($res && $res->{provider}, 'ollama', 'Ollama hop with no /api/tags entry is not used') or diag($line);
    ok(($line =~ /ollama\|gemma4-64k:latest \(not installed/ || $line !~ /ollama\|/), 'not-installed Ollama hop is logged as skipped');
    # ...and it IS used when the tag exists
    my $live2 = { %LIVE_ERN, 'ollama|gemma4-64k:latest' => 1 };
    my $live3 = { 'ollama|gemma4-64k:latest' => 1 };
    ($res, $line) = $obj->pick_from_chain(FakeCtx->new,
        chain => chain_entries(), live => $live3, guard => { locked => 1 },
        agent => 'gitfix-analysis', phase => 'analyze');
    ok($res && $res->{provider} eq 'ollama' && $res->{model} eq 'gemma4-64k:latest',
        'Ollama hop is taken when the tag is installed and nothing earlier is live') or diag($line);
}

# --- 6. quality floor: never qwen2.5vl:3b for programming while a chain entry is live
{
    is(Comserv::Model::AI2::ModelPick->is_weak_for_coding('qwen2.5vl:3b'), 1,
        'qwen2.5vl:3b is classified weak for coding (vision + 3B)');
    is(Comserv::Model::AI2::ModelPick->is_weak_for_coding('gemma4-64k:latest'), 0,
        'gemma4-64k is not weak');
    is(Comserv::Model::AI2::ModelPick->is_weak_for_coding('particle-ai/particle-1'), 0,
        'particle-1 is not weak');

    # Catalog contains the vision model AND a live chain model.
    my $catalog = [
        { id => 'qwen2.5vl:3b', name => 'qwen2.5vl:3b', provider => 'ollama' },
        { id => 'baidu/ernie-5.5-flash-preview:free', name => 'baidu/ernie-5.5-flash-preview:free',
          provider => 'openrouter', free => 1 },
    ];
    ($obj, $log) = mp();
    my $ctx = FakeCtx->new(catalog => $catalog, guard => { locked => 1 });
    my $res = $obj->coding_pick($ctx,
        agent_id => 'programming', phase => 'plan',
        chain => chain_entries(),
        live  => { 'openrouter|baidu/ernie-5.5-flash-preview:free' => 1 });
    ok($res && $res->{ok} && $res->{model} eq 'baidu/ernie-5.5-flash-preview:free',
        'programming picks the live chain model, never ollama|qwen2.5vl:3b') or diag($log->joined);
    unlike($log->joined, qr/chose=ollama\|qwen2\.5vl/, 'qwen2.5vl:3b is never chosen while a chain model is live');
}

# --- 7. everything unavailable -> weak model allowed but with a notice -----
{
    my $catalog = [ { id => 'qwen2.5vl:3b', name => 'qwen2.5vl:3b', provider => 'ollama' } ];
    ($obj, $log) = mp();
    my $ctx = FakeCtx->new(catalog => $catalog, guard => { locked => 1 });
    my $res = $obj->coding_pick($ctx,
        agent_id => 'programming', phase => 'plan',
        chain => chain_entries(), live => {});
    ok($res && $res->{ok}, 'exhausted chain still returns a model instead of dying') or diag($log->joined);
    ok($res->{weak}, 'the returned model is flagged weak');
    like($res->{notice} // '', qr/small\/vision|not live/i,
        'a clear notice accompanies the weak pick (not silent)') or diag($res->{notice} // 'no notice');
    like($log->joined, qr/WEAK fallback/, 'the weak fallback is logged at warn');
}

# --- 8. coding-agent detection + log line shape ---------------------------
{
    my $mp = 'Comserv::Model::AI2::ModelPick';
    ok($mp->is_coding_agent('programming'), 'programming is a coding agent');
    ok($mp->is_coding_agent('gitfix-analysis'), 'gitfix-analysis is a coding agent');
    ok(!$mp->is_coding_agent('documentation'), 'documentation is not a coding agent');

    ($obj, $log) = mp();
    my ($res, $line) = $obj->pick_from_chain(FakeCtx->new,
        chain => chain_entries(), live => \%LIVE_ERN, guard => { locked => 1 },
        agent => 'programming', phase => 'plan');
    like($line, qr/^agent=programming phase=plan chain=\[/, 'pick log names agent + phase + chain');
    like($line, qr/chose=openrouter\|baidu/, 'pick log names the chosen model');
}

done_testing();
