use strict;
use warnings;
use Test::More;
use lib 'lib';
use Comserv::Util::Git;
use Comserv::Util::Logging;
use JSON::MaybeXS;
use File::Spec;

# Point the git repo at the real checkout so repo_path() resolves without Catalyst.
$ENV{COMSERV_GIT_REPO} = '/home/shanta/PycharmProjects/comserv2';

my $log = Comserv::Util::Logging->instance;
my $c = bless {
    logging => $log,
    config  => { git_repo_path => '/home/shanta/PycharmProjects/comserv2' },
    stash   => {},
    req     => undef,
}, 'MockC';
sub MockC::logging { $_[0]->{logging} }
sub MockC::config  { $_[0]->{config} }
sub MockC::stash   { $_[0]->{stash} }
sub MockC::req     { $_[0]->{req} }

my $jf = File::Spec->catfile('/home/shanta/PycharmProjects/comserv2/Comserv',
    'root', 'config', 'worktrees.json');

sub slurp { my ($f)=@_; open my $fh,'<',$f or die "read $f: $!"; local $/; my $s=<$fh>; close $fh; $s }
sub writej { my ($f,$j)=@_; open my $fh,'>',$f or die "write $f: $!"; print $fh encode_json($j); close $fh }

# Force the package-level config cache to drop by guaranteeing a forward mtime jump.
# The cache is shared process-wide, so we must ensure the on-disk file is genuinely
# newer than whatever mtime the cache holds. Sleep 1s so the 1-second mtime granularity
# is exceeded, then re-read via the public builder.
sub reify {
    sleep 1;
    utime($jf, time(), time());
    Comserv::Util::Git->new(logging => $log)->build_worktree_list;
}

my $orig = slurp($jf);  # restore afterwards so the system is untouched

# --- Case 1: classic collision — 4001..4004 taken, next must be 4005 ---
{
    my $j = {
        port_start => 4000,
        base_dir   => '/home/shanta/.comserv/worktrees',
        branches   => {
            InventoryAccounting => { port => 4001, label => 'InventoryAccounting', url => '/planning/daily' },
            DockerHA           => { port => 4002, label => 'DockerHA',           url => '/planning/daily' },
            '3d'               => { port => 4003, label => '3d',                 url => '/planning/daily' },
            planning           => { port => 4004, label => 'planning',           url => '/planning/daily' },
        },
    };
    writej($jf, $j);
    reify();
    my $g = Comserv::Util::Git->new(logging => $log);
    my $p = $g->next_free_port($c);
    is($p, 4005, "next_free_port skips 4001-4004 and returns 4005 (got $p)");

    my $branch = 'wt-collide-test';
    my $base = $g->worktree_base_dir // "$ENV{HOME}/.comserv/worktrees";
    my $wt_dir = "$base/$branch/Comserv";
    $g->remove_worktree($c, $branch) if -d $wt_dir;
    my $r = $g->create_worktree($c, $branch, { parent => 'main' });
    ok($r->{success}, "create_worktree succeeded") or diag explain $r;
    is($r->{port}, 4005, "create_worktree did NOT reuse taken port 4004 (got $r->{port})");
    my $after = decode_json(slurp($jf))->{branches};
    is($after->{planning}{port}, 4004, "port 4004 still uniquely owned by 'planning'");
    is($after->{$branch}{port}, 4005, "new branch owns 4005");
    $g->remove_worktree($c, $branch);
}

# --- Case 2: stale-cache scenario — an out-of-band writer claims a port the cache hasn't seen ---
{
    my $old = {
        port_start => 4000,
        base_dir   => '/home/shanta/.comserv/worktrees',
        branches   => { InventoryAccounting => { port => 4001, url => '/planning/daily' } },
    };
    writej($jf, $old);
    reify();
    my $g = Comserv::Util::Git->new(logging => $log);
    my $p1 = $g->next_free_port($c);
    is($p1, 4002, "first free is 4002 (only 4001 taken)");

    # Out-of-band writer claims 4002 (simulates a second worker) and writes the file.
    my $cur = decode_json(slurp($jf));
    $cur->{branches}{otherworker} = { port => 4002, label => 'otherworker', url => '/planning/daily' };
    writej($jf, $cur);
    reify();  # sleep 1 + bump mtime so the mtime-aware cache MUST refresh

    my $p2 = $g->next_free_port($c);
    is($p2, 4003, "after out-of-band claim of 4002, next_free_port returns 4003 (got $p2) — stale cache fixed");
}

# restore real JSON
writej($jf, decode_json($orig));
sleep 1; utime($jf, time(), time());

done_testing();
