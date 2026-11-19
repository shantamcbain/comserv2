package t_ai_guard_auto_move;

# t/ai_guard_auto_move.t - todo #2759
# Pure unit tests for Comserv::Util::AI::GuardAutoMove: no network, no DB,
# no Catalyst; the only file written lives in a File::Temp tempdir.

use strict;
use warnings;

use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use File::Temp qw(tempdir);
use JSON::PP;

require_ok 'Comserv::Util::AI::HermesOverrunGuard';
require_ok 'Comserv::Util::AI::GuardAutoMove';

my $G = 'Comserv::Util::AI::GuardAutoMove';

# ---------------------------------------------------------------------------
# Fixtures (shaped like HermesOverrunGuard::chain_candidates output)
# ---------------------------------------------------------------------------
my $sg   = { name => 'xai-oauth/grok-4.7', provider => 'xai-oauth', default => 'grok-4.7', sg_budget => 1 };
my $part = { name => 'openrouter/particle-ai/particle-1', provider => 'openrouter', default => 'particle-ai/particle-1', paid => 1 };
my $ern  = { name => 'openrouter/baidu/ernie-5.5-flash-preview:free', provider => 'openrouter', default => 'baidu/ernie-5.5-flash-preview:free', free => 1 };
my $gem  = { name => 'ollama-launch/gemma4-64k:latest', provider => 'ollama-launch', default => 'gemma4-64k:latest', ollama => 'gemma4-64k:latest', free => 1 };
my $vl   = { provider => 'ollama-launch', default => 'qwen2.5vl:3b', ollama => 1 };
my $glm  = { provider => 'openrouter', default => 'z-ai/glm-5' };
my $orgrok = { provider => 'openrouter', default => 'x-ai/grok-4.5' };
my $build  = { provider => 'xai-oauth', default => 'grok-build-0.1' };

my $capcb = sub {
    my ($p, $m) = @_;
    return ($p eq 'openrouter' && $m !~ /:free\z/)
        ? 'OpenRouter cap reached - no paid model is allowed'
        : undef;
};

my $offender = {
    session  => 'local-beab3515',
    provider => 'openrouter',
    model    => 'particle-ai/particle-1',
    reason   => 'OpenRouter cap reached - no paid model is allowed',
};

my $chain = [
    { tier => 'supergrok', provider => 'xai-oauth',  model => 'grok-4.7' },
    { tier => 'paid',      provider => 'openrouter', model => 'particle-ai/particle-1' },
    { tier => 'free',      provider => 'openrouter', model => 'baidu/ernie-5.5-flash-preview:free' },
    { tier => 'local',     provider => 'ollama',     model => 'gemma4-64k:latest' },
];

# ---------------------------------------------------------------------------
# forbidden_target
# ---------------------------------------------------------------------------
ok(defined $G->forbidden_target($glm),    'glm is a forbidden target');
ok(defined $G->forbidden_target($orgrok), 'OpenRouter x-ai grok is forbidden');
ok(defined $G->forbidden_target($build),  'grok-build is forbidden');
ok(defined $G->forbidden_target($vl),     'vision-only / sub-7B local model is forbidden');

is($G->forbidden_target($ern),  undef, 'ernie :free is not forbidden');
is($G->forbidden_target($gem),  undef, 'gemma4-64k local is not forbidden');
is($G->forbidden_target($part), undef, 'particle-1 is not forbidden by name');

# ---------------------------------------------------------------------------
# first_allowed
# ---------------------------------------------------------------------------
my $fa1 = $G->first_allowed(
    candidates => [ $sg, $part, $ern, $gem ],
    reason_cb  => $capcb,
    sg_ok      => 0,
);
is(ref $fa1, 'HASH', 'first_allowed returns a hash when something is allowed');
is($fa1->{default}, 'baidu/ernie-5.5-flash-preview:free',
    'Super Grok skipped without budget, particle blocked by cap -> ernie');

my $fa2 = $G->first_allowed(
    candidates => [ $sg, $part, $ern, $gem ],
    reason_cb  => $capcb,
    sg_ok      => 1,
);
is($fa2->{default}, 'grok-4.7', 'with Super Grok budget the supergrok tier wins');

my $fa3 = $G->first_allowed(
    candidates => [ $glm, $orgrok, $vl, $part, $gem ],
    reason_cb  => $capcb,
    sg_ok      => 0,
);
is($fa3->{default}, 'gemma4-64k:latest',
    'forbidden and capped candidates are skipped down to the local model');

my $fa4 = $G->first_allowed(
    candidates => [ $part, $ern, $gem ],
    reason_cb  => $capcb,
    sg_ok      => 0,
    skip       => { 'baidu/ernie-5.5-flash-preview:free' => 1 },
);
is($fa4->{default}, 'gemma4-64k:latest', 'skip hash excludes the ernie fallback');

is($G->first_allowed(candidates => [ $part ], reason_cb => $capcb, sg_ok => 0),
    undef, 'all candidates blocked -> undef');

my $copy = $G->first_allowed(candidates => [ $ern ], reason_cb => $capcb, sg_ok => 0);
is(ref $copy, 'HASH', 'copy test candidate returned');
$copy->{default} = 'mutated-by-test';
is($ern->{default}, 'baidu/ernie-5.5-flash-preview:free',
    'first_allowed returns a copy, not the fixture hash');

# ---------------------------------------------------------------------------
# move_plan
# ---------------------------------------------------------------------------
my $plan = $G->move_plan(
    offenders  => [ $offender ],
    candidates => [ $sg, $part, $ern, $gem ],
    reason_cb  => $capcb,
    sg_ok      => 0,
    now        => 1000,
);
ok($plan, 'move_plan returns a plan');
is(ref $plan->{target}, 'HASH', 'plan has a target hash');
is($plan->{target}{default}, 'baidu/ernie-5.5-flash-preview:free',
    'plan target is the allowed ernie fallback');
is($plan->{from}, 'openrouter/particle-ai/particle-1', 'plan records the offending model');
is($plan->{none}, 0, 'plan is not a none-plan');
like($plan->{key}, qr{^local-beab3515:openrouter/particle-ai/particle-1$},
    'plan key is session:provider/model');

is($G->move_plan(
        offenders  => [ $offender ],
        candidates => [ $sg, $part, $ern, $gem ],
        reason_cb  => $capcb,
        sg_ok      => 0,
        now        => 1000,
        last       => { key => $plan->{key}, at => 900 },
    ),
    undef, 'cooldown window suppresses a repeat plan');

my $plan2 = $G->move_plan(
    offenders  => [ $offender ],
    candidates => [ $sg, $part, $ern, $gem ],
    reason_cb  => $capcb,
    sg_ok      => 0,
    now        => 1000,
    last       => { key => $plan->{key}, at => 1000 - 1801 },
);
ok($plan2, 'plan is produced again once the cooldown has elapsed');

is($G->move_plan(
        offenders  => [],
        candidates => [ $gem ],
        reason_cb  => $capcb,
        sg_ok      => 0,
        now        => 1000,
    ),
    undef, 'no offenders -> no plan');

my $plan3 = $G->move_plan(
    offenders  => [ $offender ],
    candidates => [ $part ],
    reason_cb  => $capcb,
    sg_ok      => 0,
    now        => 1000,
);
ok($plan3, 'all-blocked case still returns a plan');
is($plan3->{none}, 1, 'all-blocked plan is flagged none');
is($plan3->{target}, undef, 'all-blocked plan has no target');

# ---------------------------------------------------------------------------
# safe_switch_target
# ---------------------------------------------------------------------------
my $sw0 = $G->safe_switch_target(
    target     => $part,
    or_over    => 0,
    candidates => [ $sg, $part, $ern, $gem ],
    reason_cb  => $capcb,
    sg_ok      => 0,
);
is($sw0->{default}, 'particle-ai/particle-1', 'cap not hit -> paid target kept');

my $sw1 = $G->safe_switch_target(
    target     => $part,
    or_over    => 1,
    candidates => [ $sg, $part, $ern, $gem ],
    reason_cb  => $capcb,
    sg_ok      => 0,
);
is($sw1->{default}, 'baidu/ernie-5.5-flash-preview:free',
    'cap hit -> blocked paid target replaced by ernie');
is($sw1->{replaced}, 'particle-ai/particle-1', 'replacement records the blocked model');

my $sw2 = $G->safe_switch_target(
    target     => $part,
    or_over    => 1,
    candidates => [ $sg, $part, $ern, $gem ],
    reason_cb  => sub { undef },
    sg_ok      => 0,
);
is($sw2->{default}, 'particle-ai/particle-1',
    'trial still active (no reason) -> paid target kept');

my $sw3 = $G->safe_switch_target(
    target     => $ern,
    or_over    => 1,
    candidates => [ $sg, $part, $ern, $gem ],
    reason_cb  => $capcb,
    sg_ok      => 0,
);
is($sw3->{default}, 'baidu/ernie-5.5-flash-preview:free',
    'already-allowed free target is kept as-is');

# ---------------------------------------------------------------------------
# Real HermesOverrunGuard glue: safe_trip_target
# ---------------------------------------------------------------------------
my $trip1 = $G->safe_trip_target(
    $part,
    reasons   => ['OpenRouter day $3.10 of $3 over the 100% rule'],
    chain     => $chain,
    emergency => [],
    supergrok => { locked => 1 },
);
is(ref $trip1, 'HASH', 'safe_trip_target returns a target hash');
is($trip1->{default}, 'baidu/ernie-5.5-flash-preview:free',
    'OpenRouter cap trip retargets the blocked paid model to ernie');

my $trip2 = $G->safe_trip_target(
    $part,
    reasons   => ['thrash: 40 calls'],
    chain     => $chain,
    emergency => [],
    supergrok => { locked => 1 },
);
is($trip2->{default}, 'particle-ai/particle-1',
    'non-OpenRouter trip reason leaves the paid target alone');

my $trip3 = $G->safe_trip_target(
    $part,
    reasons      => ['OpenRouter day $3.10 of $3 over the 100% rule'],
    chain        => $chain,
    emergency    => [],
    supergrok    => { locked => 1 },
    trial_active => { 'particle-ai/particle-1' => 'particle_1' },
);
is($trip3->{default}, 'particle-ai/particle-1',
    'active trial keeps the paid target even when the cap is hit');

# ---------------------------------------------------------------------------
# enforce_move against the real guard writer
# ---------------------------------------------------------------------------
{
    package FakeGuard;
    our @ISA = ('Comserv::Util::AI::HermesOverrunGuard');
    sub log_line { push @{ $_[0]{lines} }, $_[1] }
}

sub read_json {
    my ($path) = @_;
    open my $fh, '<', $path or die "cannot read $path: $!";
    local $/;
    my $raw = <$fh>;
    close $fh or die "cannot close $path: $!";
    return decode_json($raw);
}

my $home   = tempdir(CLEANUP => 1);
my $swfile = "$home/guard_model_switch.json";

open my $out, '>', $swfile or die "cannot write $swfile: $!";
print {$out} encode_json({ generation => 17, source => 'supergrok_daily_guard' });
close $out or die "cannot close $swfile: $!";

my $s = bless { hermes_home => $home, lines => [] }, 'FakeGuard';
my $st = {};
my $offs = [ { %$offender } ];

my $mv = $G->enforce_move(
    $s,
    state     => $st,
    offenders => $offs,
    ctx       => { chain => $chain, emergency => [], supergrok => { locked => 1 } },
    pol       => { or_over => 1 },
    now       => 1795030000,
);
ok($mv, 'enforce_move returns a move record');
is(ref $mv->{target}, 'HASH', 'enforce_move plan has a target');
is($mv->{target}{default}, 'baidu/ernie-5.5-flash-preview:free',
    'enforce_move target is the allowed ernie fallback');
is($mv->{generation}, 18, 'enforce_move reports generation 18');

my $rec = read_json($swfile);
is($rec->{generation}, 18, 'switch file generation bumped to 18');
is($rec->{reason}, 'enforce_move', 'switch file reason is enforce_move');
is($rec->{source}, 'overrun_guard', 'switch file source is overrun_guard');
is(ref $rec->{model}, 'HASH', 'switch file carries a model hash');
is(ref $rec->{model} eq 'HASH' ? $rec->{model}{default} : undef,
    'baidu/ernie-5.5-flash-preview:free', 'switch file model.default is ernie');

is($st->{enforce_move}{key}, $mv->{key}, 'state records the plan key');

is(scalar @{ $s->{lines} }, 1, 'enforce_move logged exactly one line');
like($s->{lines}[0],
    qr{^ENFORCE_MOVE openrouter/particle-ai/particle-1 -> openrouter/baidu},
    'log line names the from/to models');

my $mv2 = $G->enforce_move(
    $s,
    state     => $st,
    offenders => $offs,
    ctx       => { chain => $chain, emergency => [], supergrok => { locked => 1 } },
    pol       => { or_over => 1 },
    now       => 1795030000 + 60,
);
is($mv2, undef, 'second enforce_move inside the cooldown returns undef');

my $rec2 = read_json($swfile);
is($rec2->{generation}, 18, 'switch file generation unchanged on cooldown');
is(scalar @{ $s->{lines} }, 1, 'no extra log line on cooldown');

done_testing();
