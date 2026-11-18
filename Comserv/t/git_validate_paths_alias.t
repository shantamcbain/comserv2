use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Cwd ();

# ---------------------------------------------------------------------------
# Admin/Git::_validate_paths — app-relative path alias (todo #2564 follow-up).
#
# git status --porcelain reports REPO-ROOT-relative paths. This worktree's app
# lives one level down (.../aisystem/Comserv/Comserv), so the AI editor's
# collector sends "data/ai_trials/particle_1.state.json" while porcelain says
# "Comserv/data/ai_trials/particle_1.state.json" — every legit commit was
# rejected with "Rejected unsafe or unknown path(s)".
#
# Only the environment is faked (git output + repo/app dirs); the real
# _validate_paths body runs.
# ---------------------------------------------------------------------------

my $MOD  = 'Comserv::Controller::Admin::Git';
my $obj  = eval { require Comserv::Controller::Admin::Git; 1 };
plan skip_all => "cannot load $MOD: $@" unless $obj;

no warnings 'redefine';

{ package FakeGitService;
  sub new { my ($class, %o) = @_; bless { %o }, $class }
  sub resolve_target { my ($self) = @_; return { mode => $self->{mode} // 'local',
                                                repo => $self->{repo} // '/repo' } } }

{ package FakeC;
  sub new { my ($class, %o) = @_; bless { %o }, $class }
  sub stash { $_[0]{stash} ||= {} }
  sub path_to { my ($s, $rel) = @_; my $p = ($s->{appdir} || '/repo'); $p .= "/$rel" if defined $rel && length $rel; return FakePath->new($p) } }
  { package FakePath; sub new { my ($c, $p) = @_; bless \$p, $c } sub stringify { ${ $_[0] } } }

{ package FakeLog;
  sub new { bless { lines => [] }, shift }
  sub log_with_details { my ($s,$c,$l,$f,$ln,$m,$msg) = @_; push @{ $s->{lines} }, "$m: $msg"; 1 }
  sub lines { $_[0]{lines} } }

# A real temp tree so Cwd::abs_path behaves: <root>/Comserv = repo toplevel,
# <root>/Comserv/Comserv = app dir (exactly the worktree shape).
use File::Temp qw(tempdir);
my $root = tempdir(CLEANUP => 1);
my $repo = "$root/Comserv";
my $app  = "$repo/Comserv";
mkdir $repo or die $!;
mkdir $app  or die $!;

# The controller's accessors are `$self->{_git_service}` / `$self->{logging}`.
my $self = bless { _git_service => FakeGitService->new(repo => $repo),
                   logging      => FakeLog->new }, $MOD;
my $c = FakeC->new(stash => { git_target => 'local' }, appdir => $app);

# What the target repo really reports (repo-root-relative).
my $PORCELAIN = join("\n",
    ' M Comserv/data/ai_trials/particle_1.state.json',
    ' M Comserv/lib/Comserv/Model/AI2/Router.pm',
    '?? Comserv/new_file.tt',
    '',
);

my @calls;
{
    no strict 'refs';
    *{"${MOD}::_git_list"} = sub { my ($self, $c, @args) = @_; push @calls, "@args"; return ($PORCELAIN) };
}

my $v = $self->_validate_paths($c, [
    'data/ai_trials/particle_1.state.json',        # app-relative, was rejected
    'lib/Comserv/Model/AI2/Router.pm',             # app-relative, was rejected
    'Comserv/data/ai_trials/particle_1.state.json',# already root-relative
    'new_file.tt',                                 # app-relative new file
]);

is_deeply($v->{invalid}, [], 'no legitimate path is rejected any more')
    or diag('invalid: ' . join(', ', @{ $v->{invalid} }));
is_deeply($v->{valid}, [
    'Comserv/data/ai_trials/particle_1.state.json',
    'Comserv/lib/Comserv/Model/AI2/Router.pm',
    'Comserv/data/ai_trials/particle_1.state.json',
    'Comserv/new_file.tt',
], 'valid paths come back repo-root-relative (what git is given next)');
is($v->{untracked}{'Comserv/new_file.tt'}, 1, 'the aliased new file is still marked untracked');
is($v->{alias_prefix}, 'Comserv/', 'alias prefix computed from app dir vs repo toplevel');

# --- guards still hold -----------------------------------------------------
my $bad = $self->_validate_paths($c, [
    '../etc/passwd',              # traversal
    '/etc/passwd',                # absolute
    'Comserv/not/in/porcelain.tt' # unknown
]);
is(scalar @{ $bad->{invalid} }, 3, 'traversal, absolute and unknown paths are still rejected');
is_deeply($bad->{valid}, [], 'nothing valid out of those');

# --- an app-relative path that is genuinely absent is still rejected -------
my $miss = $self->_validate_paths($c, ['data/nope.json']);
is(scalar @{ $miss->{invalid} }, 1, 'app-relative path absent from porcelain is rejected');

# --- remote targets never get an alias (paths are not local) --------------
$self->{_git_service} = FakeGitService->new(repo => $repo, mode => 'ssh');
my $rem = $self->_validate_paths($c, ['data/ai_trials/particle_1.state.json']);
is($rem->{alias_prefix}, '', 'no alias for an SSH target');
is(scalar @{ $rem->{invalid} }, 1, 'SSH target keeps strict root-relative validation');

done_testing();
