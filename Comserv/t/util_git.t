use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use_ok('Comserv::Util::Git') or BAIL_OUT('Cannot load Comserv::Util::Git');

# ---------------------------------------------------------------------------
# Minimal $c stub. Comserv::Util::Git only needs config(), path_to(), and the
# logging helper needs stash() + session(). We point the repo at the checkout
# root via COMSERV_GIT_REPO so repo_path resolves without a live Catalyst app.
# All operations exercised here are READ-ONLY — the repo is never mutated.
# ---------------------------------------------------------------------------
{
    package FakePath;
    sub new { bless {}, shift }
    sub stringify { $ENV{COMSERV_GIT_REPO} }

    package FakeReq;
    sub new  { bless {}, shift }
    sub param { undef }

    package FakeC;
    sub new { bless { stash => {}, session => {} }, shift }
    sub config   { {} }
    sub path_to  { FakePath->new }
    sub stash    { $_[0]->{stash} }
    sub session  { $_[0]->{session} }
    sub req      { FakeReq->new }
}

# Resolve the repo root (one level above the Comserv app dir) if not already set.
unless ($ENV{COMSERV_GIT_REPO}) {
    my $root = "$FindBin::Bin/../..";
    $ENV{COMSERV_GIT_REPO} = $root;
}

my $git = Comserv::Util::Git->new;
isa_ok($git, 'Comserv::Util::Git');

my $c = FakeC->new;

# Skip the whole suite gracefully if this isn't a git checkout.
my $probe = $git->_run($c, 'rev-parse', '--abbrev-ref', 'HEAD');
unless ($probe->{success}) {
    plan skip_all => 'Not a git repository (or git unavailable) — skipping';
}

# repo_path resolves to a non-empty string
ok(length($git->repo_path($c)), 'repo_path resolves to a non-empty path');

# current_branch returns a non-empty string
my $branch = $git->get_current_branch($c);
ok(defined $branch && length $branch, "current_branch returns a value ($branch)");

# current_branch_and_commit returns the live branch + short sha (the value the
# global header now uses, so it can never drift from the dashboard's branch).
my $live = $git->current_branch_and_commit($c);
ok(defined $live && ref $live eq 'HASH', 'current_branch_and_commit returns a hashref');
is($live->{branch}, $branch, 'current_branch_and_commit branch matches get_current_branch');
ok($live->{commit} =~ /^[a-f0-9]+$/, "current_branch_and_commit commit is a short sha ($live->{commit})");

# status parses to the documented hashref shape
my $status = $git->get_git_status($c);
is(ref $status, 'HASH', 'get_git_status returns a hashref');
is(ref $status->{staged_files},    'ARRAY', 'staged_files is an arrayref');
is(ref $status->{modified_files},  'ARRAY', 'modified_files is an arrayref');
is(ref $status->{untracked_files}, 'ARRAY', 'untracked_files is an arrayref');

# log(5) returns <= 5 entries, each with hash + message
my $commits = $git->get_recent_commits($c, 5);
is(ref $commits, 'ARRAY', 'get_recent_commits returns an arrayref');
cmp_ok(scalar(@$commits), '<=', 5, 'get_recent_commits honours the count cap');
if (@$commits) {
    ok($commits->[0]{hash} =~ /^[a-f0-9]+$/, 'commit hash looks like a sha');
    ok(length($commits->[0]{message}), 'commit has a message');
}

# local branches parse to an arrayref
my $locals = $git->get_local_branches($c);
is(ref $locals, 'ARRAY', 'get_local_branches returns an arrayref');

# tracking info shape
my $tracking = $git->get_tracking_info($c);
is(ref $tracking, 'HASH', 'get_tracking_info returns a hashref');
ok(exists $tracking->{ahead} && exists $tracking->{behind}, 'tracking has ahead/behind');

# ---- Whitelist enforcement (the security contract) ----
my $bad_sub = $git->_run($c, 'rmrf');
ok(!$bad_sub->{success}, 'unknown subcommand is refused');
like($bad_sub->{error}, qr/not an allowed git subcommand/, 'refusal message for bad subcommand');

my $bad_flag = $git->_run($c, 'log', '--output=/etc/passwd');
ok(!$bad_flag->{success}, 'disallowed flag is refused');
like($bad_flag->{error}, qr/not allowed for git log/, 'refusal message for bad flag');

# A user-looking value after -- must NOT be treated as a flag (positional safety).
my $dd = $git->_run($c, 'status', '--porcelain', '--', '--not-a-flag.txt');
ok($dd->{success}, 'positional argument after -- is accepted (not flag-scanned)');

done_testing();
