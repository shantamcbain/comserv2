use strict;
use warnings;
use utf8;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use File::Temp qw(tempdir);
use File::Copy qw(copy);
use JSON ();

# Model failover (AISYSTEM plan §5e). Mock providers only — no live model
# calls, no live DB, no real data/ files (temp copies).

BEGIN {
    use_ok('Comserv::Util::AI::ModelChains');
    use_ok('Comserv::Util::AI::ModelHealth');
    use_ok('Comserv::Util::AI::EvalAllowList');
    use_ok('Comserv::Model::AI2::Router');
}

{
    package T::Log;
    sub new { bless { lines => [] }, shift }
    sub log_with_details { my ($s, $c, $lvl, $f, $l, $sub, $msg) = @_; push @{ $s->{lines} }, "$lvl $sub " . ($msg // ''); 1 }
}
{
    package T::AI;
    sub new { bless { rows => [] }, shift }
    sub log_usage { my ($s, $c, %a) = @_; push @{ $s->{rows} }, \%a; 1 }
}
{
    package T::C;
    sub new { my ($cl, %a) = @_; bless { ai => T::AI->new, session => {} }, $cl }
    sub model { my ($s, $n) = @_; return $s->{ai} if $n eq 'AI'; die "no model $n in tests\n" }
    sub session { $_[0]{session} }
    sub rows { $_[0]{ai}{rows} }
}

my $DATA = "$FindBin::Bin/../data";
sub slurp { my $f = shift; open my $fh, '<:raw', $f or die "$f: $!"; local $/; my $x = <$fh>; close $fh; $x }
my $real_chains_before = slurp("$DATA/ai_model_chains.json");

# ── Mock provider table: slug -> response (or coderef) ───────────────────
my %SCRIPT;
my @CALLS;
no warnings 'redefine';
*Comserv::Model::AI2::Router::_chat_one_with_retry = sub {
    my ($self, $c, $prov, $model, $messages, %o) = @_;
    my $slug = "$prov|$model";
    push @CALLS, $slug;
    my $r = $SCRIPT{$slug};
    $r = $r->() if ref $r eq 'CODE';
    return $r ? { %$r } : { success => 0, error => "no script for $slug" };
};
*Comserv::Model::AI2::Router::pick_free_fallback = sub { return (undef, undef) };
*Comserv::Model::AI2::Router::_model_is_killed   = sub { return 0 };
use warnings 'redefine';

my $OK   = sub { my $t = shift // 'fine answer'; +{ success => 1, response => $t, usage => { prompt_tokens => 5, completion_tokens => 7, total_tokens => 12 } } };
my $FAIL = sub { +{ success => 0, error => shift } };

my $NOW = 1_800_000_000;
sub health { Comserv::Util::AI::ModelHealth->new(path => (shift // undef), now => sub { $NOW }) }

sub chains {
    my (%over) = @_;
    my $d = Comserv::Util::AI::ModelChains->perl_default;
    $d->{chain_chat} = [ 'openrouter|a/one:free', 'openrouter|b/two:free', 'openrouter|c/three:free' ];
    $d->{removed} = [];
    $d->{$_} = $over{$_} for keys %over;
    return { data => $d, source => 'file' };
}

my $router = Comserv::Model::AI2::Router->new(logging => T::Log->new);
my %BASE = (spend => { ok => 1, day => 0, week => 0, month => 0, by_model_day => {} },
            guard => { locked => 0 }, signals => { verdicts => {}, anomalies => [] });

sub run {
    my (%a) = @_;
    @CALLS = ();
    my $c = $a{c} || T::C->new;
    my $r = $router->chat_with_fallback($c, $a{provider} || 'openrouter', $a{model} || 'req/model:free',
        [ { role => 'user', content => 'hi' } ],
        %BASE, chains => $a{chains} || chains(), health => $a{health} || health(),
        purpose => 'chat', (map { $_ => $a{$_} } grep { exists $a{$_} } qw(spend guard signals postcheck ledger_meta failover)));
    return ($r, $c);
}

# ── 1. failure classification + failover per type ────────────────────────
my @types = (
    [ http_404 => $FAIL->('OpenRouter provider error: 404 Not Found - This model is unavailable for free') ],
    [ http_410 => $FAIL->('410 Gone') ],
    [ http_429 => $FAIL->('OpenRouter provider error: 429 Too Many Requests - Provider returned error') ],
    [ http_402 => $FAIL->('402 Payment Required: This request requires more credits') ],
    [ http_5xx => $FAIL->('OpenRouter provider error: 503 Service Unavailable') ],
    [ timeout  => $FAIL->('500 read timeout') ],
    [ empty_output      => { success => 1, response => "   \n", usage => {} } ],
    [ zero_tokens_empty => { success => 1, response => '', usage => { completion_tokens => 0, total_tokens => 0 } } ],
    [ zero_tokens       => { success => 1, response => 'echo', usage => { prompt_tokens => 9, completion_tokens => 0, total_tokens => 9 } } ],
);
for my $t (@types) {
    my ($want, $resp) = @$t;
    %SCRIPT = ('openrouter|req/model:free' => $resp, 'openrouter|a/one:free' => $OK->("answer after $want"));
    my ($r, $c) = run();
    ok($r->{success}, "$want: turn still answered");
    is($r->{response}, "answer after $want", "$want: answered by next chain step");
    is($r->{fallover}{attempt_no}, 2, "$want: attempt_no 2");
    is($r->{fallover}{fallback_from}, 'openrouter|req/model:free', "$want: fallback_from");
    is($r->{fallover}{fallback_reason}, $want, "$want: fallback_reason classified");
    is($r->{fallover}{final_model}, 'openrouter|a/one:free', "$want: final model");
    my ($row) = @{ $c->rows };
    is($row->{status}, 'error', "$want: failed attempt written to Ledger");
    is($row->{metadata}{fallover}{fallback_reason}, $want, "$want: Ledger metadata.fallover.fallback_reason");
    is($row->{metadata}{fallover}{attempt_no}, 1, "$want: Ledger attempt_no");
    is($row->{metadata}{fallover}{final_model}, 'openrouter|a/one:free', "$want: Ledger row carries final model");
}

# Ollama: non-empty text with no token counts = success, flagged tokens_unreported.
{
    %SCRIPT = ('ollama|qwen2.5-coder:14b' => { success => 1, response => 'local answer', usage => {} });
    my ($r) = run(provider => 'ollama', model => 'qwen2.5-coder:14b');
    ok($r->{success}, 'ollama non-empty 0-token text is a success');
    ok($r->{fallover}{tokens_unreported}, '... logged tokens_unreported');
    is($r->{fallover}{attempt_no}, 1, '... no failover');
    %SCRIPT = ('ollama|qwen2.5-coder:14b' => { success => 1, response => '', usage => {} },
               'openrouter|a/one:free' => $OK->());
    ($r) = run(provider => 'ollama', model => 'qwen2.5-coder:14b');
    is($r->{fallover}{fallback_reason}, 'empty_output', 'ollama empty text is a failure');
}

# Grounding post-check that strips everything fails over; second model's answer survives.
{
    %SCRIPT = ('openrouter|req/model:free' => $OK->('uncited claim'), 'openrouter|a/one:free' => $OK->('cited [G:1]'));
    my $pc = sub { my $t = shift; return $t =~ /\[G:1\]/ ? ($t, 0) : ('FALLBACK', 1) };
    my ($r, $c) = run(postcheck => $pc);
    is($r->{response}, 'cited [G:1]', 'post-check empty -> next model answered');
    is($r->{fallover}{fallback_reason}, 'postcheck_empty', '... reason postcheck_empty');
    ok($r->{postchecked}, '... Router ran the post-check (Chat.pm skips its own)');
    # All stripped: keep the honest fallback text, not all_exhausted.
    %SCRIPT = map { $_ => $OK->('uncited') } qw(openrouter|req/model:free openrouter|a/one:free openrouter|b/two:free openrouter|c/three:free);
    ($r) = run(postcheck => $pc);
    ok($r->{success}, 'every answer stripped -> still a reply');
    is($r->{response}, 'FALLBACK', '... the Golden Data fallback text');
    is($r->{fallover}{outcome}, 'postcheck_empty_all', '... outcome recorded');
}

# ── 2. circuit breaker: open, half-open probe, close / reopen ────────────
{
    my $dir = tempdir(CLEANUP => 1);
    my $h = health("$dir/ai_model_health.json");
    my $slug = 'openrouter|req/model:free';
    %SCRIPT = ($slug => $FAIL->('429 Too Many Requests'), 'openrouter|a/one:free' => $OK->());
    run(health => $h) for 1 .. 3;
    my $st = JSON->new->decode(slurp("$dir/ai_model_health.json"));
    is($st->{models}{$slug}{state}, 'open', 'circuit opens after 3 consecutive failures (file persisted)');
    is($st->{models}{$slug}{cooldown_until}, $NOW + 15 * 60, '... 15 min cooldown');
    my ($r) = run(health => $h);
    ok(!grep({ $_ eq $slug } @CALLS), 'open circuit: model skipped, not called');
    like(join(',', @{ $r->{fallover}{skipped} || [] }), qr/\Q$slug\E:circuit_open/, '... skip recorded');

    $NOW += 15 * 60 + 1;
    %SCRIPT = ($slug => $FAIL->('429 Too Many Requests'), 'openrouter|a/one:free' => $OK->());
    run(health => $h);
    is(scalar(grep { $_ eq $slug } @CALLS), 1, 'half-open: exactly one probe call');
    is($h->state_all->{models}{$slug}{state}, 'open', 'probe failed -> reopened');
    is($h->state_all->{models}{$slug}{open_reason}, 'probe_failed:http_429', '... reason probe_failed');

    $NOW += 15 * 60 + 1;
    is($h->check($slug)->{state}, 'half_open', 'cooldown over -> half_open');
    ok(!$h->check($slug)->{allow}, 'second concurrent caller does not get a probe');
    $NOW += 200;   # probe presumed lost after PROBE_TTL
    %SCRIPT = ($slug => $OK->('back'));
    ($r) = run(health => $h);
    is($r->{response}, 'back', 'probe success answered the turn');
    is($h->state_all->{models}{$slug}{state}, 'closed', 'probe success closes the circuit');

    # 404 is dead: opens at once with the long cooldown.
    my $h2 = health();
    %SCRIPT = ($slug => $FAIL->('404 Not Found'), 'openrouter|a/one:free' => $OK->());
    run(health => $h2);
    is($h2->state_all->{models}{$slug}{state}, 'open', '404 opens immediately');
    is($h2->state_all->{models}{$slug}{cooldown_until}, $NOW + 24 * 3600, '... 24h dead cooldown');

    # Anomalies from UsageMonitor open a closed circuit (dead_model = long).
    my $h3 = health();
    my $opened = $h3->apply_anomalies([ { kind => 'error_spike', provider => 'openrouter', model => 'b/two:free' },
                                        { kind => 'dead_model', provider => 'external', model => 'c/three:free' },
                                        { kind => 'thrash', provider => 'openrouter', model => 'a/one:free' } ],
                                      circuit_cooldown_minutes => 15, circuit_dead_cooldown_hours => 24);
    is_deeply([ sort @$opened ], [ 'openrouter|b/two:free', 'openrouter|c/three:free' ], 'error_spike + dead_model open circuits (external folded into openrouter)');
    is($h3->state_all->{models}{'openrouter|c/three:free'}{cooldown_until}, $NOW + 86400, 'dead_model uses the dead cooldown');
    is($h3->state_all->{models}{'openrouter|b/two:free'}{cooldown_until}, $NOW + 900, 'error_spike uses the normal cooldown');
}

# 0-token empty replies count toward the circuit too.
{
    my $h = health();
    $h->record_failure('openrouter|z/zero:free', 'zero_tokens_empty', circuit_failure_threshold => 3) for 1 .. 3;
    is($h->state_all->{models}{'openrouter|z/zero:free'}{state}, 'open', 'zero_tokens_empty x3 opens the circuit');
    my $h2 = health();
    $h2->record_failure('openrouter|z/zero:free', 'kill_switch', circuit_failure_threshold => 1);
    isnt(($h2->state_all->{models}{'openrouter|z/zero:free'} || {})->{state} // 'closed', 'open', 'non-circuit reasons (kill_switch) do not open it');
}

# ── 3. effectiveness verdicts: replace skipped, watch demoted ────────────
{
    %SCRIPT = map { $_ => $OK->($_) } qw(openrouter|a/one:free openrouter|b/two:free openrouter|c/three:free);
    $SCRIPT{'openrouter|req/model:free'} = $FAIL->('503 Service Unavailable');
    my $sig = { anomalies => [], verdicts => {
        'openrouter|a/one:free' => { verdict => 'replace' },
        'openrouter|b/two:free' => { verdict => 'watch' },
    } };
    my ($r) = run(signals => $sig);
    ok(!grep({ $_ eq 'openrouter|a/one:free' } @CALLS), 'replace-verdict model is never called');
    is($r->{response}, 'openrouter|c/three:free', 'watch model demoted below c/three');
    my @order = $router->failover_candidates(undef, 'openrouter', 'req/model:free', chains => chains(),
        verdicts => $sig->{verdicts});
    is_deeply([ map { $_->{slug} } grep { !$_->{placeholder} } @order ],
        [ 'openrouter|req/model:free', 'openrouter|a/one:free', 'openrouter|c/three:free', 'openrouter|b/two:free' ],
        'candidate order: requested, chain, watch last');
}

# ── 4. budget guard: no free -> paid failover past the soft caps ─────────
{
    my $ch = chains(chain_chat => [ 'openrouter|paid/coder', 'openrouter|a/one:free' ]);
    %SCRIPT = ('openrouter|req/model:free' => $FAIL->('429 Too Many Requests'),
               'openrouter|paid/coder' => $OK->('paid answer'), 'openrouter|a/one:free' => $OK->('free answer'));
    my ($r) = run(chains => $ch, spend => { ok => 1, day => 1.70, week => 2, month => 5, by_model_day => {} });
    ok(!grep({ $_ eq 'openrouter|paid/coder' } @CALLS), 'over $1.65/day: paid model not called');
    is($r->{response}, 'free answer', '... next free step answered');
    like(join(',', @{ $r->{fallover}{skipped} }), qr/paid\/coder:budget_cap_day/, '... skipped budget_cap_day');
    ($r) = run(chains => $ch, spend => { ok => 1, day => 0.1, week => 11.60, month => 12, by_model_day => {} });
    like(join(',', @{ $r->{fallover}{skipped} }), qr/budget_cap_week/, 'over $11.50/week blocked');
    ($r) = run(chains => $ch, spend => { ok => 1, day => 0.1, week => 1, month => 50.01, by_model_day => {} });
    like(join(',', @{ $r->{fallover}{skipped} }), qr/budget_cap_month/, 'over $50/month blocked');
    ($r) = run(chains => $ch, spend => { ok => 0 });
    like(join(',', @{ $r->{fallover}{skipped} }), qr/budget_unknown/, 'unknown spend blocks paid failover');
    ($r) = run(chains => $ch, spend => { ok => 1, day => 0.2, week => 1, month => 3, by_model_day => {} });
    is($r->{response}, 'paid answer', 'under caps: paid failover allowed');
    my $ch2 = chains(chain_chat => [ 'openrouter|paid/coder', 'openrouter|a/one:free' ],
                     model_caps_usd_per_day => { 'openrouter|paid/coder' => 0.10 });
    ($r) = run(chains => $ch2, spend => { ok => 1, day => 0.2, week => 1, month => 3, by_model_day => { 'openrouter|paid/coder' => 0.12 } });
    like(join(',', @{ $r->{fallover}{skipped} }), qr/model_cap/, 'per-model cap blocks');
    my $ch3 = chains(chain_chat => [ 'openrouter|paid/coder', 'openrouter|a/one:free' ],
                     chain_caps_usd_per_day => { chat => 0.10 });
    ($r) = run(chains => $ch3, spend => { ok => 1, day => 0.2, week => 1, month => 3, by_model_day => { 'openrouter|paid/coder' => 0.15 } });
    like(join(',', @{ $r->{fallover}{skipped} }), qr/chain_cap/, 'per-chain cap blocks');
}

# ── 5. Super Grok guard lock respected ───────────────────────────────────
{
    %SCRIPT = ('supergrok|grok-4.6' => $OK->('grok answer'), 'openrouter|a/one:free' => $OK->('free answer'));
    my ($r) = run(provider => 'supergrok', model => 'grok-4.6', guard => { locked => 1, reason => 'today 9% >= daily cap 9%' });
    ok(!grep({ $_ eq 'supergrok|grok-4.6' } @CALLS), 'guard locked: SuperGrok not called');
    is($r->{response}, 'free answer', '... next chain step answered');
    like($r->{fallover}{skipped}[0], qr/supergrok_locked/, '... skip reason supergrok_locked');
    ($r) = run(provider => 'supergrok', model => 'grok-4.6', guard => { locked => 0 });
    is($r->{response}, 'grok answer', 'guard open: SuperGrok used');
    # Guard file parsing.
    my $dir = tempdir(CLEANUP => 1);
    my @lt = localtime(time);
    my $iso = sprintf('%04d-%02d-%02dT%02d:%02d:00-07:00', $lt[5] + 1900, $lt[4] + 1, $lt[3], $lt[2], $lt[1]);
    open my $fh, '>', "$dir/g.json" or die; print $fh JSON->new->encode({ off_today => JSON::true, lock_reason => 'yesterday 12% >= daily cap 9%', mode => 'free', checked => $iso, daily_cap => 9, used_today => 1 }); close $fh;
    local $ENV{COMSERV_SUPERGROK_GUARD_FILE} = "$dir/g.json";
    my $g = $router->supergrok_guard(undef);
    ok($g->{locked}, 'supergrok_guard.json off_today -> locked');
    like($g->{reason}, qr/yesterday 12%/, '... reason from lock_reason');
}

# ── 6. all exhausted: honest message, Ledger row ─────────────────────────
{
    %SCRIPT = map { $_ => $FAIL->('503 Service Unavailable') } qw(openrouter|req/model:free openrouter|a/one:free openrouter|b/two:free openrouter|c/three:free);
    my ($r, $c) = run(ledger_meta => { surface => 'chat', role => 'member' });
    ok(!$r->{success}, 'all failed -> not a success');
    ok($r->{all_exhausted}, '... all_exhausted flag');
    is($r->{error}, 'No AI model is available right now (all options failed or are over budget). Please try again later.', 'honest message, no invented content');
    ok(!defined $r->{response}, '... no response text');
    is($router->_user_facing_error($r->{error}), $r->{error}, 'user-facing error passes the honest message through');
    my @rows = @{ $c->rows };
    is(scalar(@rows), 5, 'Ledger: 4 failed attempts + 1 all_exhausted row');
    is($rows[-1]{provider}, 'router', 'all_exhausted row provider=router');
    is($rows[-1]{status}, 'all_exhausted', '... status all_exhausted');
    is($rows[-1]{metadata}{fallover}{reason}, 'all_exhausted', '... metadata.fallover.reason all_exhausted');
    is($rows[-1]{metadata}{surface}, 'chat', '... caller ledger_meta kept');
    is($rows[1]{metadata}{fallover}{fallback_from}, 'openrouter|req/model:free', 'attempt 2 row fallback_from = attempt 1');
    is($rows[3]{metadata}{fallover}{final_model}, 'none', 'failed rows: final_model none');
    # Everything skipped (no calls at all) is also all_exhausted.
    %SCRIPT = ();
    ($r) = run(guard => { locked => 1 }, provider => 'supergrok', model => 'grok-4.6',
               chains => chains(chain_chat => [ 'openrouter|paid/x' ]), spend => { ok => 1, day => 9, week => 9, month => 9, by_model_day => {} });
    ok($r->{all_exhausted} && !@CALLS, 'all candidates blocked -> all_exhausted without any call');
}

# failover => 0 (Focus-Tune): requested model only.
{
    %SCRIPT = ('openrouter|req/model:free' => $FAIL->('429 Too Many Requests'), 'openrouter|a/one:free' => $OK->());
    my ($r) = run(failover => 0);
    ok(!$r->{success} && !grep({ $_ eq 'openrouter|a/one:free' } @CALLS), 'failover=>0 never tries another model');
}

# Legacy test contract (t/model_ai2_router_outage.t): no $c, Perl defaults.
{
    %SCRIPT = ('openrouter|paid/model' => $FAIL->('503 Service Unavailable'),
               'openrouter|google/gemma-4-31b-it:free' => { success => 1, response => 'ok' });
    my $r = $router->chat_with_fallback(undef, 'openrouter', 'paid/model', [ { role => 'user', content => 'x' } ]);
    ok($r->{success} && $r->{fallback}, 'no Catalyst context: Perl default chain, legacy fallback flag');
    is($r->{fallback_from}, 'openrouter', '... legacy fallback_from = original provider');
}

# ── 7. chains loader ─────────────────────────────────────────────────────
{
    my $dir = tempdir(CLEANUP => 1);
    my @logged;
    my $log = sub { push @logged, "@_" };
    my $ld = Comserv::Util::AI::ModelChains->load(undef, path => "$dir/missing.json", logger => $log);
    is($ld->{source}, 'perl_default', 'missing file -> Perl default');
    like($logged[0], qr/using Perl default chains \(missing\)/, '... and it is logged');
    open my $fh, '>', "$dir/bad.json" or die; print $fh '{"chain_chat": "nope"}'; close $fh;
    $ld = Comserv::Util::AI::ModelChains->load(undef, path => "$dir/bad.json", logger => $log);
    is($ld->{source}, 'perl_default', 'invalid file -> Perl default');
    like($logged[-1], qr/invalid/, '... logged as invalid');
    Comserv::Util::AI::ModelChains->clear_cache;
    $ld = Comserv::Util::AI::ModelChains->load(undef, path => "$DATA/ai_model_chains.json", logger => $log);
    is($ld->{source}, 'file', 'repo data/ai_model_chains.json is valid');
    my @chat = Comserv::Util::AI::ModelChains->chain($ld, 'chat');
    ok(!grep({ $_ eq 'openrouter|nvidia/nemotron-3-nano-30b-a3b:free' } @chat), 'dead nemotron nano not in chat chain');
    ok(Comserv::Util::AI::ModelChains->is_removed($ld, 'openrouter|nvidia/nemotron-3-nano-30b-a3b:free'), '... and listed in removed');
    is(Comserv::Util::AI::ModelChains->knob($ld, 'openrouter_soft_cap_day_usd'), 1.65, 'day cap 1.65 in file');
}

# ── 8. allow-list apply / revert on chain keys ──────────────────────────
{
    my $dir = tempdir(CLEANUP => 1);
    copy("$DATA/ai_model_chains.json", "$dir/ai_model_chains.json") or die;
    my $known = [ 'openrouter|google/gemma-4-31b-it:free', 'openrouter|cohere/north-mini-code:free',
                  'ollama|auto', 'openrouter|nvidia/nemotron-3-nano-30b-a3b:free' ];
    my $al = Comserv::Util::AI::EvalAllowList->new(data_dir => $dir, known_slugs => $known);
    my $t = 'data/ai_model_chains.json:chain_chat';
    ok($al->is_allowed($t), 'chain_chat is allow-listed');
    my $want = [ 'openrouter|cohere/north-mini-code:free', 'openrouter|google/gemma-4-31b-it:free', 'ollama|auto' ];
    my $r = $al->apply($t, $want);
    ok($r->{ok}, 'apply chain_chat') or diag $r->{error};
    ok($r->{before}{present} && ref $r->{before}{value} eq 'ARRAY', '... before value captured');
    my $now = JSON->new->decode(slurp("$dir/ai_model_chains.json"));
    is_deeply($now->{chain_chat}, $want, '... written to data/ copy');
    ok(exists $now->{circuit_failure_threshold}, '... other keys kept');
    my $rv = $al->restore($t, $r->{before});
    ok($rv->{ok}, 'revert chain_chat');
    is_deeply(JSON->new->decode(slurp("$dir/ai_model_chains.json"))->{chain_chat}, $r->{before}{value}, '... restored before value');

    my $bad = $al->apply($t, [ 'openrouter|made/up-model:free' ]);
    ok(!$bad->{ok}, 'unknown slug rejected');
    like($bad->{error}, qr/unknown model slug/, '... with reason');
    ok(!$al->apply($t, [ 'not a slug' ])->{ok}, 'bad grammar rejected');
    ok(!$al->apply($t, [])->{ok}, 'empty chain rejected');
    ok(!$al->apply($t, [ ('ollama|auto') x 2 ])->{ok}, 'duplicate slug rejected');
    my $rm = $al->apply('data/ai_model_chains.json:removed', [ 'openrouter|nvidia/nemotron-3-nano-30b-a3b:free' ]);
    ok($rm->{ok}, 'removed list apply (existing entry is a known slug)');
    ok(!$al->apply('data/ai_model_chains.json:openrouter_soft_cap_day_usd', 2)->{ok}, 'day cap cannot exceed 1.65');
    ok($al->apply('data/ai_model_chains.json:openrouter_soft_cap_day_usd', 1.00)->{ok}, 'day cap can be lowered');
    ok(!$al->apply('data/ai_model_chains.json:chain_caps_usd_per_day', { nosuch => 1 })->{ok}, 'chain cap needs a known purpose');
    ok($al->apply('data/ai_model_chains.json:circuit_failure_threshold', 4)->{ok}, 'threshold apply');
    ok(!$al->apply('data/ai_model_chains.json:circuit_failure_threshold', 0)->{ok}, 'threshold 0 rejected');
    ok(!$al->is_allowed('data/../root/config/ai_kill_switch.json:killed'), 'no path games');
    my $al0 = Comserv::Util::AI::EvalAllowList->new;   # ingest-time: grammar only
    ok(($al0->validate($t, [ 'openrouter|x/y:free' ]))[0], 'ingest-time validation checks grammar only');
    ok(!($al0->validate($t, [ 'x/y' ]))[0], '... and still rejects bad grammar');
}

is(slurp("$DATA/ai_model_chains.json"), $real_chains_before, 'real data/ai_model_chains.json untouched');

done_testing();
