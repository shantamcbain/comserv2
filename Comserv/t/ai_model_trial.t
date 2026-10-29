use strict; use warnings; use Test::More; use FindBin; use lib "$FindBin::Bin/../lib"; use JSON::PP;
use Comserv::Util::AI::ModelChains; use Comserv::Util::AI::ModelTrial;
my $MC = 'Comserv::Util::AI::ModelChains'; my $T = 'Comserv::Util::AI::ModelTrial';
# Oct 26 2026: Kimi k2.7-code trial (approved by Shanta 9:28 AM PT): validator, never a fallback, cap/stop logic.
my $ld = $MC->load(undef, path => "$FindBin::Bin/../data/ai_model_chains.json", logger => sub {});
is $ld->{source}, 'file', 'data file valid';
my $tr = $MC->trial($ld, 'kimi_k27_code');
is $tr->{model}, 'moonshotai/kimi-k2.7-code', 'trial model'; is $tr->{hard_cap_usd}, 6, 'hard cap $6'; is $tr->{alert_at_usd}, 3, 'alert at $3'; is $tr->{max_tasks}, 20, '20 tasks';
is $tr->{selectable_by}, 'explicit_trial_run', 'explicit runs only';
# never in any chain or fallback
my %all = map { $_->{model} => 1 } ($MC->hermes_chain($ld), $MC->hermes_chain($ld, emergency => 1), $MC->hermes_cash_steps($ld));
for my $k (grep { /^chain_/ && ref $ld->{data}{$_} eq "ARRAY" } keys %{ $ld->{data} }) { $all{ (split /\|/, $_, 2)[1] } = 1 for @{ $ld->{data}{$k} } }
ok !$all{'moonshotai/kimi-k2.7-code'}, 'trial model is in no chain / fallback / cash step';

my %d = %{ $MC->perl_default };
my %good = (provider => 'openrouter', selectable_by => 'explicit_trial_run', hard_cap_usd => 6, alert_at_usd => 3, max_tasks => 20);
my $v = sub { my ($t) = @_; my ($ok, $e) = $MC->validate_structure({ %d, trials => { x => $t } }); return ($ok, join ' | ', @$e) };
my ($ok) = $v->({ %good, model => 'moonshotai/kimi-k2.7-code' }); ok $ok, 'good trial accepted';
for my $bad ('x-ai/grok-4.7', 'z-ai/glm-5.3-flash', 'deepseek/deepseek-v4-pro', 'relace/relace-apply-3', 'Relace/whatever') {
    my ($o, $e) = $v->({ %good, model => $bad }); ok !$o && $e =~ /banned/, "banned trial model rejected: $bad";
}
{ my ($o, $e) = $v->({ %good, model => 'moonshotai/kimi-k2.7-code', provider => 'external' }); ok !$o && $e =~ /provider must be openrouter/, 'provider must be openrouter'; }
{ my ($o, $e) = $v->({ %good, model => 'moonshotai/kimi-k2.7-code', selectable_by => 'fallback' }); ok !$o && $e =~ /selectable_by/, 'must be explicit-run only'; }
{ my ($o, $e) = $v->({ %good, model => 'moonshotai/kimi-k2.7-code', alert_at_usd => 7 }); ok !$o && $e =~ /below hard_cap/, 'alert below cap'; }
{ my ($o, $e) = $v->({ %good, model => 'moonshotai/kimi-k2.7-code', max_tasks => 0 }); ok !$o && $e =~ /max_tasks/, 'task limit required'; }
{ my ($o, $e) = $v->({ %good, model => 'moonshotai/kimi-k2.7-code', hard_cap_usd => 'lots' }); ok !$o && $e =~ /hard_cap_usd/, 'cap must be a number'; }
{ my ($o, $e) = $MC->validate_structure({ %d, hermes_fallback_chain => ['openrouter|moonshotai/kimi-k2.7-code'], trials => { x => { %good, model => 'moonshotai/kimi-k2.7-code' } } });
  ok !$o && "@$e" =~ /never be a fallback/, 'a trial model that is also in a chain is rejected'; }
ok !$MC->trial({ %d, trials => { x => { %good, model => 'x-ai/grok-4.7' } } }, 'x'), 'trial() refuses an invalid trial';

# spent: larger of month rise and balance drop
is $T->can('spent')->({ month_usd => 45.82, balance_usd => 11.20 }, { month_usd => 46.50, balance_usd => 10.60 }), 0.68, 'month rise vs balance drop: larger wins';
is $T->can('spent')->({ month_usd => 45.82, balance_usd => 11.20 }, { month_usd => 45.82, balance_usd => 11.20 }), 0, 'no spend';
is $T->can('spent')->({ month_usd => 45.82 }, { month_usd => 45.0 }), 0, 'never negative';
# evaluate
my $ev = sub { $T->can('evaluate')->(trial => $tr, live_ok => 1, tasks_done => 0, alerted => 0, spent => 0, %{ $_[0] || {} }) };
is $ev->()->{action}, 'run', 'fresh trial runs';
my $e = $ev->({ spent => 3.0 }); is $e->{action}, 'run', 'at $3 still runs'; ok $e->{alert}, '$3 posts the spend check';
ok !$ev->({ spent => 3.5, alerted => 1 })->{alert}, 'spend check posted only once';
$e = $ev->({ spent => 5.6 }); is $e->{action}, 'stop', 'stops when the next task could pass $6'; like $e->{reason}, qr/could pass the cap/, 'reason';
$e = $ev->({ spent => 6.0 }); is $e->{action}, 'stop', 'stops at $6'; like $e->{reason}, qr/hard cap reached/, 'hard cap reason';
$e = $ev->({ spent => 7.2 }); is $e->{action}, 'stop', 'stays stopped past $6';
$e = $ev->({ tasks_done => 20 }); is $e->{action}, 'stop', 'stops after 20 tasks'; like $e->{reason}, qr/task limit/, 'task limit reason';
is $ev->({ tasks_done => 19 })->{action}, 'run', 'task 20 may run';
$e = $ev->({ bot_pct => 96 }); is $e->{action}, 'stop', 'stops when Bot usage is over 95%'; is $ev->({ bot_pct => 95 })->{action}, 'run', '95% itself is allowed';
$e = $ev->({ live_ok => 0 }); is $e->{action}, 'stop', 'no readable spend -> no task'; 

# ---- the overrun guard leaves an approved trial's spend out of the OpenRouter caps ----
{
    my $r = $T->can('exclude_from_or')->({ ok => 1, day_usd => 2.5, week_usd => 5, month_usd => 48, balance_usd => 7 }, 2.0);
    is $r->{day_usd}, 0.5, 'day: trial spend removed'; is $r->{month_usd}, 46, 'month: trial spend removed'; is $r->{balance_usd}, 7, 'balance untouched';
    is $T->can('exclude_from_or')->({ ok => 1, day_usd => 0.5 }, 2.0)->{day_usd}, 0, 'never below 0';
    is $T->can('exclude_from_or')->({ ok => 0 }, 2.0)->{ok}, 0, 'unreadable reading passes through';
    require Comserv::Util::AI::HermesOverrunGuard; require File::Temp;
    my $root = File::Temp::tempdir(CLEANUP => 1); mkdir "$root/data"; mkdir "$root/data/ai_trials";
    my $now = time;
    open my $fh, '>', "$root/data/ai_trials/x.state.json"; print $fh encode_json({ model => 'moonshotai/kimi-k2.7-code', baseline => { month_usd => 1 }, baseline_at => $now, exclude_usd => 1.25 }); close $fh;
    open $fh, '>', "$root/data/ai_trials/old.state.json"; print $fh encode_json({ model => 'old/model', baseline => { month_usd => 1 }, baseline_at => $now - 90 * 86400, exclude_usd => 9 }); close $fh;
    my $g = Comserv::Util::AI::HermesOverrunGuard->new(home => $root, app_root => $root, now => $now, base_urls => []);
    my $x = $g->trial_exclusions;
    is $x->{usd}, 1.25, 'guard excludes this month\'s trial spend only'; ok $x->{models}{'moonshotai/kimi-k2.7-code'} && !$x->{models}{'old/model'}, 'trial model excluded from the live estimate; last month\'s is not';
}

# ---- trial_tick: the counter runs from the guard (Hermes sessions that use the model), alerts once, stops at the cap ----
{
    require Comserv::Util::AI::HermesOverrunGuard; require File::Temp; require DBI;
    my $root = File::Temp::tempdir(CLEANUP => 1); mkdir "$root/data"; mkdir "$root/data/ai_trials"; mkdir "$root/.hermes";
    system('cp', "$FindBin::Bin/../data/ai_model_chains.json", "$root/data/ai_model_chains.json");
    my $now = time; my $model = 'moonshotai/kimi-k2.7-code';
    my $db = "$root/state.db"; my $dbh = DBI->connect("dbi:SQLite:dbname=$db", '', '', { RaiseError => 1 });
    $dbh->do('CREATE TABLE sessions (id TEXT, model TEXT, started_at REAL, api_call_count INTEGER)');
    # Oct 28 2026: the trial counts the model's OWN cost (session_model_usage), never the account-wide OpenRouter figures
    $dbh->do('CREATE TABLE session_model_usage (session_id TEXT, model TEXT, first_seen REAL, estimated_cost_usd REAL, actual_cost_usd REAL)');
    $dbh->do('INSERT INTO session_model_usage VALUES (?,?,?,?,?)', undef, 'c1', $model, $now - 100, 0.4, 0);
    $dbh->do('INSERT INTO session_model_usage VALUES (?,?,?,?,?)', undef, 'o1', 'qwen/qwen3-coder', $now - 100, 9.0, 0);      # another model: never counted
    $dbh->do('INSERT INTO session_model_usage VALUES (?,?,?,?,?)', undef, 'old', $model, $now - 7200, 9.0, 0);                # before the baseline: never counted
    $dbh->do('INSERT INTO sessions VALUES (?,?,?,?)', undef, "s$_", $model, $now - 100 + $_, 5) for 1 .. 3;
    $dbh->do('INSERT INTO sessions VALUES (?,?,?,?)', undef, 'other', 'grok-4.7', $now - 50, 5);
    $dbh->do('INSERT INTO sessions VALUES (?,?,?,?)', undef, 'empty', $model, $now - 50, 0);
    $dbh->disconnect;
    my $sf = "$root/data/ai_trials/kimi_k27_code.state.json";
    open my $fh, '>', $sf; print $fh encode_json({ name => 'kimi_k27_code', model => $model, baseline => { month_usd => 45, balance_usd => 11 }, baseline_at => $now - 3600, alerted => 0, tasks_done => 0 }); close $fh;
    my $g = Comserv::Util::AI::HermesOverrunGuard->new(home => $root, app_root => $root, now => $now, base_urls => [], no_notify => 1);
    $g->{state_db} = $db;
    my $rd = sub { open my $f, '<', $sf; local $/; decode_json(<$f>) };
    my $setcost = sub { my $c = DBI->connect("dbi:SQLite:dbname=$db", '', '', { RaiseError => 1 }); $c->do('UPDATE session_model_usage SET estimated_cost_usd = ? WHERE session_id = ?', undef, $_[0], 'c1'); $c->disconnect };
    $g->trial_tick({ ok => 1, month_usd => 99, balance_usd => 0 });   # absurd account figures: must not matter
    my $d = $rd->(); is $d->{tasks_done}, 3, 'tasks = Hermes sessions on the trial model with calls (not other models, not empty)'; is $d->{last_spent}, 0.4, 'spend is the trial model own cost, not the OpenRouter account figures'; is $d->{spend_basis}, 'model_cost', 'state marked as the model-cost basis'; ok !$d->{alerted} && !$d->{stopped}, 'no alert under $3';
    $setcost->(3.2); $g->trial_tick({ ok => 1, month_usd => 48.2, balance_usd => 8.0 });
    $d = $rd->(); is $d->{alerted}, 1, '$3 spend check posted'; ok !$d->{stopped}, 'still running'; ok $d->{exclude_usd} >= 3.2, 'spend excluded from the OpenRouter caps';
    my $n = scalar @{ $g->{notified} || [] };
    $setcost->(3.3); $g->trial_tick({ ok => 1, month_usd => 48.3, balance_usd => 7.9 });
    is scalar @{ $g->{notified} || [] }, $n, 'spend check not posted twice';
    $setcost->(6.0); $g->trial_tick({ ok => 1, month_usd => 51.9, balance_usd => 5.0 });
    $d = $rd->(); like $d->{stopped}, qr/hard cap reached|could pass the cap/, 'stops at the cap'; ok $d->{stopped_at}, 'stop time recorded';
    $setcost->(9.0); $g->trial_tick({ ok => 1, month_usd => 60, balance_usd => 1 });
    $d = $rd->(); is $d->{last_spent}, 6, 'stopped trial stops counting (frozen)'; is $d->{exclude_usd}, 6, 'frozen exclusion'; is $g->{trial_stopped}{$model} ? 1 : 0, 1, 'stopped model is remembered for the offender check';
    is $g->trial_exclusions->{models}{$model}, undef, 'a stopped trial model is no longer excluded from the live estimate';
    my $off = Comserv::Util::AI::HermesOverrunGuard::offender_reason('openrouter', $model, trial_stopped => $g->{trial_stopped});
    like $off, qr/approved trial stopped/, 'sessions still on a stopped trial model become offenders (gate)';
    is Comserv::Util::AI::HermesOverrunGuard::offender_reason('openrouter', $model, trial_stopped => {}), undef, 'running trial: not an offender';
    $dbh = DBI->connect("dbi:SQLite:dbname=$db", '', '', { RaiseError => 1 }); $dbh->do('INSERT INTO sessions VALUES (?,?,?,?)', undef, "t$_", $model, $now, 3) for 4 .. 25; $dbh->disconnect;
    open $fh, '>', $sf; print $fh encode_json({ name => 'kimi_k27_code', model => $model, baseline => { month_usd => 45, balance_usd => 11 }, baseline_at => $now - 3600, alerted => 1 }); close $fh;
    $setcost->(0.1); $g->trial_tick({ ok => 1, month_usd => 45.5, balance_usd => 10.5 });
    like $rd->()->{stopped}, qr/task limit/, 'stops after 20 sessions';

    # legacy state (old counter: ALL OpenRouter spend, $10.15) is recomputed once on the model-cost basis, downward
    $dbh = DBI->connect("dbi:SQLite:dbname=$db", '', '', { RaiseError => 1 });
    $dbh->do('INSERT INTO session_model_usage VALUES (?,?,?,?,?)', undef, 'k1', $model, $now - 3000, 3.56, 0);
    $dbh->do('INSERT INTO session_model_usage VALUES (?,?,?,?,?)', undef, 'late', $model, $now - 10, 5.0, 0);   # after the stop: not counted
    $dbh->disconnect; $setcost->(0);
    open $fh, '>', $sf; print $fh encode_json({ name => 'kimi_k27_code', model => $model, baseline => { month_usd => 45, balance_usd => 11 }, baseline_at => $now - 3600, alerted => 1,
        stopped => 'next task could pass the cap', last_notified => { at => $now - 600 }, exclude_usd => 10.1462, last_spent => 10.1462, tasks_done => 2 }); close $fh;
    $g->trial_tick({ ok => 1, month_usd => 99, balance_usd => 0 });
    $d = $rd->(); is $d->{exclude_usd}, 3.56, 'legacy Kimi state corrected from $10.15 to the model own $3.56'; is $d->{last_spent}, 3.56, 'last_spent corrected'; is $d->{spend_basis}, 'model_cost', 'basis recorded';
    ok $d->{stopped}, 'still stopped'; is $d->{stopped_at}, $now - 600, 'stop time taken from the stop notice';
    $g->trial_tick({ ok => 1, month_usd => 99, balance_usd => 0 });
    is $rd->()->{exclude_usd}, 3.56, 'second tick: frozen, unchanged';

    # exclusion is the trial model own spend inside each OpenRouter window: an old trial is not taken out of today
    my @u = gmtime $now; my $day0 = $now - ($u[2] * 3600 + $u[1] * 60 + $u[0]);
    $dbh = DBI->connect("dbi:SQLite:dbname=$db", '', '', { RaiseError => 1 });
    $dbh->do('DELETE FROM session_model_usage'); $dbh->do('INSERT INTO session_model_usage VALUES (?,?,?,?,?)', undef, 'y', $model, $day0 - 1800, 3.0, 0);   # yesterday (UTC)
    $dbh->do('INSERT INTO session_model_usage VALUES (?,?,?,?,?)', undef, 't', $model, $day0 + 5, 1.0, 0); $dbh->disconnect;
    open $fh, '>', $sf; print $fh encode_json({ name => 'kimi_k27_code', model => $model, baseline => { month_usd => 1 }, baseline_at => $day0 - 86400, exclude_usd => 4.0, spend_basis => 'model_cost' }); close $fh;
    my $bw = $g->trial_exclusions->{by_window};
    is $bw->{day}, 1, 'day window: only today\'s trial spend'; ok $bw->{month} >= 1, 'month window includes the trial spend';
    my $r = $T->can('exclude_from_or')->({ ok => 1, day_usd => 2, week_usd => 6, month_usd => 20 }, $bw);
    is $r->{day_usd}, 1, 'day figure loses only $1 (not the whole trial)';
}

# ---- thrash: calls of an ACTIVE approved trial model are not thrash; a stopped trial counts again; other models always count ----
{
    require Comserv::Util::AI::HermesOverrunGuard; require File::Temp; require POSIX;
    my $root = File::Temp::tempdir(CLEANUP => 1); mkdir "$root/data"; mkdir "$root/data/ai_trials"; mkdir "$root/.hermes"; mkdir "$root/.hermes/logs";
    my $now = time; my $kimi = 'moonshotai/kimi-k2.7-code';
    my $ts = sub { POSIX::strftime('%Y-%m-%d %H:%M:%S,000', gmtime($_[0])) };
    open my $lf, '>', "$root/.hermes/logs/agent.log";
    print $lf $ts->($now - 60 - $_) . " INFO [sK] agent.conversation_loop: API call #$_: model=$kimi provider=openrouter in=1000 out=50 total=1 latency=2s\n" for 1 .. 32;
    print $lf $ts->($now - 30 - $_) . " INFO [sQ] agent.conversation_loop: API call #$_: model=qwen/qwen3-coder provider=openrouter in=1000 out=50 total=1 latency=2s\n" for 1 .. 3;
    close $lf;
    my $sf = "$root/data/ai_trials/kimi_k27_code.state.json";
    my $write = sub { open my $fh, '>', $sf; print $fh encode_json({ name => 'kimi_k27_code', model => $kimi, baseline => { month_usd => 1 }, baseline_at => $now, %{ $_[0] || {} } }); close $fh };
    my $mk = sub { my $g = Comserv::Util::AI::HermesOverrunGuard->new(home => $root, app_root => $root, now => $now, base_urls => [], no_notify => 1); $g->{agent_log} = "$root/.hermes/logs/agent.log"; $g->{trial_models} = $g->trial_exclusions->{models}; $g };
    $write->({});
    my $c = $mk->()->thrash_by_class; is $c->{counts}{openrouter_paid}, 3, 'active trial: its 32 calls are not counted, qwen\'s 3 are';
    $write->({ stopped => 'hard cap reached' });
    $c = $mk->()->thrash_by_class; is $c->{counts}{openrouter_paid}, 35, 'stopped trial: its calls count again';
    my $d = Comserv::Util::AI::HermesOverrunGuard::decide(thrash_by_class => $c, limits => { openrouter_paid => 30 }, openrouter => { ok => 1, day_usd => 0, week_usd => 0, month_usd => 1 }, state => {});
    is $d->{action}, 'trip', 'stopped trial: 35 paid calls trip the thrash limit'; like "@{ $d->{reasons} }", qr/openrouter_paid/, 'thrash reason names the class';
    $write->({});
    $c = $mk->()->thrash_by_class;
    $d = Comserv::Util::AI::HermesOverrunGuard::decide(thrash_by_class => $c, limits => { openrouter_paid => 30 }, openrouter => { ok => 1, day_usd => 0, week_usd => 0, month_usd => 1 }, state => {});
    is $d->{action}, 'none', 'active trial: no thrash trip';
}

# thrash_count (state.db message count) leaves the active trial model out too
{
    require DBI; require File::Temp; require Comserv::Util::AI::HermesOverrunGuard;
    my $root = File::Temp::tempdir(CLEANUP => 1); my $db = "$root/state.db"; my $now = time; my $kimi = 'moonshotai/kimi-k2.7-code';
    my $dbh = DBI->connect("dbi:SQLite:dbname=$db", '', '', { RaiseError => 1 });
    $dbh->do('CREATE TABLE sessions (id TEXT, model TEXT, billing_provider TEXT)'); $dbh->do('CREATE TABLE messages (session_id TEXT, role TEXT, timestamp REAL)');
    $dbh->do('INSERT INTO sessions VALUES (?,?,?)', undef, @$_) for ['k', $kimi, 'openrouter'], ['q', 'qwen/qwen3-coder', 'openrouter'];
    $dbh->do('INSERT INTO messages VALUES (?,?,?)', undef, 'k', 'assistant', $now - 10) for 1 .. 5;
    $dbh->do('INSERT INTO messages VALUES (?,?,?)', undef, 'q', 'assistant', $now - 10) for 1 .. 2;
    $dbh->disconnect;
    my $g = Comserv::Util::AI::HermesOverrunGuard->new(home => $root, app_root => $root, now => $now, base_urls => []); $g->{state_db} = $db;
    is $g->thrash_count, 7, 'no trial: all 7 counted';
    $g->{trial_models} = { $kimi => 1 };
    is $g->thrash_count, 2, 'active trial model excluded, qwen still counted';
}

# ---- exclude_from_or per-window form ----
{
    my $r = $T->can('exclude_from_or')->({ ok => 1, day_usd => 2, week_usd => 5, month_usd => 40 }, { day => 0, week => 1.5, month => 3 });
    is $r->{day_usd}, 2, 'window with no trial spend untouched'; is $r->{week_usd}, 3.5, 'week reduced'; is $r->{month_usd}, 37, 'month reduced';
}
# ---- model_cost: only that model, since the baseline, never negative/undef-safe ----
{
    require DBI; require File::Temp;
    my $root = File::Temp::tempdir(CLEANUP => 1); my $db = "$root/s.db";
    my $dbh = DBI->connect("dbi:SQLite:dbname=$db", '', '', { RaiseError => 1 });
    $dbh->do('CREATE TABLE session_model_usage (session_id TEXT, model TEXT, first_seen REAL, estimated_cost_usd REAL, actual_cost_usd REAL)');
    $dbh->do('INSERT INTO session_model_usage VALUES (?,?,?,?,?)', undef, @$_) for ['a', 'openai/gpt-5.6-luna', 100, 0.5, 0], ['b', 'openai/gpt-5.6-luna', 200, 0.2, 0.9], ['c', 'qwen/qwen3-coder', 200, 7, 0], ['d', 'openai/gpt-5.6-luna', 50, 4, 0];
    $dbh->disconnect;
    is $T->can('model_cost')->($db, 'openai/gpt-5.6-luna', 100), 1.4, 'own model only, since baseline, larger of actual/estimated per row';
    is $T->can('model_cost')->($db, 'openai/gpt-5.6-luna', 100, 150), 0.5, 'until bound';
    is $T->can('model_cost')->($db, 'nope/none', 0), 0, 'no rows: 0'; is $T->can('model_cost')->("$root/missing.db", 'x/y', 0), undef, 'unreadable: undef';
}

# ---- Oct 28 2026: OpenRouter caps raised to $3/day, $15/week, $65/month (Shanta); x.ai direct stays $0 ----
{
    my $c = $MC->channel_caps($ld, 'openrouter');
    is $c->{day}, 3, 'OpenRouter day cap $3'; is $c->{week}, 15, 'week $15'; is $c->{month}, 65, 'month $65';
    my $x = $MC->channel_caps($ld, 'xai_direct'); is $x->{day} + $x->{week} + $x->{month}, 0, 'x.ai direct stays $0';
    require Comserv::Util::AI::HermesOverrunGuard; my $G = 'Comserv::Util::AI::HermesOverrunGuard';
    my $or = { ok => 1, day_usd => 2.9, week_usd => 14, month_usd => 52 };
    is $G->can('decide')->(thrash => 0, openrouter => $or, state => {}, caps => $c)->{action}, 'none', 'inside the new caps: no trip';
    like "@{ $G->can('decide')->(thrash => 0, openrouter => { %$or, month_usd => 65.2 }, state => {}, caps => $c)->{reasons} }", qr/month \$65\.\d+ over \$65\.00 cap/, 'trips at the new month cap';
    is $G->can('decide')->(thrash => 0, openrouter => $or, state => {})->{action}, 'trip', 'old built-in caps would have tripped (so the guard must pass the file caps)';
}

# ---- trials.gpt_56_luna: PROBATION (approved by Shanta Oct 28 2026 9:29 AM PT; replaces the $3 / 6-task trial) ----
{
    my $lu = $MC->trial($ld, 'gpt_56_luna');
    ok $lu, 'luna probation entry is valid'; is $lu->{model}, 'openai/gpt-5.6-luna', 'model'; is $lu->{provider}, 'openrouter', 'on openrouter';
    ok $lu->{probation}, 'probation flag'; is $lu->{hard_cap_usd}, 5, 'limit $5 of luna own spend'; is $lu->{max_tasks}, 10, 'limit 10 sessions'; ok !defined $lu->{alert_at_usd}, 'no separate alert level: the stop is the one alert';
    is $lu->{selectable_by}, 'probation_chain', 'probation chain member';
    is join(',', @{ $lu->{provider_routing}{only} }), 'openai,azure', 'OpenAI or Azure only'; ok !grep(/relace/i, @{ $lu->{provider_routing}{only} }), 'never Relace';
    my %other = map { $_->{model} => 1 } ($MC->hermes_chain($ld, emergency => 1), $MC->hermes_cash_steps($ld));
    for my $k (grep { /^chain_/ && ref $ld->{data}{$_} eq "ARRAY" } keys %{ $ld->{data} }) { $other{ (split /\|/, $_, 2)[1] } = 1 for @{ $ld->{data}{$k} } }
    ok !$other{'openai/gpt-5.6-luna'}, 'luna is in no app chain / emergency chain / cash step';
    is join(' | ', map { $_->{provider} . '/' . $_->{model} } $MC->hermes_chain($ld)), 'supergrok/grok-4.7 | openrouter/openai/gpt-5.6-luna | openrouter/cohere/north-mini-code:free', 'Hermes chain: Super Grok, luna (first paid), north-mini last';
    is_deeply [ map { $_->{tier} } $MC->hermes_chain($ld) ], [qw(supergrok paid free)], 'tiers';
    my $E = $T->can('evaluate'); my %base = (trial => $lu, live_ok => 1, tasks_done => 0, alerted => 0, spent => 0);
    is $E->(%base)->{action}, 'run', 'fresh probation runs'; ok !$E->(%base, spent => 4.9)->{alert}, 'no early alert';
    is $E->(%base, spent => 4.9)->{action}, 'run', 'still running at $4.90 (no reserve rule)';
    my $e = $E->(%base, spent => 5); is $e->{action}, 'stop', 'stops at $5 of its own spend'; like $e->{reason}, qr/probation limit reached: \$5\.00 of \$5.*awaiting Shanta/, 'reason names the limit and the approval'; ok $e->{probation}, 'flagged probation'; ok !$e->{alert}, 'alert comes from the stop notice only';
    is $E->(%base, spent => 7.3)->{action}, 'stop', 'stays stopped past $5';
    $e = $E->(%base, tasks_done => 10); is $e->{action}, 'stop', 'stops after 10 sessions'; like $e->{reason}, qr/10 of 10 sessions/, 'session limit reason'; is $E->(%base, tasks_done => 9)->{action}, 'run', 'session 10 may run';
    my %d2 = %{ $MC->perl_default };
    my ($o, $er) = $MC->validate_structure({ %d2, trials => { x => { %{ $lu }, provider_routing => { only => ['openai', 'relace'] } } } });
    ok !$o && "@$er" =~ /must not list Relace/, 'Relace in provider_routing.only rejected';
    ($o, $er) = $MC->validate_structure({ %d2, trials => { x => { %{ $lu }, provider_routing => 'openai' } } }); ok !$o && "@$er" =~ /provider_routing must be an object/, 'bad routing shape rejected';
    # validator: probation may be the paid step of hermes_fallback_chain ONLY
    my %pc = (%d2, hermes_fallback_chain => ['supergrok|grok-4.7', 'openrouter|openai/gpt-5.6-luna', 'openrouter|cohere/north-mini-code:free'], trials => { x => { %{ $lu } } });
    ($o, $er) = $MC->validate_structure({ %pc }); ok $o, 'probation model as the paid step of the Hermes chain is accepted' or diag "@$er";
    ($o, $er) = $MC->validate_structure({ %pc, chain_chat => ['openrouter|openai/gpt-5.6-luna'] }); ok !$o && "@$er" =~ /never be a fallback/, 'probation model in an app chain rejected';
    ($o, $er) = $MC->validate_structure({ %pc, hermes_emergency_chain => ['openrouter|openai/gpt-5.6-luna'] }); ok !$o && "@$er" =~ /never be a fallback/, 'probation model in the emergency chain rejected';
    ($o, $er) = $MC->validate_structure({ %pc, hermes_fallback_chain => ['supergrok|grok-4.7', 'openrouter|qwen/qwen3-coder', 'openrouter|openai/gpt-5.6-luna', 'openrouter|cohere/north-mini-code:free'] });
    ok !$o && "@$er" =~ /only paid step/, 'a second paid step next to the probation model rejected';
    ($o, $er) = $MC->validate_structure({ %pc, trials => { x => { %{ $lu }, probation => 0 } } }); ok !$o && "@$er" =~ /never be a fallback/, 'without probation the model may not be in the chain';
    ($o, $er) = $MC->validate_structure({ %pc, trials => { x => { %{ $lu }, hard_cap_usd => 0 } } }); ok !$o && "@$er" =~ /hard_cap_usd/, 'probation still needs a $ limit';
    ($o, $er) = $MC->validate_structure({ %pc, trials => { x => { %{ $lu }, selectable_by => 'fallback' } } }); ok !$o && "@$er" =~ /selectable_by/, 'selectable_by checked';
    is_deeply $MC->channel_caps($ld, 'openrouter'), { day => 3, week => 15, month => 65 }, 'chain stays inside the OpenRouter caps $3 / $15 / $65';
    like $ld->{data}{_hermes_comment}, qr/gpt-5\.6-luna.*PROBATION.*60% of the day cap and 90%/s, '_hermes_comment describes the chain and the probation';
}
# ---- the trial exclusion is applied ONCE per OpenRouter reading (the old guard re-applied it to its saved snapshot every minute) ----
{
    require Comserv::Util::AI::HermesOverrunGuard; require File::Temp; require DBI;
    my $root = File::Temp::tempdir(CLEANUP => 1); mkdir "$root/data"; mkdir "$root/data/ai_trials"; mkdir "$root/.hermes"; mkdir "$root/.hermes/logs";
    system('cp', "$FindBin::Bin/../data/ai_model_chains.json", "$root/data/ai_model_chains.json");
    open my $cf, '>', "$root/.hermes/config.yaml"; print $cf "model:\n  default: cohere/north-mini-code:free\n  provider: openrouter\n"; close $cf;
    my $now = 1_800_000_000; my $model = 'moonshotai/kimi-k2.7-code';
    my $db = "$root/.hermes/state.db"; my $dbh = DBI->connect("dbi:SQLite:dbname=$db", '', '', { RaiseError => 1 });
    $dbh->do('CREATE TABLE sessions (id TEXT, model TEXT, started_at REAL, api_call_count INTEGER)');
    $dbh->do('CREATE TABLE session_model_usage (session_id TEXT, model TEXT, first_seen REAL, estimated_cost_usd REAL, actual_cost_usd REAL)');
    $dbh->do('INSERT INTO session_model_usage VALUES (?,?,?,?,?)', undef, 'k', $model, $now - 3000, 3.5, 0); $dbh->disconnect;
    open my $fh, '>', "$root/data/ai_trials/kimi_k27_code.state.json";
    print $fh encode_json({ name => 'kimi_k27_code', model => $model, baseline => { month_usd => 1 }, baseline_at => $now - 3600, spend_basis => 'model_cost', stopped => 'x', stopped_at => $now - 100, exclude_usd => 3.5, last_spent => 3.5 }); close $fh;
    my $mk = sub { Comserv::Util::AI::HermesOverrunGuard->new(home => $root, app_root => $root, now => $_[0], base_urls => [], no_notify => 1) };
    my $or = { ok => 1, day_usd => 0, week_usd => 0, month_usd => 20, balance_usd => 10, fetched_at => $now };
    my @m;
    for my $dt (0, 60, 120) {
        my $r = $mk->($now + $dt)->run(thrash => 0, thrash_by_class => { ok => 1, counts => {} }, live => { ok => 1, day_usd => 0, calls => 0, recent => {} }, openrouter => { %$or });
        push @m, $r->{openrouter}{month_usd};
    }
    is_deeply \@m, [ 16.5, 16.5, 16.5 ], 'trial $3.50 taken out of the month once: same figure on the fresh run and the two lite runs' or diag explain \@m;
}
# ---- Oct 28 2026: an ACTIVE probation model is allowed (also pinned by /model luna) while it is under 10 sessions / $5; stopped, it is blocked and out of the chain ----
{
    require Comserv::Util::AI::HermesOverrunGuard; require File::Temp; require DBI;
    my $G = 'Comserv::Util::AI::HermesOverrunGuard';
    my $root = File::Temp::tempdir(CLEANUP => 1); mkdir "$root/data"; mkdir "$root/data/ai_trials"; mkdir "$root/.hermes";
    system('cp', "$FindBin::Bin/../data/ai_model_chains.json", "$root/data/ai_model_chains.json");
    my $now = time; my $model = 'openai/gpt-5.6-luna';
    my $db = "$root/state.db"; my $dbh = DBI->connect("dbi:SQLite:dbname=$db", '', '', { RaiseError => 1 });
    $dbh->do('CREATE TABLE sessions (id TEXT, model TEXT, started_at REAL, api_call_count INTEGER)');
    $dbh->do('CREATE TABLE session_model_usage (session_id TEXT, model TEXT, first_seen REAL, estimated_cost_usd REAL, actual_cost_usd REAL)');
    $dbh->do('INSERT INTO session_model_usage VALUES (?,?,?,?,?)', undef, 'l1', $model, $now - 100, 0.5, 0);
    $dbh->do('INSERT INTO sessions VALUES (?,?,?,?)', undef, 'ls1', $model, $now - 100, 5);
    $dbh->disconnect;
    my $sf = "$root/data/ai_trials/gpt_56_luna.state.json";
    open my $fh, '>', $sf; print $fh encode_json({ name => 'gpt_56_luna', model => $model, baseline => { month_usd => 50, balance_usd => 20 }, baseline_at => $now - 3600, alerted => 0, tasks_done => 0, spend_basis => 'model_cost' }); close $fh;
    my $g = $G->new(home => $root, app_root => $root, now => $now, base_urls => [], no_notify => 1);
    $g->{state_db} = $db;
    $g->trial_tick({ ok => 1, month_usd => 99, balance_usd => 0 });
    ok $g->{trial_active}{$model}, 'active (begun, not stopped, under cap) trial model is remembered as active';
    ok !$g->{trial_stopped}{$model}, 'and not as stopped';
    my %cap = (or_over => 1, tripped => 1, sg_unavailable => 1, allowed_paid => { 'qwen/qwen3-coder' => 0 });
    is $G->can('offender_reason')->('openrouter', $model, %cap, trial_active => $g->{trial_active}, trial_stopped => $g->{trial_stopped}), undef, 'active trial allowed while the OpenRouter cap is hit / guard tripped';
    like $G->can('offender_reason')->('openrouter', $model, %cap), qr/OpenRouter cap reached/, 'same model with no active trial: blocked by the cap (nothing else changed)';
    like $G->can('offender_reason')->('openrouter', 'qwen/qwen3-coder', %cap, trial_active => $g->{trial_active}), qr/OpenRouter cap reached/, 'non-trial paid model stays blocked during the cap hold';
    like $G->can('offender_reason')->('openrouter', 'x-ai/grok-4.7', %cap, trial_active => { 'x-ai/grok-4.7' => 1 }), qr/grok is blocked/, 'trial flag never unblocks OpenRouter grok';
    my $offs = $G->can('session_offenders')->({ a => { provider => 'openrouter', model => $model, last_t => $now }, b => { provider => 'openrouter', model => 'qwen/qwen3-coder', last_t => $now - 5 } },
        %cap, trial_active => $g->{trial_active}, trial_stopped => $g->{trial_stopped});
    is_deeply [ map { $_->{model} } @$offs ], [ 'qwen/qwen3-coder' ], 'session_offenders lists qwen but not the active luna session';

    # chain consistency: luna (begun, not stopped) is a chain paid step and in allowed_paid; its spend is NOT excluded from the OpenRouter caps
    { my %cc = $g->chain_context; is join(',', map { $_->{model} } @{ $cc{chain} }), 'grok-4.7,openai/gpt-5.6-luna,cohere/north-mini-code:free', 'active probation: luna is in the Hermes chain';
      ok $cc{allowed_paid}{$model}, 'luna is an allowed paid chain step'; ok !%{ $cc{probation_out} }, 'nothing removed from the chain';
      my $tx = $g->trial_exclusions; ok !$tx->{models}{$model} && !$tx->{usd} && !$tx->{by_window}, 'probation spend is not excluded from the caps and luna is not exempt from thrash'; }

    # the probation limit ($5 of its own spend) stops it: stopped model is an offender again
    my $c = DBI->connect("dbi:SQLite:dbname=$db", '', '', { RaiseError => 1 }); $c->do('UPDATE session_model_usage SET estimated_cost_usd = 3.2'); $c->disconnect;
    $g->trial_tick({ ok => 1, month_usd => 99, balance_usd => 0 });
    ok $g->{trial_active}{$model}, 'under $5: still active ($3.20)';
    $c = DBI->connect("dbi:SQLite:dbname=$db", '', '', { RaiseError => 1 }); $c->do('UPDATE session_model_usage SET estimated_cost_usd = 5.2'); $c->disconnect;
    $g->trial_tick({ ok => 1, month_usd => 99, balance_usd => 0 });
    ok !$g->{trial_active}{$model}, 'probation over its $5 limit: no longer active'; ok $g->{trial_stopped}{$model}, 'probation over its limit: stopped';
    like $G->can('offender_reason')->('openrouter', $model, %cap, trial_active => $g->{trial_active}, trial_stopped => $g->{trial_stopped}), qr/approved trial stopped/, 'stopped trial is an offender again';
    my $g2 = $G->new(home => $root, app_root => $root, now => $now + 60, base_urls => [], no_notify => 1); $g2->{state_db} = $db;
    $g2->trial_tick({ ok => 1, month_usd => 99, balance_usd => 0 });
    ok !$g2->{trial_active}{$model} && $g2->{trial_stopped}{$model}, 'a stopped trial stays stopped on a later guard run';
    { my %cc = $g2->chain_context; is join(',', map { $_->{model} } @{ $cc{chain} }), 'grok-4.7,cohere/north-mini-code:free', 'stopped probation: luna is OUT of the Hermes chain (north-mini follows Super Grok)';
      ok !$cc{allowed_paid}{$model}, 'and not an allowed paid step'; like $cc{probation_out}{$model}, qr/probation gpt_56_luna stopped: probation limit reached/, 'reason recorded'; }
    is_deeply [ keys %{ $g2->probation_blocked($MC->load(undef, path => "$root/data/ai_model_chains.json", logger => sub {})) } ], [$model], 'probation_blocked names luna';
    # approval starts a new window (script/ai_trial.pl approve, run in a copy of the tree so the live state is untouched)
    { my $r2 = File::Temp::tempdir(CLEANUP => 1); mkdir "$r2/script"; mkdir "$r2/data"; mkdir "$r2/data/ai_trials";
      system('cp', "$FindBin::Bin/../script/ai_trial.pl", "$r2/script/ai_trial.pl"); system('ln', '-s', "$FindBin::Bin/../lib", "$r2/lib");
      system('cp', "$FindBin::Bin/../data/ai_model_chains.json", "$r2/data/ai_model_chains.json");
      my $f2 = "$r2/data/ai_trials/gpt_56_luna.state.json";
      my $wr = sub { open my $o, '>', $f2; print $o encode_json($_[0]); close $o };
      $wr->({ name => 'gpt_56_luna', model => $model, baseline => { month_usd => 50 }, baseline_at => $now - 7200, tasks_done => 10, last_spent => 5.2, spend_basis => 'model_cost' });
      my $o1 = `perl $r2/script/ai_trial.pl approve gpt_56_luna 2>&1`; like $o1, qr/not stopped/, 'approve refuses while the probation has not hit its limit';
      $wr->({ name => 'gpt_56_luna', model => $model, baseline => { month_usd => 50 }, baseline_at => $now - 7200, tasks_done => 10, last_spent => 5.2, stopped => 'probation limit reached', stopped_at => $now - 100, spend_basis => 'model_cost',
              last_notified => { key => 'trial_stop|gpt_56_luna|stop' } });
      my $o2 = `perl $r2/script/ai_trial.pl approve gpt_56_luna 2>&1`; like $o2, qr/"approved":1/, 'approve works once stopped';
      open my $in, '<', $f2; my $st = decode_json(do { local $/; <$in> }); close $in;
      ok !$st->{stopped} && $st->{tasks_done} == 0 && $st->{baseline_at} >= $now - 5 && !$st->{last_notified}, 'new window: stop cleared, sessions 0, baseline = now, alert re-armed';
      is scalar @{ $st->{rounds} }, 1, 'old round kept'; is $st->{rounds}[0]{tasks_done}, 10, 'old round records its sessions'; }
    # task limit (10 sessions) also stops it
    $c = DBI->connect("dbi:SQLite:dbname=$db", '', '', { RaiseError => 1 }); $c->do('UPDATE session_model_usage SET estimated_cost_usd = 0.1');
    $c->do('INSERT INTO sessions VALUES (?,?,?,?)', undef, "x$_", $model, $now - 50, 3) for 2 .. 10; $c->disconnect;
    open $fh, '>', $sf; print $fh encode_json({ name => 'gpt_56_luna', model => $model, baseline => { month_usd => 50 }, baseline_at => $now - 3600, spend_basis => 'model_cost' }); close $fh;
    my $g3 = $G->new(home => $root, app_root => $root, now => $now + 120, base_urls => [], no_notify => 1); $g3->{state_db} = $db;
    $g3->trial_tick({ ok => 1, month_usd => 99, balance_usd => 0 });
    ok !$g3->{trial_active}{$model} && $g3->{trial_stopped}{$model}, 'session limit (10) reached: stopped, not active';
    like $g3->{trial_stopped}{$model}, qr/10 of 10 sessions/, 'stop reason names the session limit';
    # not begun (no state file) -> unaudited -> not a chain step at all
    unlink $sf; my $g4 = $G->new(home => $root, app_root => $root, now => $now + 180, base_urls => [], no_notify => 1);
    { my %cc = $g4->chain_context; is join(',', map { $_->{model} } @{ $cc{chain} }), 'grok-4.7,cohere/north-mini-code:free', 'no baseline: luna is not a chain step (fail closed)'; like $cc{probation_out}{$model}, qr/not begun/, 'reason'; }
}
# ---- pick_target: luna only inside the caps; never while the OpenRouter day figure is over cap ----
{
    require Comserv::Util::AI::HermesOverrunGuard; my $G = 'Comserv::Util::AI::HermesOverrunGuard';
    my @CH = $MC->hermes_chain($ld); my @EM = $MC->hermes_chain($ld, emergency => 1);
    my $IDS = { map { ($_ => 1) } 'cohere/north-mini-code:free', 'openai/gpt-5.6-luna', 'qwen/qwen3-coder' };
    my %base = (or_ids => $IDS, health => {}, ollama_models => [], chain => \@CH, emergency => \@EM, kind => 'caps', supergrok => { mode => 'openrouter', locked => 1, off_today => 1 });
    is $G->can('pick_target')->(%base, paid_ok => 1)->{default}, 'openai/gpt-5.6-luna', 'Super Grok out + room under the caps: luna';
    is $G->can('pick_target')->(%base, paid_ok => 0)->{default}, 'cohere/north-mini-code:free', 'Super Grok out + no room: north-mini';
    my $caps = { day => 3, week => 15, month => 65 };
    ok !$G->can('paid_room')->({ ok => 1, day_usd => 6.12, week_usd => 6.6, month_usd => 52.4 }, $caps, []), 'day $6.12 of $3: no room (so no luna)';
    ok  $G->can('paid_room')->({ ok => 1, day_usd => 0.4, week_usd => 6.6, month_usd => 52.4 }, $caps, []), 'after the UTC day resets: room (day < 60%, week < 90%, month < 90%)';
    ok !$G->can('paid_room')->({ ok => 1, day_usd => 0.4, week_usd => 6.6, month_usd => 58.6 }, $caps, []), 'month >= 90% of $65 ($58.50): no room';
}
done_testing;
