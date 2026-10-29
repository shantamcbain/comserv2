use strict; use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin; use lib "$FindBin::Bin/../lib";
use Time::Local qw(timegm);
use Comserv::Util::AI::HermesOverrunGuard;
my $G = 'Comserv::Util::AI::HermesOverrunGuard';
my $EM = "\xe2\x80\x94";   # em dash as written to agent.log (UTF-8 bytes)
sub refused { my ($ts, $sid, $from, $fp, $why, $to, $tp) = @_;
    "$ts,159 WARNING [$sid] agent.chat_completion_helpers: Profile default: $from via $fp refused for $why $EM using fallback $to via $tp. Top up credits, or run `hermes model` to pick a model this account can use.\n" }

my $e = $G->can('parse_fallback_line')->(refused('2026-10-29 17:31:46', 'local-c3dfb01110a9', 'grok-4.7', 'xai-oauth', 'billing/credits', 'openai/gpt-5.6-luna', 'openrouter'));
is $e->{from}, 'grok-4.7', 'from'; is $e->{to}, 'openai/gpt-5.6-luna', 'to'; is $e->{reason}, 'billing/credits', 'reason';
is $e->{session}, 'local-c3dfb01110a9', 'session'; is $e->{at}, timegm(46, 31, 17, 29, 9, 2026), 'UTC timestamp';
is $G->can('short_session')->('local-c3dfb01110a986a4'), 'c3dfb011', 'short id';
ok !$G->can('parse_fallback_line')->("2026-10-29 17:31:46,1 INFO [x] Fallback openai/gpt-5.6-luna: extra_body resolved: None\n"), 'other Fallback lines ignored';

my $h = tempdir(CLEANUP => 1); mkdir "$h/.hermes"; mkdir "$h/.hermes/logs";
my $log = "$h/.hermes/logs/agent.log";
my $t0 = timegm(0, 40, 17, 29, 9, 2026);
my %cwd = ('local-c3dfb011aa' => '/w/.comserv/worktrees/planning/Comserv', 'local-792106ceaa' => '/w/.comserv/worktrees/CSSNavigation/Comserv');
my $mk = sub { $G->new(home => $h, app_root => $h, no_notify => 1, now => $_[0] // $t0, port => 4006, worktree => 'aisystem',
    session_cwd_cb => sub { ($cwd{$_[0]}) }, branch_cb => sub { (($_[0] =~ m{worktrees/([^/]+)})[0]) },
    toplevel_cb => sub { $_[0] . '/Comserv' }, server_ports => { '/w/.comserv/worktrees/planning/Comserv/Comserv' => 4005 }) };
open my $fh, '>', $log; print $fh refused('2026-10-29 17:31:46', 'local-c3dfb011aa', 'grok-4.7', 'xai-oauth', 'billing/credits', 'openai/gpt-5.6-luna', 'openrouter');
print $fh refused('2026-10-29 17:31:07', 'local-792106ceaa', 'grok-4.7', 'xai-oauth', 'billing/credits', 'openai/gpt-5.6-luna', 'openrouter');
print $fh refused('2026-10-29 17:32:00', 'local-unknown01', 'grok-4.7', 'xai-oauth', 'rate limit', 'openai/gpt-5.6-luna', 'openrouter');
print $fh refused('2026-10-29 15:00:00', 'local-old00000', 'grok-4.7', 'xai-oauth', 'billing/credits', 'openai/gpt-5.6-luna', 'openrouter'); close $fh;
my $out = $mk->()->fallback_notices;
is scalar @$out, 3, 'three fresh fallbacks raised (old one ignored)';
like $out->[0]{text}, qr/^FALLBACK Thu Oct 29 10:31 PT session c3dfb011: grok-4\.7 -> openai\/gpt-5\.6-luna \(openrouter\), reason billing\/credits; session on planning :4005\.$/, 'notice text: PT, short id, from/to, reason, branch+port';
like $out->[1]{text}, qr/session on CSSNavigation port unknown/, 'branch without a running server';
like $out->[2]{text}, qr/reason rate limit; session on branch unknown port unknown/, 'branch unknown';
open my $lf, '<', "$h/.hermes/logs/overrun_guard.log"; my @l = <$lf>; close $lf;
is scalar(grep { /^\S+ \[:4006 aisystem\] FALLBACK / } @l), 3, 'one prefixed log line each';

# repeat lines in the same session stay silent; a new model (luna -> north) raises again with the real from-model
open $fh, '>>', $log; print $fh refused('2026-10-29 17:41:00', 'local-c3dfb011aa', 'grok-4.7', 'xai-oauth', 'billing/credits', 'openai/gpt-5.6-luna', 'openrouter'); close $fh;
is scalar @{ $mk->($t0 + 120)->fallback_notices }, 0, 'same session same model -> silent';
is scalar @{ $mk->($t0 + 180)->fallback_notices }, 0, 'nothing new -> silent (offset kept)';
open $fh, '>>', $log; print $fh refused('2026-10-29 17:45:00', 'local-c3dfb011aa', 'grok-4.7', 'xai-oauth', 'rate limit', 'cohere/north-mini-code:free', 'openrouter'); close $fh;
$out = $mk->($t0 + 700)->fallback_notices;
is scalar @$out, 1, 'model changed again -> one notice';
like $out->[0]{text}, qr/openai\/gpt-5\.6-luna -> cohere\/north-mini-code:free .*reason rate limit/, 'luna -> north';
unlike $out->[0]{text}, qr/north took over mid-task/, 'luna -> north: no grok handoff warning';
open $fh, '>>', $log; print $fh refused('2026-10-29 17:46:00', 'local-792106ceaa', 'grok-4.7', 'xai-oauth', 'billing/credits', 'cohere/north-mini-code:free', 'openrouter'),
                                refused('2026-10-29 17:46:01', 'local-newgrok1', 'grok-4.7', 'xai-oauth', 'billing/credits', 'cohere/north-mini-code:free', 'openrouter'); close $fh;
$out = $mk->($t0 + 1400)->fallback_notices;
like $out->[1]{text}, qr/grok-4\.7 -> cohere\/north-mini-code:free .*WARNING: north took over mid-task; it may lose the thread, so consider \/model luna or a handoff summary\./, 'grok -> north warning';
# rotation: smaller file resets the offset
open $fh, '>', $log; print $fh refused('2026-10-29 17:47:00', 'local-rot00001', 'grok-4.7', 'xai-oauth', 'billing/credits', 'openai/gpt-5.6-luna', 'openrouter'); close $fh;
is scalar @{ $mk->($t0 + 1500)->fallback_notices }, 1, 'rotated log read from the start';
# --- Code Guard review fixes ---
my $mask = $G->can('clean_reason');
unlike $mask->('billing/credits for key sk-or-v1-abcdef0123456789abcdef0123456789'), qr/abcdef0123/, 'key-like text masked';
like $mask->('Bearer eyJhbGciOiJIUzI1NiJ9xxxxxxxxxxxxxxxxxx'), qr/^Bearer \*\*\*$/, 'bearer token masked';
is length($mask->('x ' x 200)), 120, 'reason truncated to 120';
is $mask->('billing/credits'), 'billing/credits', 'plain reason kept';

my $mk2 = sub { my ($hh, $now, %x) = @_; $G->new(home => $hh, app_root => $hh, no_notify => 1, now => $now, port => 4006, worktree => 'aisystem',
    session_cwd_cb => sub { () }, server_ports => {}, %x) };
my $fresh = sub { my $hh = tempdir(CLEANUP => 1); mkdir "$hh/.hermes"; mkdir "$hh/.hermes/logs"; $hh };
my $lines = sub { my $hh = shift; open my $f, '<', "$hh/.hermes/logs/overrun_guard.log" or return (); grep { /FALLBACK/ } <$f> };
# partial last line stays for the next run
{   my $hh = $fresh->(); my $lg = "$hh/.hermes/logs/agent.log";
    my $full = refused('2026-10-29 17:39:00', 'local-part0001', 'grok-4.7', 'xai-oauth', 'billing/credits', 'openai/gpt-5.6-luna', 'openrouter');
    open my $f, '>', $lg; print $f substr($full, 0, 80); close $f;
    is scalar @{ $mk2->($hh, $t0)->fallback_notices }, 0, 'partial line: nothing raised';
    open $f, '>>', $lg; print $f substr($full, 80); close $f;
    is scalar @{ $mk2->($hh, $t0 + 5)->fallback_notices }, 1, 'line completed later is raised on the next run';
}
# dry_run: no log line, no seen state
{   my $hh = $fresh->(); open my $f, '>', "$hh/.hermes/logs/agent.log";
    print $f refused('2026-10-29 17:39:00', 'local-dry00001', 'grok-4.7', 'xai-oauth', 'billing/credits', 'openai/gpt-5.6-luna', 'openrouter'); close $f;
    is scalar @{ $mk2->($hh, $t0, dry_run => 1)->fallback_notices }, 1, 'dry_run computes the notice';
    is scalar(my @dl = $lines->($hh)), 0, 'dry_run writes no log line';
    ok !-e "$hh/.hermes/overrun_fallback_seen.json", 'dry_run saves no seen state';
}
# cap 3 per run + one summary; per-session 10-minute limit
{   my $hh = $fresh->(); open my $f, '>', "$hh/.hermes/logs/agent.log";
    print $f refused('2026-10-29 17:39:0' . $_, "local-cap0000$_", 'grok-4.7', 'xai-oauth', 'billing/credits', 'openai/gpt-5.6-luna', 'openrouter') for 1 .. 5; close $f;
    my $o = $mk2->($hh, $t0)->fallback_notices;
    is scalar(grep { !$_->{summary} } @$o), 3, 'at most 3 notices per run';
    my ($sm) = grep { $_->{summary} } @$o;
    is $sm->{count}, 2, 'the other 2 rolled into one summary';
    my @l = $lines->($hh);
    is scalar @l, 4, '3 lines + 1 summary line';
    like $l[-1], qr/\[:4006 aisystem\] FALLBACK summary .*2 more fallback\(s\) not shown/, 'summary line prefixed';
    open $f, '>>', "$hh/.hermes/logs/agent.log";
    print $f refused('2026-10-29 17:42:00', 'local-cap00001', 'grok-4.7', 'xai-oauth', 'rate limit', 'cohere/north-mini-code:free', 'openrouter'); close $f;
    $o = $mk2->($hh, $t0 + 120)->fallback_notices;
    is scalar(grep { !$_->{summary} } @$o), 0, 'same session within 10 min: no own notice';
    is( (grep { $_->{summary} } @$o)[0]{count}, 1, '... rolled into the summary instead');
    open $f, '>>', "$hh/.hermes/logs/agent.log";
    print $f refused('2026-10-29 17:52:00', 'local-cap00001', 'grok-4.7', 'xai-oauth', 'rate limit', 'ollama/gemma', 'ollama-launch'); close $f;
    $o = $mk2->($hh, $t0 + 720)->fallback_notices;
    is scalar(grep { !$_->{summary} } @$o), 1, 'after 10 min the session notifies again';
}
# exact / suffix session match against a real SQLite db (no LIKE wildcards)
SKIP: {
    eval { require DBI; require DBD::SQLite; 1 } or skip 'no DBD::SQLite', 3;
    my $hh = $fresh->(); my $db = "$hh/.hermes/state.db";
    my $dbh = DBI->connect("dbi:SQLite:dbname=$db", '', '', { RaiseError => 1 });
    $dbh->do('CREATE TABLE sessions (id TEXT, session_key TEXT, cwd TEXT, git_branch TEXT)');
    $dbh->do(q{INSERT INTO sessions VALUES ('local-abc', 'agent:main:local:dm:local-abc', '/x/worktrees/planning/C', '')});
    $dbh->do(q{INSERT INTO sessions VALUES ('other', 'agent:main:local:dm:local-xyz', '/x/worktrees/CSSNavigation/C', '')});
    $dbh->disconnect;
    my $g = $G->new(home => $hh, app_root => $hh, no_notify => 1);
    is +($g->session_cwd('local-abc'))[0], '/x/worktrees/planning/C', 'exact id match';
    is +($g->session_cwd('local-xyz'))[0], '/x/worktrees/CSSNavigation/C', 'session_key suffix match';
    is scalar(() = $g->session_cwd('%')), 0, '% is not a wildcard';
}
done_testing();
