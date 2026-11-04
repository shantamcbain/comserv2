# Oct 31 2026 (Shanta): "Update all branches from main" (Comserv::Util::Git::update_all_from_main) on throwaway repos.
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

sub g { my ($dir, @a) = @_; system('git', '-C', $dir, '-c', 'core.hooksPath=/dev/null', @a) == 0 or die "git @a failed in $dir" }
sub wr { my ($f, $t) = @_; open my $fh, '>', $f or die $!; print $fh $t; close $fh }
sub rd { my ($f) = @_; open my $fh, '<', $f or die $!; local $/; <$fh> }

my $root = tempdir(CLEANUP => 1);
my $main = "$root/main";
mkdir $main;
g($main, 'init', '-q', '-b', 'main');
wr("$main/$_.txt", "$_ base\n") for qw(a b c);
g($main, 'add', '.'); g($main, 'commit', '-q', '-m', 'base');

my $base = "$root/wt";
my %ports = (clean => 4101, dirtyok => 4102, dirtyhit => 4103, diverged => 4104, conflict => 4105,
             Proxmox => 4016, three => 4003, listed => 4106, current => 4107);
for my $k (sort keys %ports) {
    mkdir "$base"; mkdir "$base/$k";
    g($main, 'worktree', 'add', '-q', '-b', "br-$k", "$base/$k/Comserv", 'main');
}
my $cfg = { base_dir => $base, update_all_skip => ['listed'],
            branches => { map { ($_ => { port => $ports{$_} }) } keys %ports } };

# branch-side state
wr("$base/dirtyok/Comserv/c.txt", "local edit, main does not touch c\n");
wr("$base/dirtyhit/Comserv/a.txt", "local edit on a\n");
wr("$base/diverged/Comserv/d.txt", "branch file\n"); g("$base/diverged/Comserv", 'add', '.'); g("$base/diverged/Comserv", 'commit', '-q', '-m', 'branch work');
wr("$base/conflict/Comserv/a.txt", "branch a\n");   g("$base/conflict/Comserv", 'add', '.'); g("$base/conflict/Comserv", 'commit', '-q', '-m', 'branch a');
# main moves on (changes a and b); 'current' fast-forwards first so it is already up to date
wr("$main/a.txt", "main a\n"); wr("$main/b.txt", "main b\n");
g($main, 'add', '.'); g($main, 'commit', '-q', '-m', 'main moves');
g("$base/current/Comserv", 'merge', '-q', '--ff-only', 'main');

my %pre = map { ($_ => do { my $r = $git->_run($c, 'rev-parse', 'HEAD', { repo => "$base/$_/Comserv" }); (my $h = $r->{output}) =~ s/\s+//g; $h }) } keys %ports;
my $listen = sub { ($_[0] // 0) == 4101 };   # pretend only :4101 has a -r server running

# ---- dry run: nothing moves
my $dry = $git->update_all_from_main($c, { dry_run => 1, config => $cfg, port_listening => $listen });
my %d = map { ($_->{key} => $_) } @{ $dry->{rows} };
is $d{clean}{action}, 'would_ff', 'dry: clean -> would_ff';
is $d{dirtyok}{action}, 'would_ff', 'dry: dirty, untouched file -> would_ff';
is $d{dirtyhit}{action}, 'would_skip_local_changes', 'dry: dirty file main changes -> predicted refusal';
is_deeply $d{dirtyhit}{files}, ['a.txt'], 'dry: refusal names the file';
is $d{diverged}{action}, 'would_merge', 'dry: diverged -> would_merge';
is $d{Proxmox}{action}, 'skipped_proxmox', 'dry: Proxmox skipped';
is $d{three}{action}, 'skipped_4003', 'dry: :4003 skipped without the box';
is $d{listed}{action}, 'skipped_listed', 'dry: worktrees.json skip list honoured';
is $d{current}{action}, 'uptodate', 'dry: already current';
is_deeply $dry->{restart_ports}, [4101], 'dry: lists ports that will auto-restart';
like $dry->{summary}, qr/Preview .*:4101/, 'dry summary';
for my $k (keys %ports) {
    my $r = $git->_run($c, 'rev-parse', 'HEAD', { repo => "$base/$k/Comserv" }); (my $h = $r->{output}) =~ s/\s+//g;
    is $h, $pre{$k}, "dry: $k HEAD unchanged";
}

# ---- update
my $res = $git->update_all_from_main($c, { config => $cfg, port_listening => $listen });
my %r = map { ($_->{key} => $_) } @{ $res->{rows} };
is $r{clean}{action}, 'fast_forwarded', 'clean fast-forwarded';
is $r{clean}{pre_merge_commit}, $pre{clean}, 'pre-merge commit recorded';
isnt $r{clean}{post_merge_commit}, $pre{clean}, 'post-merge commit recorded';
is $r{dirtyok}{action}, 'fast_forwarded', 'dirty but unaffected -> merged';
is rd("$base/dirtyok/Comserv/c.txt"), "local edit, main does not touch c\n", 'uncommitted edit kept';
is rd("$base/dirtyok/Comserv/a.txt"), "main a\n", 'main change arrived';
is $r{dirtyhit}{action}, 'skipped_local_changes', 'dirty file main changes -> skipped_local_changes';
is_deeply $r{dirtyhit}{files}, ['a.txt'], 'refusal lists the file';
is rd("$base/dirtyhit/Comserv/a.txt"), "local edit on a\n", 'local edit untouched';
is $r{diverged}{action}, 'merged', 'diverged merged with --no-ff';
my $par = $git->_run($c, 'rev-list', '--count', "$pre{diverged}..HEAD", { repo => "$base/diverged/Comserv" });
like $par->{output}, qr/^\s*2\s*$/, 'merge commit + main commit';
is $r{conflict}{action}, 'conflict', 'conflict reported';
is_deeply $r{conflict}{files}, ['a.txt'], 'conflict file named';
like $r{conflict}{reason}, qr/\(aborted\)/, 'conflict aborted';
ok !Comserv::Util::Git::_worktree_merge_in_progress("$base/conflict/Comserv"), 'no merge left open';
{ my $h = $git->_run($c, 'rev-parse', 'HEAD', { repo => "$base/conflict/Comserv" }); (my $x = $h->{output}) =~ s/\s+//g;
  is $x, $pre{conflict}, 'conflict branch unchanged'; }
my $cst = $git->_run($c, 'status', '--porcelain', { repo => "$base/conflict/Comserv" });
is $cst->{output}, '', 'conflict worktree clean after abort';
is $r{Proxmox}{action}, 'skipped_proxmox', 'Proxmox never touched';
is $r{three}{action}, 'skipped_4003', ':4003 skipped';
is_deeply $res->{restart_ports}, [4101], 'auto-restarted ports reported';

# ---- :4003 with the box ticked
my $r3 = $git->update_all_from_main($c, { include_4003 => 1, config => $cfg, port_listening => sub { 0 } });
my ($t3) = grep { $_->{key} eq 'three' } @{ $r3->{rows} };
is $t3->{action}, 'fast_forwarded', ':4003 updated when ticked';
my ($p3) = grep { $_->{key} eq 'Proxmox' } @{ $r3->{rows} };
is $p3->{action}, 'skipped_proxmox', 'Proxmox still skipped';

done_testing;
