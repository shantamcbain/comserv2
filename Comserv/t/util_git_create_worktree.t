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

# Minimal mock $c — just enough for Git.pm (logging + config + stash + req).
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

my $git = Comserv::Util::Git->new(logging => $log);

my $branch = 'wt-test-xyz';
my $base   = $git->worktree_base_dir // "$ENV{HOME}/.comserv/worktrees";
my $wt_dir = "$base/$branch/Comserv";
$git->remove_worktree($c, $branch) if -d $wt_dir;

my $jf   = File::Spec->catfile('/home/shanta/PycharmProjects/comserv2/Comserv', 'root', 'config', 'worktrees.json');
my $before = decode_json(_slurp($jf));

# 1) create
my $r = $git->create_worktree($c, $branch, { parent => 'main' });
ok($r->{success}, "create_worktree succeeded") or diag explain $r;
is($r->{branch}, $branch, "branch echoed");
ok($r->{port} >= 4001, "port >= 4001 (got $r->{port})");
ok(-d $wt_dir, "worktree dir created: $wt_dir");
ok(-f "$wt_dir/Comserv/script/comserv_server.pl", "worktree has app script at Comserv/script/");

# 2) JSON updated
my $mid = decode_json(_slurp($jf));
ok($mid->{branches}{$branch}, "JSON has entry for $branch");
is($mid->{branches}{$branch}{port}, $r->{port}, "JSON port == returned port");

# 3) git branch exists
my $br = $git->_run($c, 'branch', '--list', $branch);
like($br->{output}, qr/\Q$branch\E/, "git branch $branch exists");

# 4) remove -> full cleanup
my $rr = $git->remove_worktree($c, $branch);
ok($rr->{success}, "remove_worktree succeeded") or diag explain $rr;
ok(!-d $wt_dir, "worktree dir removed");
my $after = decode_json(_slurp($jf));
ok(!$after->{branches}{$branch}, "JSON entry removed (port freed)");
my $br2 = $git->_run($c, 'branch', '--list', $branch);
unlike($br2->{output}, qr/\Q$branch\E/, "git branch $branch deleted");
is($after->{port_start}, $before->{port_start}, "port_start preserved");

done_testing();

sub _slurp { my ($f)=@_; open my $fh,'<',$f or die "read $f: $!"; local $/; my $s=<$fh>; close $fh; $s }
