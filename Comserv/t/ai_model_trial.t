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
    $dbh->do('INSERT INTO sessions VALUES (?,?,?,?)', undef, "s$_", $model, $now - 100 + $_, 5) for 1 .. 3;
    $dbh->do('INSERT INTO sessions VALUES (?,?,?,?)', undef, 'other', 'grok-4.7', $now - 50, 5);
    $dbh->do('INSERT INTO sessions VALUES (?,?,?,?)', undef, 'empty', $model, $now - 50, 0);
    $dbh->disconnect;
    my $sf = "$root/data/ai_trials/kimi_k27_code.state.json";
    open my $fh, '>', $sf; print $fh encode_json({ name => 'kimi_k27_code', model => $model, baseline => { month_usd => 45, balance_usd => 11 }, baseline_at => $now - 3600, alerted => 0, tasks_done => 0 }); close $fh;
    my $g = Comserv::Util::AI::HermesOverrunGuard->new(home => $root, app_root => $root, now => $now, base_urls => [], no_notify => 1);
    $g->{state_db} = $db;
    my $rd = sub { open my $f, '<', $sf; local $/; decode_json(<$f>) };
    $g->trial_tick({ ok => 1, month_usd => 45.4, balance_usd => 10.6 });
    my $d = $rd->(); is $d->{tasks_done}, 3, 'tasks = Hermes sessions on the trial model with calls (not other models, not empty)'; is $d->{last_spent}, 0.4, 'spend from live figures'; ok !$d->{alerted} && !$d->{stopped}, 'no alert under $3';
    $g->trial_tick({ ok => 1, month_usd => 48.2, balance_usd => 8.0 });
    $d = $rd->(); is $d->{alerted}, 1, '$3 spend check posted'; ok !$d->{stopped}, 'still running'; ok $d->{exclude_usd} >= 3.2, 'spend excluded from the OpenRouter caps';
    my $n = scalar @{ $g->{notified} || [] };
    $g->trial_tick({ ok => 1, month_usd => 48.3, balance_usd => 7.9 });
    is scalar @{ $g->{notified} || [] }, $n, 'spend check not posted twice';
    $g->trial_tick({ ok => 1, month_usd => 51.9, balance_usd => 5.0 });
    $d = $rd->(); like $d->{stopped}, qr/hard cap reached|could pass the cap/, 'stops at the cap'; is $g->{trial_stopped}{$model} ? 1 : 0, 1, 'stopped model is remembered for the offender check';
    is $g->trial_exclusions->{models}{$model}, undef, 'a stopped trial model is no longer excluded from the live estimate';
    my $off = Comserv::Util::AI::HermesOverrunGuard::offender_reason('openrouter', $model, trial_stopped => $g->{trial_stopped});
    like $off, qr/approved trial stopped/, 'sessions still on a stopped trial model become offenders (gate)';
    is Comserv::Util::AI::HermesOverrunGuard::offender_reason('openrouter', $model, trial_stopped => {}), undef, 'running trial: not an offender';
    $dbh = DBI->connect("dbi:SQLite:dbname=$db", '', '', { RaiseError => 1 }); $dbh->do('INSERT INTO sessions VALUES (?,?,?,?)', undef, "t$_", $model, $now, 3) for 4 .. 25; $dbh->disconnect;
    open $fh, '>', $sf; print $fh encode_json({ name => 'kimi_k27_code', model => $model, baseline => { month_usd => 45, balance_usd => 11 }, baseline_at => $now - 3600, alerted => 1 }); close $fh;
    $g->trial_tick({ ok => 1, month_usd => 45.5, balance_usd => 10.5 });
    like $rd->()->{stopped}, qr/task limit/, 'stops after 20 sessions';
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
done_testing;
