# "Update all branches from main" (Comserv::Util::Git::update_all_from_main) on throwaway repos.
# Rewritten 2026-11-18 (Shanta: "fix update button"): no --autostash; preflight skips dirty, untracked
# and conflicting branches with the files named; worktrees found via `git worktree list` too.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin; use lib "$FindBin::Bin/../lib";
use Comserv::Util::Git;
use Comserv::Util::Logging;

my $log = Comserv::Util::Logging->instance;
my $c = bless { stash => {} }, 'MockC';
sub MockC::stash { $_[0]->{stash} } sub MockC::req { undef } sub MockC::config { {} } sub MockC::logging { $log }
my $git = Comserv::Util::Git->new(logging => $log);

local $ENV{GIT_AUTHOR_NAME} = 'T'; local $ENV{GIT_AUTHOR_EMAIL} = 't@example.invalid';
local $ENV{GIT_COMMITTER_NAME} = 'T'; local $ENV{GIT_COMMITTER_EMAIL} = 't@example.invalid';
local $ENV{GIT_CONFIG_NOSYSTEM} = 1; local $ENV{HOME} = tempdir(CLEANUP => 1);

sub g  { my ($dir, @a) = @_; system('git', '-C', $dir, '-c', 'core.hooksPath=/dev/null', @a) == 0 or die "git @a failed in $dir" }
sub gq { my ($dir, @a) = @_; my $o = qx{git -C '$dir' @a 2>/dev/null}; $o =~ s/\s+\z//; $o }
sub wr { my ($f, $t) = @_; open my $fh, '>', $f or die "$f: $!"; print $fh $t; close $fh }
sub rd { my ($f) = @_; open my $fh, '<', $f or die $!; local $/; <$fh> }

my $root = tempdir(CLEANUP => 1);
my $main = "$root/main";
mkdir $main;
g($main, 'init', '-q', '-b', 'main');
wr("$main/$_.txt", "$_ base\n") for qw(a b c);
g($main, 'add', '.'); g($main, 'commit', '-q', '-m', 'base');

my $base = "$root/wt"; mkdir $base;
# Layout 1 (<base>/<key>/Comserv), registered in worktrees.json.
my %ports = (clean => 4101, dirtyok => 4102, dirtyhit => 4103, dirtysame => 4104, diverged => 4105,
             conflict => 4106, untrk_same => 4107, untrk_diff => 4108, midmerge => 4109,
             listed => 4110, current => 4111);
for my $k (sort keys %ports) {
    mkdir "$base/$k";
    g($main, 'worktree', 'add', '-q', '-b', "br-$k", "$base/$k/Comserv", 'main');
}
# Layout 2 (<base>/<key>) and NOT in worktrees.json: only `git worktree list` knows it.
g($main, 'worktree', 'add', '-q', '-b', 'br-flat', "$base/flat", 'main');
# A detached worktree must be skipped, not merged.
g($main, 'worktree', 'add', '-q', '--detach', "$root/detached", 'main');

my $cfg = { base_dir => $base, update_all_skip => ['listed'],
            branches => { (map { ($_ => { port => $ports{$_} }) } keys %ports), ghost => { port => 4199 } } };

# main moves on: changes a and b, adds n.txt
my $main_a = "main a\n"; my $main_n = "new file from main\n";
my %pre_main_wt = ();
wr("$base/dirtyok/Comserv/c.txt", "local edit, main does not touch c\n");
wr("$base/dirtyhit/Comserv/a.txt", "local edit on a\n");
wr("$base/diverged/Comserv/d.txt", "branch file\n"); g("$base/diverged/Comserv", 'add', '.'); g("$base/diverged/Comserv", 'commit', '-q', '-m', 'branch work');
wr("$base/conflict/Comserv/a.txt", "branch a\n");   g("$base/conflict/Comserv", 'add', '.'); g("$base/conflict/Comserv", 'commit', '-q', '-m', 'branch a');
wr("$base/midmerge/Comserv/a.txt", "mid a\n");      g("$base/midmerge/Comserv", 'add', '.'); g("$base/midmerge/Comserv", 'commit', '-q', '-m', 'mid a');
wr("$main/a.txt", $main_a); wr("$main/b.txt", "main b\n"); wr("$main/n.txt", $main_n);
g($main, 'add', '.'); g($main, 'commit', '-q', '-m', 'main moves');
g("$base/current/Comserv", 'merge', '-q', '--ff-only', 'main');
wr("$base/dirtysame/Comserv/a.txt", $main_a);                   # uncommitted copy of main's version
wr("$base/untrk_same/Comserv/n.txt", $main_n);                  # leftover copy of main's new file
wr("$base/untrk_diff/Comserv/n.txt", "someone's own n\n");      # untracked file that differs
system("git -C '$base/midmerge/Comserv' -c core.hooksPath=/dev/null merge -q main >/dev/null 2>&1");   # leaves a conflicted merge open
ok Comserv::Util::Git::_worktree_merge_in_progress("$base/midmerge/Comserv"), 'fixture: midmerge has a merge open';

my @all = (keys %ports, 'flat');
my $dir_of = sub { $_[0] eq 'flat' ? "$base/flat" : "$base/$_[0]/Comserv" };
my %pre = map { ($_ => gq($dir_of->($_), 'rev-parse', 'HEAD')) } @all;
my $listen = sub { ($_[0] // 0) == 4101 };

# ---- discovery
my @t = $git->_update_all_targets($c, $cfg, $main);
my %tk = map { ($_->{key} => $_) } @t;
ok $tk{flat}, 'layout-2 worktree found via git worktree list (not in worktrees.json)';
is $tk{flat}{path}, "$base/flat", 'flat path';
is $tk{flat}{source}, 'git worktree list', 'flat source';
is $tk{clean}{port}, 4101, 'port comes from worktrees.json';
is $tk{clean}{path}, "$base/clean/Comserv", 'layout-1 path';
ok $tk{detached} && $tk{detached}{detached}, 'detached worktree listed as detached';
is $tk{ghost}{source}, 'worktrees.json', 'json-only key kept';
ok !(grep { $_->{path} eq $main } @t), 'main checkout itself is not a target';

# ---- dry run: nothing moves
my $dry = $git->update_all_from_main($c, { dry_run => 1, config => $cfg, main_repo => $main, port_listening => $listen });
my %d = map { ($_->{key} => $_) } @{ $dry->{rows} };
is $d{clean}{status}, 'would_update', 'dry: clean -> would_update';
is $d{flat}{status}, 'would_update', 'dry: discovered flat worktree -> would_update';
is $d{dirtyok}{status}, 'would_update', 'dry: dirty file main does not touch -> still merges';
is $d{dirtyhit}{status}, 'skipped_dirty', 'dry: dirty file main changes -> skipped_dirty';
is_deeply $d{dirtyhit}{files}, ['a.txt'], 'dry: names the dirty file';
is $d{conflict}{status}, 'skipped_conflict', 'dry: conflict predicted by merge-tree';
is_deeply $d{conflict}{files}, ['a.txt'], 'dry: conflict file named';
is $d{listed}{status}, 'skipped', 'dry: update_all_skip honoured';
is $d{current}{status}, 'up_to_date', 'dry: already current';
is $d{detached}{status}, 'skipped', 'dry: detached skipped';
is $d{ghost}{status}, 'missing', 'dry: json key with no checkout -> missing';
is_deeply $dry->{restart_ports}, [4101], 'dry: lists ports that will auto-restart';
like $dry->{summary}, qr/^Preview \(nothing changed\)/, 'dry summary';
is gq($dir_of->($_), 'rev-parse', 'HEAD'), $pre{$_}, "dry: $_ HEAD unchanged" for @all;

# ---- update
my $res = $git->update_all_from_main($c, { config => $cfg, main_repo => $main, port_listening => $listen });
my %r = map { ($_->{key} => $_) } @{ $res->{rows} };
my $main_sha = gq($main, 'rev-parse', 'main');

is $r{clean}{status}, 'updated', 'clean updated';
is $r{clean}{action}, 'updated', 'action mirrors status for old callers';
is $r{clean}{before_sha}, $pre{clean}, 'before_sha recorded';
is $r{clean}{after_sha}, $main_sha, 'clean fast-forwarded to main';
is $r{clean}{pre_merge_commit}, $pre{clean}, 'pre_merge_commit kept for old view';
is $r{flat}{status}, 'updated', 'layout-2 worktree updated';
is gq("$base/flat", 'rev-parse', 'HEAD'), $main_sha, 'flat now at main';

is $r{dirtyok}{status}, 'updated', 'dirty but unaffected -> updated';
is rd("$base/dirtyok/Comserv/c.txt"), "local edit, main does not touch c\n", 'uncommitted edit kept as is';
is rd("$base/dirtyok/Comserv/a.txt"), $main_a, 'main change arrived';
is_deeply $r{dirtyok}{kept_uncommitted}, ['c.txt'], 'kept edit listed';

is $r{dirtyhit}{status}, 'skipped_dirty', 'dirty file main changes -> skipped_dirty';
is_deeply $r{dirtyhit}{files}, ['a.txt'], 'skip lists the file';
like $r{dirtyhit}{file_notes}{'a.txt'}, qr/differs from main/, 'differing edit classified';
is rd("$base/dirtyhit/Comserv/a.txt"), "local edit on a\n", 'local edit untouched';
is gq("$base/dirtyhit/Comserv", 'rev-parse', 'HEAD'), $pre{dirtyhit}, 'dirtyhit HEAD unchanged';
ok $r{dirtyhit}{needs_manual}, 'dirtyhit flagged needs_manual';

is $r{dirtysame}{status}, 'skipped_dirty', 'uncommitted copy of main version still blocks git';
like $r{dirtysame}{file_notes}{'a.txt'}, qr/same as main - safe to discard/, '...but is classified safe to discard';

is $r{untrk_same}{status}, 'skipped_untracked', 'untracked file main would overwrite -> skipped_untracked';
is_deeply $r{untrk_same}{files}, ['n.txt'], 'untracked file named';
like $r{untrk_same}{file_notes}{'n.txt'}, qr/identical to main - safe to delete/, 'identical copy classified';
is $r{untrk_diff}{status}, 'skipped_untracked', 'differing untracked file -> skipped_untracked';
like $r{untrk_diff}{file_notes}{'n.txt'}, qr/differs from main/, 'differing copy classified';
is rd("$base/untrk_diff/Comserv/n.txt"), "someone's own n\n", 'untracked file untouched';

is $r{diverged}{status}, 'updated', 'diverged merged';
is gq("$base/diverged/Comserv", 'rev-list', '--count', "$pre{diverged}..HEAD"), 2, 'merge commit + main commit';

is $r{conflict}{status}, 'skipped_conflict', 'conflict skipped before merging';
is_deeply $r{conflict}{files}, ['a.txt'], 'conflict file named';
ok !Comserv::Util::Git::_worktree_merge_in_progress("$base/conflict/Comserv"), 'no merge left open';
is gq("$base/conflict/Comserv", 'rev-parse', 'HEAD'), $pre{conflict}, 'conflict branch unchanged';
is gq("$base/conflict/Comserv", 'status', '--porcelain'), '', 'conflict worktree still clean';

is $r{midmerge}{status}, 'skipped_dirty', 'worktree with a merge already open -> skipped_dirty';
is_deeply $r{midmerge}{files}, ['a.txt'], 'unmerged file listed';
ok Comserv::Util::Git::_worktree_merge_in_progress("$base/midmerge/Comserv"), 'the open merge is left for the human, not aborted';

is $r{listed}{status}, 'skipped', 'listed skipped';
is $r{listed}{reason}, 'in update_all_skip (worktrees.json)', 'listed reason';
is $r{current}{status}, 'up_to_date', 'current up to date';
is $r{detached}{status}, 'skipped', 'detached skipped';
is gq("$root/detached", 'rev-parse', 'HEAD'), gq($main, 'rev-parse', 'main~1'), 'detached HEAD not moved';
is $r{ghost}{status}, 'missing', 'missing reported';

is gq($main, 'stash', 'list'), '', 'no stash entries created (no --autostash)';
is_deeply $res->{restart_ports}, [4101], 'auto-restarted ports reported';
like $res->{summary}, qr/Needs attention: .*conflict=br-conflict \(:4106\) skipped_conflict \[a\.txt\]/, 'summary names conflicting branch and file';
for my $row (@{ $res->{rows} }) {
    ok exists $row->{status} && ref $row->{files} eq 'ARRAY', "row $row->{key} has status and files";
}

# ---- second run: already-updated branches report up_to_date, still nothing stashed
my $again = $git->update_all_from_main($c, { config => $cfg, main_repo => $main, port_listening => sub { 0 } });
my %a = map { ($_->{key} => $_) } @{ $again->{rows} };
is $a{clean}{status}, 'up_to_date', 'second run: clean already current';
is $a{conflict}{status}, 'skipped_conflict', 'second run: conflict still skipped';

# ---- nothing to merge anywhere
my $quiet = $git->update_all_from_main($c, {
    config => { base_dir => "$root/none", branches => { current => { port => 4111 } } },
    main_repo => "$base/current/Comserv", port_listening => sub { 0 },
});
ok 1, 'quiet run did not die';

done_testing;
