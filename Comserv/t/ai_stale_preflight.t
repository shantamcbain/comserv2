use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Comserv::Util::AI::StalePreflight;

# Stale-server preflight (AISYSTEM plan §5g). Drafted by Hermes
# (deepseek-v4-pro), reviewed/extended. Local /proc + temp dirs only.

my $SP = 'Comserv::Util::AI::StalePreflight';
my $now = time;

is($SP->can('evaluate')->()->{status}, 'DOWN', 'no process -> DOWN');
is(Comserv::Util::AI::StalePreflight::evaluate(proc_start_epoch => $now + 10, newest_mtime_epoch => $now, commit_epoch => $now - 5)->{status},
   'OK', 'process newer than files and commit -> OK');
my $r = Comserv::Util::AI::StalePreflight::evaluate(proc_start_epoch => $now, newest_mtime_epoch => $now + 10, newest_file_path => '/x/A.pm');
is($r->{status}, 'STALE', 'file newer -> STALE');
like($r->{reasons}[0], qr{file newer than process: /x/A\.pm}, '... names the file');
$r = Comserv::Util::AI::StalePreflight::evaluate(proc_start_epoch => $now, commit_epoch => $now + 10);
is($r->{status}, 'STALE', 'commit newer -> STALE');
like($r->{reasons}[0], qr/commit newer/, '... reason');
$r = Comserv::Util::AI::StalePreflight::evaluate(proc_start_epoch => $now, newest_mtime_epoch => $now - 60, commit_epoch => $now + 10);
is($r->{status}, 'OK', 'commit newer but every code file older -> OK (templates/docs-only commit)');
like($r->{reasons}[0], qr/no code file changed/, '... with a note');
is(Comserv::Util::AI::StalePreflight::evaluate(proc_start_epoch => $now, newest_mtime_epoch => $now + 1)->{status}, 'OK', 'within 2s grace -> OK');
is(Comserv::Util::AI::StalePreflight::evaluate(proc_start_epoch => $now, newest_mtime_epoch => $now + 30, grace_s => 60)->{status}, 'OK', 'custom grace');

my $pi = Comserv::Util::AI::StalePreflight::proc_info($$);
ok($pi->{start_epoch} && $now - $pi->{start_epoch} >= 0 && $now - $pi->{start_epoch} < 86400, 'proc_info($$) start time is sane');
ok($pi->{cwd}, '... cwd');
like($pi->{cmd}, qr/perl|prove/, '... cmdline');
ok(!defined Comserv::Util::AI::StalePreflight::proc_info(999999999), 'missing pid -> undef');

my $tmp = tempdir(CLEANUP => 1);
make_path("$tmp/lib/X", "$tmp/.git", "$tmp/root/static/ai", "$tmp/lib/node_modules", "$tmp/data");
my %f = ("lib/X/Old.pm" => $now - 300, "lib/X/New.pm" => $now - 100, "lib/notes.txt" => $now + 500,
         ".git/hook.pm" => $now + 500, "root/static/ai/x.js" => $now + 500, "lib/node_modules/y.js" => $now + 500,
         "data/z.pl" => $now + 500);
for (keys %f) { open my $fh, '>', "$tmp/$_" or die "$_: $!"; print $fh "1;\n"; close $fh; utime $f{$_}, $f{$_}, "$tmp/$_" }
my $nf = Comserv::Util::AI::StalePreflight::newest_file($tmp, dirs => ['.']);
like($nf->{path}, qr{lib/X/New\.pm$}, 'newest code file wins; .git, static/ai, node_modules, data, .txt ignored');
is($nf->{scanned}, 2, '... only the two .pm files scanned');
is(Comserv::Util::AI::StalePreflight::newest_file($tmp)->{path}, "$tmp/lib/X/New.pm", 'default dirs lib/root/script');

$r = Comserv::Util::AI::StalePreflight::check(pid => $$, worktree => $tmp, label => 't');
is($r->{status}, 'OK', 'check: files older than this process -> OK');
like($r->{proc_start_pt}, qr/^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d PT$/, '... times in PT');
like($r->{checked_pt}, qr/ PT$/, '... checked_pt');
utime $now + 100, $now + 100, "$tmp/lib/X/Old.pm";
$r = Comserv::Util::AI::StalePreflight::check(pid => $$, worktree => $tmp);
is($r->{status}, 'STALE', 'check: touched file -> STALE');
like($r->{reasons}[0], qr/Old\.pm/, '... names it');

$r = Comserv::Util::AI::StalePreflight::check(port => 1, worktree => $tmp, label => 'nothing on :1');
is($r->{status}, 'DOWN', 'no listener -> DOWN');

my @t = Comserv::Util::AI::StalePreflight::default_targets();
ok((grep { ($_->{port} // 0) == 4003 } @t), 'default targets include :4003 (read-only)');
ok((grep { ($_->{label} // '') =~ /Hermes/ } @t), '... and Hermes');
my $all = Comserv::Util::AI::StalePreflight::check_all(targets => [ { pid => $$, worktree => $tmp, label => 'me' }, { port => 1, label => 'none' } ]);
is_deeply([ map { $_->{status} } @$all ], [ 'STALE', 'DOWN' ], 'check_all over custom targets');

done_testing();
