use strict; use warnings; use POSIX (); use Test::More; use File::Temp qw(tempdir);
use FindBin; use lib "$FindBin::Bin/../lib"; use JSON::PP;
use Comserv::Util::AI::HermesOverrunGuard; use Comserv::Util::AI::ModelChains;
my $G = 'Comserv::Util::AI::HermesOverrunGuard'; my $MC = 'Comserv::Util::AI::ModelChains';
# Oct 26 2026: Hermes fallback chain (Super Grok > paid qwen3-coder > free north-mini LAST), billing channels
# (Super Grok / x.ai direct / OpenRouter) and sessions pinned on a disallowed model (Oct 25 $6.04 overrun).
$Comserv::Util::AI::HermesOverrunGuard::COOLDOWN_S = 0;
my $IDS = { map { ($_ => 1) } 'cohere/north-mini-code:free', 'nvidia/nemotron-3.5-lightning:free', 'qwen/qwen3-coder', 'x-ai/grok-4.7', 'deepseek/deepseek-v4.1-flash' };
my $SG_OFF = { mode => 'openrouter', locked => 1, off_today => 1 };
my $SG_OK  = { mode => 'grok', remaining => 60, locked => 0, off_today => 0 };

# ---- ModelChains: the chain lives in data/ai_model_chains.json ----
my $ld = $MC->load(undef, path => "$FindBin::Bin/../data/ai_model_chains.json", logger => sub {});
is $ld->{source}, 'file', 'data file loads and validates';
my @ch = $MC->hermes_chain($ld);
is_deeply [ map { $_->{tier} } @ch ], [qw(supergrok paid free)], 'chain tiers: Super Grok, paid, free';
like $ch[1]{slug}, qr{qwen/qwen3-coder}, 'step 2 is qwen3-coder'; like $ch[-1]{slug}, qr/north-mini/, 'north-mini is LAST';
{
    my %d = %{ $MC->perl_default };
    my ($ok, $e) = $MC->validate_structure({ %d, hermes_fallback_chain => ['openrouter|cohere/north-mini-code:free', 'openrouter|qwen/qwen3-coder'] });
    ok !$ok && "@$e" =~ /north-mini must be the last|paid step/, 'north before paid rejected';
    ($ok, $e) = $MC->validate_structure({ %d, hermes_fallback_chain => ['openrouter|x-ai/grok-4.7'] });
    ok !$ok && "@$e" =~ /banned on openrouter/, 'openrouter grok step rejected';
    ($ok, $e) = $MC->validate_structure({ %d, hermes_fallback_chain => ['openrouter|z-ai/glm-5'] });
    ok !$ok && "@$e" =~ /banned/, 'glm step rejected';
    ($ok, $e) = $MC->validate_structure({ %d, hermes_fallback_chain => ['supergrok|grok-4.7', 'openrouter|qwen/qwen3-coder', 'openrouter|cohere/north-mini-code:free'] });
    ok $ok, 'good chain accepted';
    is $MC->channel_caps($ld, 'xai_direct')->{day}, 0, 'x.ai direct cash cap defaults to $0 (off)';
    is $MC->channel_caps($ld, 'openrouter')->{week}, 11.5, 'OpenRouter weekly cap $11.50';
}
my @CH = @ch; my @EM = $MC->hermes_chain($ld, emergency => 1);
my %base = (or_ids => $IDS, health => {}, ollama_models => ['gemma4-64k:latest'], chain => \@CH, emergency => \@EM, kind => 'caps');

# ---- pick_target follows the chain ----
is $G->can('pick_target')->(%base, supergrok => $SG_OK)->{default}, 'grok-4.7', 'Super Grok has budget -> grok-4.7';
is $G->can('pick_target')->(%base, supergrok => $SG_OFF, paid_ok => 1)->{default}, 'qwen/qwen3-coder', 'grok unavailable + room under caps -> paid qwen3-coder first';
is $G->can('pick_target')->(%base, supergrok => $SG_OFF, paid_ok => 0)->{default}, 'cohere/north-mini-code:free', 'no room under caps -> north-mini';
is $G->can('pick_target')->(%base, supergrok => $SG_OFF, paid_ok => 1, or_ids => { %$IDS, 'qwen/qwen3-coder' => 0 })->{default}, 'cohere/north-mini-code:free', 'qwen not in the OpenRouter list -> north-mini';
is $G->can('pick_target')->(%base, supergrok => $SG_OFF, paid_ok => 1, health => { 'openrouter|qwen/qwen3-coder' => { state => 'open' } })->{default}, 'cohere/north-mini-code:free', 'qwen circuit open -> north-mini';
is $G->can('pick_target')->(%base, supergrok => $SG_OFF, paid_ok => 1, health => { 'openrouter|qwen/qwen3-coder' => { state => 'open' }, 'openrouter|cohere/north-mini-code:free' => { state => 'open' } })->{provider},
   'ollama-launch', 'north-mini only skipped when unusable: emergency tail after it';
# thrash trips never move to a paid model (money safety)
isnt $G->can('pick_target')->(%base, supergrok => $SG_OFF, paid_ok => 1, kind => 'thrash')->{default}, 'qwen/qwen3-coder', 'thrash trip does not pick a paid model';
my @order = map { $_->{name} } $G->can('candidate_order')->('caps', undef, $SG_OFF, chain => \@CH, emergency => \@EM);
is $order[0], 'xai-oauth/grok-4.7', 'order: Super Grok first'; is $order[1], 'openrouter/qwen/qwen3-coder', 'order: paid second';
is $order[2], 'openrouter/cohere/north-mini-code:free', 'order: north-mini third (last chain step)';
ok((grep { $order[$_] =~ /gemma4|nemotron|qwen2\.5-coder/ } 3 .. $#order) == @order - 3, 'emergency tail follows north-mini');
# permanent fallback list
my $fc = $G->can('fallback_chain')->(%base, supergrok => $SG_OK, paid_ok => 1);
is_deeply [ map { "$_->{provider}/$_->{model}" } @$fc ],
    [ 'xai-oauth/grok-build-0.1', 'openrouter/qwen/qwen3-coder', 'openrouter/cohere/north-mini-code:free', 'ollama-launch/gemma4-64k:latest', 'openrouter/nvidia/nemotron-3.5-lightning:free' ],
    'fallback_providers: Super Grok build > paid qwen > north-mini > emergency';
$fc = $G->can('fallback_chain')->(%base, supergrok => $SG_OK, paid_ok => 0);
ok !grep({ $_->{model} =~ /qwen/ } @$fc), 'no paid step in fallback_providers when caps have no room';

# ---- paid_room ----
my $caps = { day => 1.65, week => 11.5, month => 50 };
ok  $G->can('paid_room')->({ ok => 1, day_usd => 0.5, week_usd => 3, month_usd => 10 }, $caps, []), 'room: low use';
ok !$G->can('paid_room')->({ ok => 1, day_usd => 1.0, week_usd => 3, month_usd => 10 }, $caps, []), 'no room: day >= 60% of cap';
ok !$G->can('paid_room')->({ ok => 1, day_usd => 0.1, week_usd => 3, month_usd => 46 }, $caps, []), 'no room: month >= 90% of cap';
ok !$G->can('paid_room')->({ ok => 1, day_usd => 0.1, week_usd => 3, month_usd => 4 }, $caps, ['OpenRouter day $2 over $1.65 cap']), 'no room: money-cap reason';
ok !$G->can('paid_room')->({ ok => 0 }, $caps, []), 'no room: usage unknown';

# ---- billing channels and labels ----
my $bc = $G->can('billing_channel');
is $bc->('xai-oauth', 'grok-4.7'), 'supergrok', 'xai-oauth = Super Grok quota';
is $bc->('xai', 'grok-4.7'), 'xai_direct', 'xai = x.ai direct API (cash)';
is $bc->('openrouter', 'x-ai/grok-4.7'), 'openrouter', 'OpenRouter grok bills on OpenRouter';
like $G->can('billing_label')->('openrouter', 'x-ai/grok-4.7'), qr{openrouter/x-ai/grok-4\.7 \[OpenRouter grok \(paid\)\]}, 'label names provider, model and who bills';
like $G->can('billing_label')->('openrouter', 'deepseek/deepseek-v4.1-flash'), qr/OpenRouter paid/, 'label paid OpenRouter';
like $G->can('billing_label')->('xai', 'grok-4.7'), qr/x\.ai direct API/, 'label x.ai direct';
is $G->can('classify_call')->({ provider => 'xai', model => 'grok-4.7' }), 'xai_direct', 'thrash class x.ai direct apart from supergrok';

# ---- offender_reason / session_offenders (the Oct 25 sessions) ----
my %pol = (tripped => 1, allowed_paid => { 'qwen/qwen3-coder' => 1 }, xai_direct_cap_day => 0, or_over => 0, sg_unavailable => 1);
my $off = $G->can('offender_reason');
like $off->('openrouter', 'x-ai/grok-4.7', %pol), qr/grok is blocked/, 'OpenRouter grok is an offender (12:16 PM session)';
like $off->('openrouter', 'deepseek/deepseek-v4.1-flash', %pol), qr/not in the Hermes chain/, 'unlisted paid model is an offender while tripped (1:22 PM session)';
is $off->('openrouter', 'qwen/qwen3-coder', %pol), undef, 'chain paid step is allowed';
is $off->('openrouter', 'cohere/north-mini-code:free', %pol), undef, 'free model is allowed';
like $off->('openrouter', 'qwen/qwen3-coder', %pol, or_over => 1), qr/cap reached/, 'even the chain paid step stops at the OpenRouter cap';
like $off->('xai', 'grok-4.7', %pol), qr/x\.ai direct API is off/, 'x.ai direct off while its cap is $0';
is $off->('xai', 'grok-4.7', %pol, xai_direct_cap_day => 2), undef, 'x.ai direct allowed under its own cap';
is $off->('xai-oauth', 'grok-4.7', %pol), undef, 'Super Grok is never a cash offender';
is $off->('openrouter', 'deepseek/deepseek-v4.1-flash', tripped => 0, sg_unavailable => 0, allowed_paid => {}), undef, 'untripped, Super Grok up: paid use is only counted';
like $off->('openrouter', 'deepseek/deepseek-v4.1-flash', tripped => 0, sg_unavailable => 1, allowed_paid => {}), qr/only the chain paid step/, 'grok unavailable: unlisted paid model is an offender even before a trip';
my $recent = {
    a => { session => 'local-f2f8', provider => 'openrouter', model => 'x-ai/grok-4.7', calls => 20, usd => 5.88, last_t => 100 },
    b => { session => 'local-f2f8', provider => 'openrouter', model => 'cohere/north-mini-code:free', calls => 3, usd => 0, last_t => 90 },
    c => { session => 'local-aaaa', provider => 'xai-oauth', model => 'grok-4.7', calls => 5, usd => 0, last_t => 80 },
};
my $so = $G->can('session_offenders')->($recent, %pol);
is scalar(@$so), 1, 'only the billing offender is listed'; is $so->[0]{model}, 'x-ai/grok-4.7', 'offender model';
my $bs = $G->can('billing_summary')->($recent, 2);
like $bs->[0]{label}, qr{openrouter/x-ai/grok-4\.7}, 'billing summary leads with what costs money';

# ---- decide: x.ai direct has its own cap ----
my $ok = { ok => 1, day_usd => 0.1, week_usd => 1, month_usd => 2 };
my $dd = $G->can('decide')->(thrash => 0, openrouter => $ok, state => {}, xai_direct => { usd => 2.5, cap_day => 2 });
is $dd->{action}, 'trip', 'x.ai direct over its day cap trips'; like $dd->{reasons}[0], qr/^x\.ai direct day/, 'reason names x.ai direct';
is $G->can('trip_kind')->($dd->{reasons}), 'caps', 'x.ai direct trip is a caps (cash) trip';
is $G->can('decide')->(thrash => 0, openrouter => $ok, state => {}, xai_direct => { usd => 5, cap_day => 0 })->{action}, 'none', 'cap 0 means off, enforced per session, not a day-cap trip';

# ---- live_spend: per-channel cash and recent sessions from agent.log ----
{
    my $h = tempdir(CLEANUP => 1); mkdir "$h/.hermes"; mkdir "$h/.hermes/logs";
    my $now = time;
    my $ts = sub { my $t = shift; POSIX::strftime('%Y-%m-%d %H:%M:%S,000', gmtime($t)) };
    open my $fh, '>', "$h/.hermes/logs/agent.log";
    print $fh $ts->($now - 60)  . " INFO [sessA] agent.conversation_loop: API call #1: model=x-ai/grok-4.7 provider=openrouter in=100000 out=500 total=1 latency=2s\n";
    print $fh $ts->($now - 50)  . " INFO [sessA] agent.conversation_loop: API call #2: model=x-ai/grok-4.7 provider=openrouter in=100000 out=500 total=1 latency=2s\n";
    print $fh $ts->($now - 40)  . " INFO [sessB] agent.conversation_loop: API call #1: model=grok-4.7 provider=xai in=100000 out=500 total=1 latency=2s\n";
    print $fh $ts->($now - 30)  . " INFO [sessC] agent.conversation_loop: API call #1: model=grok-4.7 provider=xai-oauth in=100000 out=500 total=1 latency=2s\n";
    print $fh $ts->($now - 20)  . " INFO [sessD] agent.conversation_loop: API call #1: model=cohere/north-mini-code:free provider=openrouter in=1000 out=50 total=1 latency=2s\n";
    close $fh;
    my $g = $G->new(home => $h, app_root => $h, no_ledger => 1, no_notify => 1, base_urls => [], now => $now, or_ids => $IDS, supergrok => {});
    no warnings 'redefine'; local *Comserv::Util::AI::HermesOverrunGuard::openrouter_endpoints = sub { {} };
    my $l = $g->live_spend;
    ok $l->{ok}, 'live_spend reads agent.log';
    is $l->{by_channel}{openrouter}{calls}, 3, 'OpenRouter channel: its 3 calls only';
    is $l->{by_channel}{xai_direct}{calls}, 1, 'x.ai direct channel counted apart';
    ok $l->{by_channel}{xai_direct}{usd} > 0, 'x.ai direct has an estimated cash cost';
    is $l->{by_channel}{supergrok}{calls}, 1, 'Super Grok channel counted, no cash'; is $l->{by_channel}{supergrok}{usd}, 0, 'Super Grok cash 0';
    is $l->{calls}, 3, 'calls field stays OpenRouter-only';
    is scalar(keys %{ $l->{recent} }), 4, 'recent sessions listed';
    # run(): offender -> gate file + one alert, only on change
    open my $cf, '>', "$h/.hermes/config.yaml"; print $cf "model:\n  default: grok-4.7\n  provider: xai-oauth\n  base_url: https://api.x.ai/v1\n  api_mode: codex_responses\n"; close $cf;
    my @notes;
    my $g2 = $G->new(home => $h, app_root => $h, no_ledger => 1, no_notify => 1, base_urls => [], now => $now, or_ids => $IDS, supergrok => $SG_OFF,
                     set_cb => sub {}, ollama_url => 'http://127.0.0.1:9');
    my $r = $g2->run(force => 1, thrash => 0, thrash_by_class => { ok => 1, counts => {} }, openrouter => { ok => 1, day_usd => 0.1, week_usd => 1, month_usd => 2 }, live => $l);
    ok $r->{offenders} && @{ $r->{offenders} } >= 2, 'run lists the pinned OpenRouter grok and x.ai direct sessions';
    my $gate = decode_json(do { local $/; open my $gf, '<', "$h/.hermes/overrun_gate.json" or die "no gate: $!"; <$gf> });
    is $gate->{active}, 1, 'gate active'; like $gate->{message}, qr{/model code}, 'gate tells the user how to re-point';
    ok((grep { $_->{session} eq 'sessA' } @{ $gate->{sessions} }), 'gate lists the OpenRouter grok session');
    is $r->{gate}, 'written', 'gate written';
    my $n1 = () = do { local $/; open my $lf, '<', "$h/.hermes/overrun_guard_events.jsonl" or die; my $t = <$lf>; $t =~ /"action":"enforce"/g };
    $r = $g2->run(force => 1, thrash => 0, thrash_by_class => { ok => 1, counts => {} }, openrouter => { ok => 1, day_usd => 0.1, week_usd => 1, month_usd => 2 }, live => $l);
    is $r->{gate}, 'unchanged', 'same state: gate not rewritten';
    my $n2 = () = do { local $/; open my $lf, '<', "$h/.hermes/overrun_guard_events.jsonl" or die; my $t = <$lf>; $t =~ /"action":"enforce"/g };
    is $n2, $n1, 'same offenders: no second alert/event (alerts only on change)';
    # offender gone -> gate cleared
    $r = $g2->run(force => 1, thrash => 0, thrash_by_class => { ok => 1, counts => {} }, openrouter => { ok => 1, day_usd => 0.1, week_usd => 1, month_usd => 2 },
                  live => { ok => 1, day_usd => 0, calls => 0, recent => {}, by_channel => {} });
    is $r->{gate}, 'cleared', 'no offenders: gate cleared';
    is decode_json(do { local $/; open my $gf, '<', "$h/.hermes/overrun_gate.json"; <$gf> })->{active}, 0, 'gate inactive';
    my $stf = decode_json(do { local $/; open my $sf, '<', "$h/.hermes/overrun_guard_state.json" or die; <$sf> });
    ok ref $stf->{cash} eq 'HASH' && exists $stf->{cash}{openrouter}{month_usd} && ref $stf->{cash}{paid_why} eq 'ARRAY', 'run publishes the cash snapshot (numbers only) for the daily guard';
}

# ---- Oct 26 (2): opt-in cash steps for the daily lock (default OFF) ----
{
    my %d = %{ $MC->perl_default };
    ok !$MC->hermes_cash_steps($ld) , 'cash steps: none by default (setting exists, enabled=false in the data file)';
    is $ld->{data}{hermes_daily_lock_cash}{enabled} ? 1 : 0, 0, 'hermes_daily_lock_cash.enabled is false in data/ai_model_chains.json';
    my @on = $MC->hermes_cash_steps({ %d, hermes_daily_lock_cash => { enabled => JSON::PP::true, steps => ['xai_direct|grok-4.7', 'openrouter|x-ai/grok-4.7'] } });
    is_deeply [ map { "$_->{provider}/$_->{model}" } @on ], ['xai/grok-4.7', 'openrouter/x-ai/grok-4.7'], 'enabled: x.ai direct then OpenRouter grok';
    ok !(() = $MC->hermes_cash_steps({ %d, hermes_daily_lock_cash => { enabled => JSON::PP::false } })), 'enabled=false: no steps';
    my ($ok, $e) = $MC->validate_structure({ %d, hermes_daily_lock_cash => { enabled => 1, steps => ['xai_direct|grok-4.7', 'openrouter|x-ai/grok-4.7'] } });
    ok $ok, 'cash setting accepts grok steps (the only place OpenRouter grok is allowed)';
    ($ok, $e) = $MC->validate_structure({ %d, hermes_daily_lock_cash => { enabled => 1, steps => ['openrouter|qwen/qwen3-coder'] } });
    ok !$ok && "@$e" =~ /not a grok model/, 'cash setting refuses non-grok steps';
    ($ok, $e) = $MC->validate_structure({ %d, hermes_daily_lock_cash => { enabled => 1, steps => ['openrouter|deepseek/deepseek-v4-pro'] } });
    ok !$ok, 'cash setting refuses v4-pro';
    ($ok, $e) = $MC->validate_structure({ %d, hermes_daily_lock_cash => { enabled => 'maybe' } });
    ok !$ok && "@$e" =~ /enabled must be/, 'cash enabled must be a boolean';
    ($ok, $e) = $MC->validate_structure({ %d, hermes_fallback_chain => ['supergrok|grok-4.7', 'openrouter|x-ai/grok-4.7'] });
    ok !$ok && "@$e" =~ /banned on openrouter/, 'the chain itself still bans OpenRouter grok';
    my @why = $G->can('paid_room_why')->({ ok => 1, day_usd => 0, week_usd => 0, month_usd => 45.82 }, { day => 1.65, week => 11.5, month => 50 }, []);
    is $why[0], 'OpenRouter month $45.82 of $50 over the 90% rule', 'paid_room_why wording';
    is scalar(() = $G->can('paid_room_why')->({ ok => 1, day_usd => 0, week_usd => 0, month_usd => 4 }, { day => 1.65, week => 11.5, month => 50 }, [])), 0, 'paid_room_why: empty when there is room';
}
done_testing;
