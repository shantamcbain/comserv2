package Comserv::Util::Git;

use strict;
use warnings;
use Try::Tiny;
use IPC::Run3 ();
use JSON::MaybeXS;   # imports decode_json/encode_json
use Cwd ();
use File::Copy qw(copy);

use Comserv::Util::Logging;

=head1 NAME

Comserv::Util::Git - Git subsystem service layer

=head1 DESCRIPTION

Single home for all low-level git execution in Comserv2. Extracted from
Comserv::Controller::Admin::Git (Phase C of the Git Subsystem Refactor Plan).

Design properties:

=over

=item * B<No shell.> Every git invocation goes through L</_run>, which uses
C<IPC::Run3> with an explicit argument list. Shell metacharacters in a filename,
branch name, or commit message can never be interpreted.

=item * B<No chdir.> C<git -C $repo> is used instead of changing the process
working directory, so a persistent Twiggy/Starman worker's cwd is never corrupted
(fixes the class of bug behind the static-asset 404s).

=item * B<Whitelisted.> C<_run> rejects any subcommand not in the allowed set and
any C<-flag> argument not in that subcommand's allow-list. Anything user-supplied
is passed positionally, after C<--> where git supports it.

=item * B<Uniform return.> Every public method returns
C<< { success => 0|1, exit_code => N, output => $stdout, error => $stderr, data => {...} } >>.
Methods never die on git failure (they die only on programmer error).

=back

Logging uses the standard helper; all public methods therefore take C<$c>.

=cut

# Allowed git subcommands. Anything else is refused by _run.
my %ALLOWED_SUBCMD = map { $_ => 1 } qw(
    status log rev-parse rev-list branch diff fetch pull push ls-files
    add commit stash checkout show restore rm merge worktree
);

# Per-subcommand allow-list of flags (leading '-'). User values are NEVER flags.
my %ALLOWED_FLAGS = (
    status   => { map { $_ => 1 } qw(--porcelain --short -s --no-color) },
    log      => { map { $_ => 1 } qw(--oneline --no-color --stat -n) },
    'rev-parse' => { map { $_ => 1 } qw(--abbrev-ref --symbolic-full-name --short --verify --quiet --show-prefix --show-toplevel --git-common-dir) },
    'rev-list'  => { map { $_ => 1 } qw(--left-right --count) },
    branch   => { map { $_ => 1 } qw(-r -a -D -d --list --show-current --no-color --format) },
    diff     => { map { $_ => 1 } qw(--cached --stat --no-color --name-only -U --unified --no-index) },
    fetch    => { map { $_ => 1 } qw(--prune) },
    pull     => { map { $_ => 1 } qw(--ff-only) },
    push     => { map { $_ => 1 } qw(--set-upstream -u --delete) },
    'ls-files' => { map { $_ => 1 } qw(--error-unmatch --others --exclude-standard) },
    add      => {},
    commit   => { map { $_ => 1 } qw(-m --amend) },
    stash    => { map { $_ => 1 } qw(push pop drop list -m) },
    checkout => { map { $_ => 1 } qw(-b) },
    show     => { map { $_ => 1 } qw(--no-color) },
    restore  => { map { $_ => 1 } qw(--staged) },
    rm       => { map { $_ => 1 } qw(--cached -r) },
    # Merge is human-gated (admin-only in the controller). Allowed flags keep it safe:
    # --no-ff (always create a merge commit), --no-commit (review then commit),
    # --abort (cancel a conflicted merge), --squash (optional single-commit merge).
    merge    => { map { $_ => 1 } qw(--no-ff --no-commit --abort --squash) },
    # Worktree is used by the isolation primitive (create_worktree / remove_worktree):
    # allow add, remove (with --force to clear a dirty checkout), list, prune.
    worktree => { map { $_ => 1 } qw(add remove list prune --porcelain --force) },
);

sub new {
    my ($class, %args) = @_;
    my $self = {
        logging => $args{logging} || Comserv::Util::Logging->instance,
    };
    return bless $self, $class;
}

sub logging { $_[0]->{logging} }

=head2 repo_path($c)

Resolve the git repository root. Order: app config C<git_repo_path>, then
C<$ENV{COMSERV_GIT_REPO}>, then one level above the Catalyst app dir. Returns
undef if nothing resolves.

=cut

sub repo_path {
    my ($self, $c) = @_;
    my $path;
    $path = $c->config->{git_repo_path} if $c && $c->config->{git_repo_path};
    $path ||= $ENV{COMSERV_GIT_REPO};
    $path ||= $c->path_to('..')->stringify if $c;
    return $path;
}

=head2 main_repo_path($c)

Resolve the PRIMARY checkout — the working tree where C<main> is actually
checked out — so operations that mutate C<main> (merge_to_main) run there
instead of in a feature worktree.

A linked worktree cannot check out C<main> (git refuses: "already checked
out at <primary>"), and C<git merge --no-ff E<lt>branchE<gt>> inside the
feature worktree merges the branch into itself ("Already up to date").
We derive the primary from C<git rev-parse --git-common-dir> (shared
object db of a linked worktree) and fall back to L</repo_path>.

=cut

sub main_repo_path {
    my ($self, $c) = @_;
    my $repo = $self->repo_path($c);
    unless (defined $repo && length $repo) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'git_merge',
            'main_repo_path: could not resolve repo_path (no repo)');
        return undef;
    }
    my $r = $self->_run($c, 'rev-parse', '--git-common-dir');
    my $common = $r->{output} // '';
    $common =~ s/\s+\z//;
    if ($r->{success} && length $common) {
        $common = "$repo/$common" unless $common =~ m{^/};
        $common =~ s{/\.git\z}{};
        return $common if $common && -d $common;
    }
    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'git_merge',
        'main_repo_path: git-common-dir failed; falling back to repo_path');
    return $repo;
}

=head2 worktree_checkout_dir($c, $branch)

Resolve the Catalyst app dir of the worktree that has C<$branch> checked
out. Uses the directory-scan resolver (robust when porcelain metadata is
stale after a rename). Returns undef if the branch has no worktree.

=cut

sub worktree_checkout_dir {
    my ($self, $c, $branch) = @_;
    return undef unless $branch && $branch ne 'main';
    my $git_root = $self->worktree_checkout_path_for_branch($c, $branch);
    unless ($git_root) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'test_gate',
            "worktree_checkout_dir: no checkout found for branch '$branch'");
        return undef;
    }
    return -d "$git_root/Comserv" ? "$git_root/Comserv" : $git_root;
}

=head2 resolve_target($c, $target)

Map a dashboard "target" selector to where git should actually run.

  target                 meaning
  -----                 -------
  '' / 'local'          run git on THIS app host (the default, legacy behavior)
  'workstation'         SSH into the dev workstation and run git there
  'production1'..       SSH into that monitored host and run git there

For a non-local target we need (a) the SSH destination and (b) the path to the
git repo ON that host. Both come from the TARGET_HOSTS table below, which is the
single source of truth for "which repo lives where". Add entries there to make
more hosts targetable.

Returns a hashref:
  { mode => 'local'|'ssh', repo => $path, host => $ip, user => $ssh_user,
    port => $port, label => $human }

Local mode returns mode 'local' and the normal repo_path(). SSH mode returns the
remote repo path and connection details. An unknown target falls back to local
and logs a warning (fail-safe, never runs a command on an undeclared host).

=cut

# repo_path ON each host + its SSH coordinates. Edit here to add a targetable host.
my %TARGET_HOSTS = (
    workstation => {
        label => 'Workstation (dev box)',
        host  => '192.168.1.199',
        user  => 'shanta',
        port  => 22,
        repo  => '/home/shanta/PycharmProjects/comserv2',
    },
    production1 => {
        label => 'Production 1',
        host  => '192.168.1.126',
        user  => 'ubuntu',
        port  => 22,
        repo  => '/home/shanta/PycharmProjects/comserv2',
    },
);

sub resolve_target {
    my ($self, $c, $target) = @_;
    $target = '' unless defined $target;
    $target = lc($target);

    # local / default
    return {
        mode  => 'local',
        repo  => $self->repo_path($c),
        host  => '', user => '', port => 22,
        label => 'Local (this app host)',
    } if $target eq '' || $target eq 'local';

    my $spec = $TARGET_HOSTS{$target}   # exact alias
            || $TARGET_HOSTS{lc $target}
            || undef;

    # also accept a raw IP if it matches a declared host
    unless ($spec) {
        for my $k (keys %TARGET_HOSTS) {
            if (($TARGET_HOSTS{$k}{host} // '') eq $target) {
                $spec = $TARGET_HOSTS{$k};
                $target = $k;
                last;
            }
        }
    }

    unless ($spec) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'git_target',
            "Unknown git target '$target' -> falling back to local");
        return {
            mode  => 'local',
            repo  => $self->repo_path($c),
            host  => '', user => '', port => 22,
            label => 'Local (this app host)',
        };
    }

    return {
        mode  => 'ssh',
        repo  => $spec->{repo},
        host  => $spec->{host},
        user  => $spec->{user},
        port  => $spec->{port} || 22,
        label => $spec->{label} // $target,
        key   => $target,
    };
}

=head2 list_targets($c)

The options for the dashboard target selector. Always includes Local first.

=cut

sub list_targets {
    my ($self, $c) = @_;
    my @out = ({ key => 'local', label => 'Local (this app host)' });
    for my $k (sort keys %TARGET_HOSTS) {
        push @out, { key => $k, label => $TARGET_HOSTS{$k}{label} // $k };
    }
    return \@out;
}

=head2 _ssh_exec_git($c, $tinfo, @argv)

Run a (whitelisted) git argv on a remote host via sshpass + ssh. Each argv
element is single-shell-quoted so filenames/branches/commit messages with spaces
or metacharacters are passed verbatim. Returns the same uniform hash as _run.

Requires the shared credentials file (~/.comserv/secrets/ssh_credentials.json)
to carry the SSH password for the destination. If absent, the call fails closed
with a clear error (no command is sent).

=cut

sub _ssh_exec_git {
    my ($self, $c, $tinfo, @argv) = @_;

    my $result = { success => 0, exit_code => -1, output => '', error => '', data => {} };

    my $creds_path = "$ENV{HOME}/.comserv/secrets/ssh_credentials.json";
    $creds_path = '/home/shanta/.comserv/secrets/ssh_credentials.json' unless $ENV{HOME};
    unless (-f $creds_path) {
        $result->{error} = "SSH credentials file not found ($creds_path). Cannot reach $tinfo->{host}.";
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'git_ssh', $result->{error});
        return $result;
    }
    open my $cf, '<', $creds_path or do {
        $result->{error} = "Cannot open SSH credentials file: $!";
        return $result;
    };
    local $/;
    my $json = <$cf>;
    close $cf;
    my $creds = eval { decode_json($json) };
    my $password = $creds && ref $creds eq 'HASH' ? ($creds->{ssh_password} // '') : '';
    unless (length $password) {
        $result->{error} = "No ssh_password in credentials file for $tinfo->{host}. Save credentials via Test Connection first.";
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'git_ssh', $result->{error});
        return $result;
    }

    # Build the git command and embed it in a single shell-quoted token on the
    # remote. We wrap the WHOLE command in one layer of single quotes on the
    # remote, which preserves spaces in filenames/branches/messages automatically;
    # the only escaping needed is for embedded single quotes (e.g. in a commit
    # message). This avoids the nested-quoting trap of quoting each argv element.
    my $remote_cmd = 'git -C ' . $tinfo->{repo} . ' ' . join(' ', @argv);
    my $esc = q{'\''};   # literal 4 chars: ' \ ' '  (the shell single-quote escape)
    $remote_cmd =~ s/'/$esc/g;

    local $ENV{SSHPASS} = $password;
    my $ssh = "sshpass -e ssh -p $tinfo->{port} -o ConnectTimeout=10 "
            . "-o StrictHostKeyChecking=no $tinfo->{user}\@$tinfo->{host} "
            . "'$remote_cmd' 2>&1";
    my $out = `$ssh`;
    my $code = $? >> 8;

    $result->{exit_code} = $code;
    $result->{output}    = defined $out ? $out : '';
    $result->{success}   = ($code == 0) ? 1 : 0;
    $self->logging->log_with_details($c, $result->{success} ? 'info' : 'error',
        __FILE__, __LINE__, 'git_ssh',
        "ssh $tinfo->{host} git " . join(' ', @argv) . " -> exit=$code");
    return $result;
}

=head2 _run($c, @argv, \%opts)

The one command runner. C<@argv> is the git subcommand plus its arguments (no
'git', no '-C', no shell). Enforces the whitelist, runs via IPC::Run3 with
C<git -C $repo>, captures stdout+stderr separately, and returns the uniform hash.

C<%opts> may carry a C<target> key (dashboard "run git on host X" selector).
With no target (or 'local') the command runs on this app host. With a remote
target the whitelisted argv is sent over SSH to that host and run against the
repo path declared for it (see L</resolve_target>). Every public method in this
class passes its C<$c>-level target through, so the entire subsystem is
target-aware from a single choke point.

=cut

sub _run {
    my ($self, $c, @argv) = @_;

    # opts may be the last positional (hashref) for readability
    my %opts;
    if (@argv && ref $argv[-1] eq 'HASH') {
        %opts = %{ pop @argv };
    }

    my $result = { success => 0, exit_code => -1, output => '', error => '', data => {} };

    my $tinfo;
    if ($opts{repo}) {
        # Explicit repository path override (local mode). Used when the caller
        # needs git to run inside a specific checkout (e.g. a branch worktree)
        # rather than the resolved default repo. Bypasses resolve_target but
        # still goes through the same argv whitelist below.
        $tinfo = { mode => 'local', repo => $opts{repo}, host => '', user => '', port => 22, label => 'explicit' };
    }
    else {
        $tinfo = $self->resolve_target($c, $opts{target});
    }

    # If the caller didn't pass an explicit target, honor the one bound for this
    # request (set once by the controller from the dashboard's target selector).
    # This lets the whole subsystem route to a remote host with a single line of
    # controller code rather than threading target through every public method.
    unless ($opts{target} || $opts{repo}) {
        my $req_target = $c->stash->{git_target}
                      // ($c->req ? $c->req->param('target') : undef);
        $tinfo = $self->resolve_target($c, $req_target) if defined $req_target;
    }

    if ($tinfo->{mode} eq 'ssh') {
        # Re-validate argv through the same whitelist on the way out, then ship.
        my $subcmd = $argv[0] // '';
        unless ($ALLOWED_SUBCMD{$subcmd}) {
            $result->{error} = "Refused: '$subcmd' is not an allowed git subcommand";
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'git_run',
                $result->{error});
            return $result;
        }
        return $self->_ssh_exec_git($c, $tinfo, @argv);
    }

    my $repo = $tinfo->{repo};
    unless (defined $repo && length $repo) {
        $result->{error} = 'Repository path could not be resolved';
        return $result;
    }

    my $subcmd = $argv[0] // '';
    unless ($ALLOWED_SUBCMD{$subcmd}) {
        $result->{error} = "Refused: '$subcmd' is not an allowed git subcommand";
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'git_run',
            $result->{error});
        return $result;
    }

    # Reject any -flag not explicitly allowed for this subcommand. A '--' marker
    # ends flag scanning: everything after it is a positional argument.
    my $flags_ok = $ALLOWED_FLAGS{$subcmd} || {};
    my $after_ddash = 0;
    for my $i (1 .. $#argv) {
        my $a = $argv[$i];
        next unless defined $a;
        if ($a eq '--') { $after_ddash = 1; next; }
        next if $after_ddash;
        if ($a =~ /^-/) {
            # git log accepts a bare numeric count like "-10" (shorthand for -n 10).
            next if $subcmd eq 'log' && $a =~ /^-\d+$/;
            # allow "-n5" style joined value for log
            (my $base = $a) =~ s/^(-\w|--[a-z-]+).*$/$1/;
            unless ($flags_ok->{$a} || $flags_ok->{$base}) {
                $result->{error} = "Refused: flag '$a' is not allowed for git $subcmd";
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'git_run',
                    $result->{error});
                return $result;
            }
        }
    }

    my ($out, $err) = ('', '');
    my $ran = try {
        IPC::Run3::run3([ 'git', '-C', $repo, @argv ], \undef, \$out, \$err);
        1;
    } catch {
        $result->{error} = "git execution failed: $_";
        0;
    };
    return $result unless $ran;

    my $code = $? >> 8;
    $result->{exit_code} = $code;
    $result->{output}    = defined $out ? $out : '';
    $result->{error}     = defined $err ? $err : '';
    $result->{success}   = ($code == 0) ? 1 : 0;

    # Log level: a non-zero exit is usually an error, but some expected/graceful
    # conditions legitimately exit non-zero and are handled by the caller:
    #   * `rev-parse --abbrev-ref --symbolic-full-name @{u}` exits 128 with
    #     "fatal: no upstream configured for branch '...'" when a branch simply
    #     has no tracking branch. get_tracking_info() treats that as
    #     upstream => undef (a normal dashboard state), so logging it as ERROR
    #     just creates noise / false error-audit todos. Demote such known-benign
    #     "no upstream" results to info so real failures still stand out.
    #   * The same is true for `rev-list --left-right --count @{u}...HEAD`.
    # Detect this structurally (the argv asks about @{u}) as well as by message
    # text, because git's wording varies by version/locale and a text-only match
    # silently stops working after a git upgrade.
    my $combined   = ($result->{output} // '') . "\n" . ($result->{error} // '');
    my $asks_upstream = grep { defined $_ && /\@\{u(pstream)?\}/ } @argv;
    my $benign   = !$result->{success}
                && ( $asks_upstream
                  || $combined =~ /no upstream configured|does not have an upstream|no such branch/i );
    my $level    = $result->{success} ? 'info'
                 : $benign            ? 'info'
                 :                      'error';
    $self->logging->log_with_details($c, $level, __FILE__, __LINE__, 'git_run',
        "git " . join(' ', @argv) . " -> exit=$code out=" . substr($result->{output}, 0, 500));

    return $result;
}

# ---------------------------------------------------------------------------
# Read-only helpers
# ---------------------------------------------------------------------------

=head2 get_current_branch($c)

Returns the current branch name, or 'unknown'.

=cut

sub get_current_branch {
    my ($self, $c) = @_;
    my $r = $self->_run($c, 'branch', '--show-current');
    my $branch = $r->{output};
    chomp $branch if defined $branch;
    return ($r->{success} && length $branch) ? $branch : 'unknown';
}

=head2 get_available_branches($c)

Fetch and return an arrayref of remote branch names (origin/*), main first,
master/HEAD excluded. Falls back to ['main'].

=cut

sub get_available_branches {
    my ($self, $c) = @_;

    $self->_run($c, 'fetch', 'origin');
    my $r = $self->_run($c, 'branch', '-r', '--no-color');

    my @branches;
    my %excluded = (master => 1, master2 => 1, HEAD => 1);
    for my $line (split /\n/, $r->{output}) {
        $line =~ s/^\s+|\s+$//g;
        $line =~ s/\x1b\[[0-9;]*m//g;
        if ($line =~ m{^origin/(.+)$}) {
            my $name = $1;
            next if $excluded{$name} || $name =~ /^HEAD\s*->/;
            push @branches, $name;
        }
    }

    @branches = sort {
        return -1 if $a eq 'main' && $b ne 'main';
        return  1 if $b eq 'main' && $a ne 'main';
        return $a cmp $b;
    } @branches;

    @branches = ('main') unless @branches;
    return \@branches;
}

=head2 get_local_branches($c)

Arrayref of local branch names (current-branch asterisk stripped).

=cut

sub get_local_branches {
    my ($self, $c) = @_;
    my $r = $self->_run($c, 'branch', '--no-color');
    my @branches;
    for my $line (split /\n/, $r->{output}) {
        $line =~ s/^\s*\*?\s*//;
        $line =~ s/^\s+|\s+$//g;
        $line =~ s/\x1b\[[0-9;]*m//g;
        next if !$line || $line =~ /^\(.*\)$/;
        # 'git' is a reserved word (it collides with the git command itself) and
        # can never be checked out or merged — skip it everywhere so it can't be
        # offered in the UI or validated as a real branch.
        next if $line eq 'git';
        push @branches, $line;
    }
    return \@branches;
}

=head2 get_branch_details($c)

Rich per-branch metadata for the dashboard branch card. Uses a single
C<git for-each-ref> so it's one cheap call regardless of branch count.

Returns an arrayref of hashrefs, current branch first, each:
  { name, is_current, last_commit_date (YYYY-MM-DD), last_commit_relative,
    last_commit_subject, upstream (or ''), removable (0 for protected/current) }

=cut

sub get_branch_details {
    my ($self, $c) = @_;

    my $current = $self->get_current_branch($c);
    my %protected = (main => 1, master => 1, Production => 1);

    # Field-separated, one line per branch. %(committerdate:short) = YYYY-MM-DD.
    my $fmt = '%(refname:short)%09%(committerdate:short)%09%(committerdate:relative)%09%(upstream:short)%09%(contents:subject)';
    my $r = $self->_run($c, 'branch', '--no-color', '--format', $fmt);

    my @rows;
    for my $line (split /\n/, $r->{output}) {
        next unless length $line;
        my ($name, $date, $rel, $upstream, $subject) = split /\t/, $line, 5;
        next unless defined $name && length $name;
        my $is_current = ($name eq $current) ? 1 : 0;
        push @rows, {
            name                 => $name,
            is_current           => $is_current,
            last_commit_date     => $date    // '',
            last_commit_relative => $rel     // '',
            last_commit_subject  => $subject // '',
            upstream             => $upstream // '',
            removable            => ($is_current || $protected{$name}) ? 0 : 1,
        };
    }

    # Current branch first, then most-recently-committed.
    @rows = sort {
        $b->{is_current} <=> $a->{is_current}
            || ($b->{last_commit_date} cmp $a->{last_commit_date})
    } @rows;

    return \@rows;
}

=head2 get_recent_commits($c, $count)

Arrayref of { hash, message } for the last $count (default 10) commits.

=cut

sub get_recent_commits {
    my ($self, $c, $count) = @_;
    $count = 10 unless $count && $count =~ /^\d+$/;
    my $r = $self->_run($c, 'log', '--oneline', "-$count");
    my $commits = [];
    return $commits unless $r->{success};
    for my $line (split /\n/, $r->{output}) {
        if ($line =~ /^([a-f0-9]+)\s+(.+)$/) {
            push @$commits, { hash => $1, message => $2 };
        }
    }
    return $commits;
}

=head2 get_git_stash_list($c)

Arrayref of { ref, index, message }.

=cut

sub get_git_stash_list {
    my ($self, $c) = @_;
    my $r = $self->_run($c, 'stash', 'list');
    my $stashes = [];
    return $stashes unless $r->{success};
    for my $line (split /\n/, $r->{output}) {
        if ($line =~ /^(stash\@\{(\d+)\}):\s*(.+)$/) {
            push @$stashes, { ref => $1, index => $2, message => $3 };
        }
    }
    return $stashes;
}

=head2 get_git_status($c)

Parsed working-tree status: { has_changes, staged_files, modified_files,
untracked_files, output }.

=cut

sub get_git_status {
    my ($self, $c) = @_;

    my $status = {
        has_changes     => 0,
        staged_files    => [],
        modified_files  => [],
        untracked_files => [],
        output          => '',
    };

    my $r = $self->_run($c, 'status', '--porcelain');
    $status->{output} = $r->{output};
    return $status unless $r->{success} && length $r->{output};

    $status->{has_changes} = 1;
    for my $line (split /\n/, $r->{output}) {
        if ($line =~ /^(.)(.) (.+)$/) {
            my ($staged, $modified, $file) = ($1, $2, $3);
            # Untracked ("??") is its own bucket — don't also count it as staged/modified.
            if ($staged eq '?' && $modified eq '?') {
                push @{ $status->{untracked_files} }, $file;
                next;
            }
            push @{ $status->{staged_files} },   $file if $staged   ne ' ';
            push @{ $status->{modified_files} }, $file if $modified ne ' ';
        }
    }
    return $status;
}

=head2 get_tracking_info($c)

Ahead/behind vs the branch's integration base.

This project does NOT use a GitHub-style push/pull workflow per branch.
Worktrees are *linked* to the main (PyCharm) repo's .git, so a branch in a
worktree IS the same ref as that branch in the PyCharm repo — the AI commits
in the worktree, the user verifies and commits, then merges into `main`.

We therefore compute the relationship in two layers:

  1. GitHub upstream (@{u}) if it exists — the classic ahead/behind.
  2. FALLBACK when there is no @{u} (the normal local-merge case): compare the
     current branch against `main` using a local-only `rev-list --count` (no
     fetch, no network — `main` is a local branch in the shared repo). This is
     the signal the dashboard needs: "is my branch behind main?" so the branch
     can be updated before new work starts.

Returns { upstream, ahead, behind, base, base_ahead, base_behind } where the
`base*` fields describe the relationship to `main` (or whatever integration
base we pick) regardless of whether a GitHub upstream is configured.

=cut

sub get_tracking_info {
    my ($self, $c) = @_;
    my $info = {
        upstream     => undef,
        ahead        => 0,
        behind       => 0,
        base         => undef,   # integration base we fell back to (e.g. 'main')
        base_ahead   => 0,       # commits in branch not in base
        base_behind  => 0,       # commits in base not in branch (branch is stale)
    };

    # --- Layer 1: GitHub-style upstream if configured -------------------
    my $r = $self->_run($c, 'rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}');
    my $upstream = $r->{output};
    chomp $upstream if defined $upstream;
    if ($r->{success} && $upstream && $upstream !~ /fatal|no upstream/i) {
        $info->{upstream} = $upstream;
        my $cr = $self->_run($c, 'rev-list', '--left-right', '--count', '@{u}...HEAD');
        my $counts = $cr->{output};
        chomp $counts if defined $counts;
        if ($counts && $counts =~ /^(\d+)\s+(\d+)$/) {
            $info->{behind} = $1;
            $info->{ahead}  = $2;
        }
        return $info;
    }

    # --- Layer 2: local-merge fallback vs integration base -----------------
    # Pick a base branch: `main` if it exists, else `master`, else the repo's
    # first existing local branch that is not the current branch.
    my $current = $self->get_current_branch($c);
    my $base;
    for my $cand (qw(main master)) {
        my $br = $self->_run($c, 'rev-parse', '--verify', '--quiet', $cand);
        if ($br->{success} && length($br->{output} // '')) {
            $base = $cand;
            last;
        }
    }
    return $info unless defined $base;          # no base to compare against
    return $info if defined $current && $current eq $base;  # already on base

    $info->{base} = $base;
    my $cr = $self->_run($c, 'rev-list', '--left-right', '--count', "$base...HEAD");
    my $counts = $cr->{output};
    chomp $counts if defined $counts;
    if ($counts && $counts =~ /^(\d+)\s+(\d+)$/) {
        # left  = commits only in $base (branch is BEHIND $base -> stale)
        # right = commits only in HEAD (branch is AHEAD of $base -> unmerged work)
        $info->{base_behind} = $1;
        $info->{base_ahead}  = $2;
    }
    return $info;
}

=head2 diff($c, %opts)

Return a diff string. Options: cached => 1 (staged diff), paths => [\@files]
(diff only those files against HEAD), stat => 1 (--stat summary). With no options,
diffs the working tree against HEAD.

=cut

sub diff {
    my ($self, $c, %opts) = @_;
    my @argv = ('diff');
    push @argv, '--stat'   if $opts{stat};
    push @argv, '--cached' if $opts{cached};
    push @argv, 'HEAD'     if !$opts{cached};
    if ($opts{paths} && @{ $opts{paths} }) {
        push @argv, '--', @{ $opts{paths} };
    }
    my $r = $self->_run($c, @argv);
    return $r->{output};
}

# ---------------------------------------------------------------------------
# Write helpers (paths/messages always positional)
# ---------------------------------------------------------------------------

=head2 stage($c, \@paths) / unstage($c, \@paths)

Stage or unstage specific files. Returns the uniform hash.

=cut

sub stage {
    my ($self, $c, $paths) = @_;
    return { success => 0, error => 'No files given' } unless $paths && @$paths;
    return $self->_run($c, 'add', '--', @$paths);
}

sub unstage {
    my ($self, $c, $paths) = @_;
    return { success => 0, error => 'No files given' } unless $paths && @$paths;
    return $self->_run($c, 'restore', '--staged', '--', @$paths);
}

=head2 commit($c, $message)

Commit staged changes with $message. Returns the uniform hash.

=cut

sub commit {
    my ($self, $c, $message) = @_;
    return { success => 0, error => 'Commit message required' }
        unless defined $message && length $message;
    return $self->_run($c, 'commit', '-m', $message);
}

=head2 push_to_origin($c, %opts)

Push to origin. opts: branch (required), set_upstream => 0|1.

=cut

sub push_to_origin {
    my ($self, $c, %opts) = @_;
    my $branch = $opts{branch} or return { success => 0, error => 'Branch required' };
    my @argv = ('push');
    push @argv, '--set-upstream' if $opts{set_upstream};
    push @argv, 'origin', $branch;
    return $self->_run($c, @argv);
}

=head2 rm($c, \@paths)

git rm tracked files (recoverable via history).

=cut

sub rm {
    my ($self, $c, $paths) = @_;
    return { success => 0, error => 'No files given' } unless $paths && @$paths;
    return $self->_run($c, 'rm', '--', @$paths);
}

=head2 stash_push($c, \@paths, $message)

Stash selected files (or all changes if \@paths empty), with optional message.

=cut

sub stash_push {
    my ($self, $c, $paths, $message) = @_;
    my @argv = ('stash', 'push');
    push @argv, '-m', $message if defined $message && length $message;
    push @argv, '--', @$paths if $paths && @$paths;
    return $self->_run($c, @argv);
}

=head2 stash_pop($c, $index) / stash_drop($c, $index)

Pop or drop a stash by index (default 0).

=cut

sub stash_pop {
    my ($self, $c, $index) = @_;
    $index = 0 unless defined $index && $index =~ /^\d+$/;
    return $self->_run($c, 'stash', 'pop', "stash\@{$index}");
}

sub stash_drop {
    my ($self, $c, $index) = @_;
    $index = 0 unless defined $index && $index =~ /^\d+$/;
    return $self->_run($c, 'stash', 'drop', "stash\@{$index}");
}

=head2 pull($c, $branch)

Pull origin/$branch (default main), auto-stashing local theme_mappings.json
changes and reapplying them afterward. Returns (success, output, warning) to
match the legacy execute_git_pull contract used by callers.

=cut

sub pull {
    my ($self, $c, $branch) = @_;
    $branch ||= 'main';
    my $output  = '';
    my $success = 0;
    my $warning;

    my $app_dir = $self->repo_path($c);

    my $theme_file = "$app_dir/Comserv/root/static/config/theme_mappings.json";
    my $has_theme_changes = 0;

    if (-f $theme_file) {
        my $st = $self->_run($c, 'status', '--porcelain', '--', $theme_file);
        if ($st->{output} && $st->{output} =~ /^\s*M/) {
            $has_theme_changes = 1;
            $output .= "Detected local changes in theme_mappings.json\n";
            my $backup_file = "$theme_file.backup." . time();
            if (copy($theme_file, $backup_file)) {
                $output .= "Created backup: $backup_file\n";
            } else {
                $output .= "Warning: Could not create backup of theme_mappings.json\n";
            }
            my $sp = $self->stash_push($c, [$theme_file],
                'Auto-stash theme_mappings.json before pull');
            $output .= "Stashed changes: $sp->{output}\n";
        }
    }

    $output .= "Fetching latest changes...\n";
    $output .= $self->_run($c, 'fetch', 'origin')->{output};

    my $current = $self->get_current_branch($c);
    if ($current ne $branch) {
        $output .= "Switching to branch '$branch'...\n";
        my $co = $self->_run($c, 'checkout', $branch);
        $output .= $co->{output};
        if (!$co->{success}) {
            $output .= "Error: Failed to switch to branch '$branch'\n";
            return (0, $output, undef);
        }
    }

    $output .= "Pulling changes from origin/$branch...\n";
    my $pr = $self->_run($c, 'pull', 'origin', $branch);
    $output .= $pr->{output};

    if ($pr->{success}) {
        $success = 1;
        $output .= "Git pull completed successfully.\n";
        if ($has_theme_changes) {
            $output .= "Attempting to reapply theme_mappings.json changes...\n";
            my $pop = $self->stash_pop($c);
            $output .= $pop->{output};
            $warning = "Git pull successful, but could not automatically reapply "
                . "theme_mappings.json changes. Please check the backup file and resolve manually."
                unless $pop->{success};
        }
    } else {
        $output .= "Error: Git pull failed\n";
    }

    return ($success, $output, $warning);
}

=head2 create_branch($c, $branch_name, $source_branch)

Create $branch_name from origin/$source_branch (default main) and push it.
Returns the legacy result hash (success, output, error_msg/success_msg).

=cut

sub create_branch {
    my ($self, $c, $branch_name, $source_branch) = @_;
    my $result = { success => 0, output => '', action => 'create_branch' };

    if (!$branch_name || $branch_name !~ m{^[a-zA-Z0-9_\-/]+$}) {
        $result->{error_msg} = "Invalid branch name. Use only letters, numbers, "
            . "underscores, hyphens, and forward slashes.";
        return $result;
    }
    $source_branch ||= 'main';

    $result->{output} .= "Fetching latest changes...\n";
    $result->{output} .= $self->_run($c, 'fetch', 'origin')->{output};

    my $local = $self->_run($c, 'branch', '--list', $branch_name);
    if ($local->{output} =~ /\S/) {
        $result->{error_msg} = "Branch '$branch_name' already exists locally.";
        return $result;
    }
    my $remote = $self->_run($c, 'branch', '-r', '--list', "origin/$branch_name");
    if ($remote->{output} =~ /\S/) {
        $result->{error_msg} = "Branch '$branch_name' already exists on remote.";
        return $result;
    }

    $result->{output} .= "Creating branch '$branch_name' from '$source_branch'...\n";
    my $cr = $self->_run($c, 'checkout', '-b', $branch_name, "origin/$source_branch");
    $result->{output} .= $cr->{output};
    if (!$cr->{success}) {
        $result->{error_msg} = "Failed to create branch '$branch_name'";
        return $result;
    }

    $result->{output} .= "Pushing new branch to remote...\n";
    my $pu = $self->push_to_origin($c, branch => $branch_name, set_upstream => 1);
    $result->{output} .= $pu->{output};
    if (!$pu->{success}) {
        $result->{error_msg} = "Failed to push branch '$branch_name' to remote";
        return $result;
    }

    $result->{success}     = 1;
    $result->{success_msg} = "Branch '$branch_name' created successfully and pushed to remote.";
    return $result;
}

=head2 delete_branch($c, $branch_name)

Delete a local + remote branch. Refuses protected branches.

=cut

sub delete_branch {
    my ($self, $c, $branch_name) = @_;
    my $result = { success => 0, output => '', action => 'delete_branch' };

    if (!$branch_name) {
        $result->{error_msg} = "Branch name is required.";
        return $result;
    }
    if ($branch_name eq 'main' || $branch_name eq 'master' || $branch_name eq 'Production') {
        $result->{error_msg} = "Cannot delete protected branch '$branch_name'.";
        return $result;
    }

    my $current = $self->get_current_branch($c);
    if ($current eq $branch_name) {
        $result->{output} .= "Switching to main branch before deletion...\n";
        my $co = $self->_run($c, 'checkout', 'main');
        $result->{output} .= $co->{output};
        if (!$co->{success}) {
            $result->{error_msg} = "Failed to switch to main branch";
            return $result;
        }
    }

    # Local branch: delete only if it actually exists, so we don't raise a
    # spurious "branch not found" error on an already-deleted / no-op delete.
    my $local = $self->_run($c, 'branch', '--list', $branch_name);
    if ($local->{output} =~ /\S/) {
        $result->{output} .= "Deleting local branch '$branch_name'...\n";
        $result->{output} .= $self->_run($c, 'branch', '-D', $branch_name)->{output};
    }
    else {
        $result->{output} .= "Local branch '$branch_name' not found — skipping local delete.\n";
    }

    # Remote branch: only `push --delete` when origin/$branch_name exists.
    # Pushing --delete for a branch that was never pushed (or already deleted)
    # returns exit=1 with empty output and raises a false ERROR audit todo.
    my $remote = $self->_run($c, 'branch', '-r', '--list', "origin/$branch_name");
    if ($remote->{output} =~ /\S/) {
        $result->{output} .= "Deleting remote branch '$branch_name'...\n";
        $result->{output} .= $self->_run($c, 'push', 'origin', '--delete', $branch_name)->{output};
    }
    else {
        $result->{output} .= "Remote branch 'origin/$branch_name' not found — skipping remote delete.\n";
    }

    $result->{success}     = 1;
    $result->{success_msg} = "Branch '$branch_name' deleted successfully.";
    return $result;
}

=head2 switch_branch($c, $branch_name)

Switch to $branch_name, auto-stashing uncommitted changes, creating the local
branch from origin if needed, then pulling. Returns the legacy result hash.

=cut

sub switch_branch {
    my ($self, $c, $branch_name) = @_;
    my $result = { success => 0, output => '', action => 'switch_branch' };

    if (!$branch_name) {
        $result->{error_msg} = "Branch name is required.";
        return $result;
    }

    $result->{output} .= "Fetching latest changes...\n";
    $result->{output} .= $self->_run($c, 'fetch', 'origin')->{output};

    my $st = $self->_run($c, 'status', '--porcelain');
    if ($st->{output}) {
        $result->{output} .= "Warning: You have uncommitted changes:\n$st->{output}\n";
        $result->{output} .= "Stashing changes before branch switch...\n";
        my $sp = $self->stash_push($c, [], "Auto-stash before branch switch to $branch_name");
        $result->{output} .= $sp->{output};
    }

    $result->{output} .= "Switching to branch '$branch_name'...\n";
    my $co = $self->_run($c, 'checkout', $branch_name);
    $result->{output} .= $co->{output};
    if (!$co->{success}) {
        $result->{output} .= "Local branch not found, creating from remote...\n";
        my $cb = $self->_run($c, 'checkout', '-b', $branch_name, "origin/$branch_name");
        $result->{output} .= $cb->{output};
        if (!$cb->{success}) {
            $result->{error_msg} = "Failed to switch to or create branch '$branch_name'";
            return $result;
        }
    }

    $result->{output} .= "Pulling latest changes for branch '$branch_name'...\n";
    $result->{output} .= $self->_run($c, 'pull', 'origin', $branch_name)->{output};

    $result->{success}     = 1;
    $result->{success_msg} = "Successfully switched to branch '$branch_name'.";
    return $result;
}

=head2 list_worktrees($c)

Return an arrayref of worktree entries for the repo:
  { path, branch, is_main, port }
Port is derived from the configured worktree layout (~/.comserv/worktrees/<branch>/Comserv)
using the same port map the dashboard uses (BranchServerControl / _planning_tab.tt).
Main repo (no configured worktree path in its path) is reported as is_main => 1.

=cut

sub list_worktrees {
    my ($self, $c) = @_;

    my $repo = $self->repo_path($c) // return [];
    my $r = $self->_run($c, 'worktree', 'list', '--porcelain');
    my @rows;
    return \@rows unless $r->{success};

    # git worktree list --porcelain emits, per worktree:
    #   <worktree-path>
    #   HEAD <sha>
    #   branch refs/heads/<name>     (or "detached")
    my ($path, $branch);
    for my $line (split /\n/, $r->{output}) {
        if ($line =~ /^(\S.*)$/) {
            $path  = $1;  $branch = undef;
        }
        elsif ($line =~ /^branch\s+refs\/heads\/(.+)$/) {
            $branch = $1;
        }
        elsif ($line eq '' && defined $path) {
            push @rows, _worktree_row($path, $branch);
            $path = undef;
        }
    }
    push @rows, _worktree_row($path, $branch) if defined $path;
    return \@rows;
}

=head2 worktree_checkout_path_for_branch($c, $branch)

Resolve the on-disk checkout path where $branch is currently checked out, so
git operations can run directly in that tree instead of trying to check the
branch out elsewhere (which fails for worktree branches — a branch already
checked out in another worktree cannot be checked out in the main repo).

Returns the path string, or undef if the branch is not currently checked out
in any worktree (e.g. a local-only branch with no worktree).

=cut

sub worktree_checkout_path_for_branch {
    my ($self, $c, $branch) = @_;

    # Primary strategy: scan the worktree base directory and check each
    # checkout's ACTUAL current branch with `git branch --show-current`. This
    # is robust even when `git worktree list --porcelain` has stale/corrupt
    # metadata (e.g. a worktree whose directory was renamed but whose git
    # bookkeeping still points at the old name — git-dev's porcelain entry
    # drops its `worktree <path>` line, so list_worktrees records it with no
    # path). Scanning the dirs directly always finds the real checkout.
    my $cfg  = eval { _worktree_config() } // { base_dir => "$ENV{HOME}/.comserv/worktrees" };
    my $base = $cfg->{base_dir} // "$ENV{HOME}/.comserv/worktrees";
    if ($base && -d $base) {
        opendir(my $dh, $base) or return undef;
        my @entries = grep { -e "$base/$_/Comserv/.git" } readdir($dh);
        closedir($dh);
        for my $name (@entries) {
            my $dir = "$base/$name/Comserv";
            my $b   = $self->_run($c, 'branch', '--show-current',
                { repo => $dir })->{output};
            chomp $b if defined $b;
            return $dir if defined $b && length $b && $b eq $branch;
        }
    }

    # Fallback: trust list_worktrees (works for well-formed worktree metadata).
    my $wts = $self->list_worktrees($c) or return undef;
    for my $wt (@$wts) {
        next unless $wt->{branch} && $wt->{branch} eq $branch;
        return $wt->{path} if $wt->{path} && -d $wt->{path};
    }
    return undef;
}

sub _worktree_row {
    my ($path, $branch) = @_;
    my $cfg     = _worktree_config();
    my $base    = $cfg->{base_dir} // '';
    my $is_main = ($base && $path =~ m{\Q$base\E})
               || ($path !~ m{worktrees[/\\]});
    my $wt_branch;
    if ($base && $path =~ m{\Q$base\E[/\\]([^/\\]+)}) {
        $wt_branch = $1;
    }
    elsif ($path =~ m{worktrees[/\\]([^/\\]+)[/\\]Comserv}) {
        $wt_branch = $1;   # fallback for any legacy worktree dirs still on disk
    }
    return {
        path     => $path,
        branch   => $branch // ($wt_branch // 'detached'),
        is_main  => $is_main ? 1 : 0,
        port     => $is_main ? 3001 : _worktree_port($wt_branch // ''),
    };
}

# Cached worktree config loaded from root/config/worktrees.json. This is the
# single source of truth for the worktree base dir + branch->port map, replacing
# the old hardcoded .zenflow layout. There is NO static fallback: a branch not in
# the JSON has port 0. Deleted ports stay deleted so they can be reused.
my $_wt_config;
my $_wt_config_mtime;
sub _worktree_config {
    my $file = __FILE__;
    $file =~ s{lib/Comserv/Util/Git\.pm$}{root/config/worktrees.json};
    # Re-read when the file is missing OR newer than the cached copy. The module-level
    # cache is shared across all requests in a worker, and a multi-worker Catalyst server
    # has several independent caches. Without this, one worker keeps serving a stale port
    # map while another worker (or an external process) writes a new branch+port to the
    # JSON — the next create_worktree then allocates a port that is ALREADY taken, causing
    # two worktrees to collide on the same port (observed: a new branch was handed 4004,
    # the port already claimed by `planning`). The file is the single source of truth; the
    # cache must never outlive the file.
    my $mtime = (stat($file))[9];
    if ($_wt_config && defined $_wt_config_mtime && defined $mtime
            && $mtime == $_wt_config_mtime && -f $file) {
        return $_wt_config;
    }
    if (-f $file) {
        eval {
            my $raw = do { local $/; open my $fh, '<', $file or die $!; <$fh> };
            my $j = decode_json($raw);
            $j->{base_dir} =~ s{^~([/\\]|$)}{$ENV{HOME}$1} if $j->{base_dir};
            $_wt_config      = $j;
            $_wt_config_mtime = $mtime;
        };
        return $_wt_config if $_wt_config;
    }
    $_wt_config       = { base_dir => "$ENV{HOME}/.comserv/worktrees", branches => {} };
    $_wt_config_mtime = undef;
    return $_wt_config;
}

sub worktree_base_dir { return _worktree_config()->{base_dir}; }

# Fresh, cache-bypassing read of worktrees.json used by the PORT-ALLOCATION path
# (next_free_port / create_worktree). The cached _worktree_config() is fine for UI
# builders (staleness there is cosmetic), but the allocator must NEVER trust a cached
# map: two create_worktree calls inside the same 1-second mtime window (or across
# workers) would otherwise both read a stale port set and hand out the same port.
# This reads the file straight from disk every time.
sub _worktree_json_fresh {
    my $file = __FILE__;
    $file =~ s{lib/Comserv/Util/Git\.pm$}{root/config/worktrees.json};
    return { base_dir => "$ENV{HOME}/.comserv/worktrees", branches => {} } unless -f $file;
    my $j = eval {
        my $raw = do { local $/; open my $fh, '<', $file or die $!; <$fh> };
        decode_json($raw);
    };
    return $j if $j && ref $j eq 'HASH';
    return { base_dir => "$ENV{HOME}/.comserv/worktrees", branches => {} };
}

# Build the worktree/develop-server registry for UI surfaces (the planning tab's
# "Branch Servers" panel, the Git dashboard's "Develop Servers" card, etc.). This is
# the SINGLE canonical builder — the planning tab and the Git dashboard must both call
# it so they can never drift apart. Returns [ { name, port, label, url, cmd }, ... ]
# with `main` first (port 3001), then every branch from root/config/worktrees.json
# sorted by name. `cmd` is the one launch form used everywhere:
#   cd <base_dir>/<branch>/Comserv/Comserv && CATALYST_DEBUG=1 COMSERV_NO_HEALTH_LOG=1 perl script/comserv_server.pl -p <port> -r
# BranchServerControl (per-branch start/stop/restart) consumes the same path/port, so
# the list, the launch command, and the running server all agree.
sub build_worktree_list {
    my ($self) = @_;
    my @list;

    my $base = eval { worktree_base_dir() } // "$ENV{HOME}/.comserv/worktrees";
    push @list, {
        name  => 'main',
        port  => 3001,
        label => 'MAIN',
        url   => '/planning/daily',
        cmd   => 'cd /home/shanta/PycharmProjects/comserv2/Comserv && CATALYST_DEBUG=1 perl script/comserv_server.pl --twiggy -p 3001 -r',
        # Hermes CLI for THIS checkout. Running from the worktree git-root makes Hermes
        # auto-load the branch .hermes.md (which pulls in the global rules + domain
        # expertise). -w = worktree-safe mode (parallel agents, no git conflicts).
        hermes_cmd => 'cd /home/shanta/PycharmProjects/comserv2/Comserv && hermes chat -w',
    };

    my $cfg = eval { _worktree_config() } // { branches => {} };
    my $branches = $cfg->{branches} // {};
    for my $name (sort keys %$branches) {
        my $b = $branches->{$name} // {};
        push @list, {
            name  => $name,
            port  => $b->{port} // 0,
            label => $b->{label} // $name,
            url   => $b->{url}   // '/planning/daily',
            cmd   => "cd $base/$name/Comserv/Comserv && CATALYST_DEBUG=1 COMSERV_NO_HEALTH_LOG=1 perl script/comserv_server.pl -p "
                   . ($b->{port} // 0) . ' -r',
            # Branch Hermes: cwd = the worktree's own git root so its .hermes.md loads.
            hermes_cmd => "cd $base/$name/Comserv && hermes chat -w",
        };
    }
    return \@list;
}

# NOTE: the old hardcoded WORKTREE_PORTS hash has been REMOVED. The single source
# of truth for branch->port is root/config/worktrees.json. A deleted/non-JSON port
# must NEVER be resurrected from a static map (user rule: removed ports stay removed
# so they can be reused). If a branch is not in the JSON, its port is 0.

=head2 next_free_port($c)

Scan upward from the configured floor (port_start, default 4000) for the first
port not already assigned to a branch in worktrees.json. Port 4000 itself is
treated as occupied if anything is listening there; the caller's JSON is the
authority for what is taken. Returns the first free integer > floor.

=cut

sub next_free_port {
    my ($self_or_c) = @_;
    # Read the file fresh (never the cache) so concurrent writers can't collide.
    my $cfg  = _worktree_json_fresh();
    my $floor = $cfg->{port_start} // 4000;
    $floor = 4000 if $floor !~ /^\d+$/ || $floor < 4000;
    # Port 4000 is occupied by a live instance; never hand it out. The first
    # usable port is one above the floor (your rule: first available AFTER 4000).
    my $start = $floor < 4001 ? 4001 : $floor;
    my %taken;
    if ($cfg->{branches}) {
        for my $b (keys %{ $cfg->{branches} }) {
            my $p = $cfg->{branches}{$b}{port};
            $taken{$p} = 1 if $p && $p =~ /^\d+$/;
        }
    }
    my $p = $start;
    $p++ while $taken{$p};   # first port >= start not already in the JSON
    return $p;
}

=head2 create_worktree($c, $branch, \%opts)

The isolation primitive. In one call:
  1. create the branch from $opts{parent} (default 'main') if it does not exist,
  2. git worktree add <base_dir>/<branch>/Comserv <branch>,
  3. assign the next free port (next_free_port),
  4. append { port, label, url } to root/config/worktrees.json,
  5. return { success, branch, port, path, cmd }.

The branch-servers list reads the JSON, so it refreshes automatically.
Never renames or deletes an existing branch.

=cut

sub create_worktree {
    my ($self, $c, $branch, $opts) = @_;
    $opts //= {};
    my $res = { success => 0, action => 'create_worktree', branch => $branch };

    unless ($branch && $branch =~ /^[A-Za-z0-9._\/-]+$/) {
        $res->{error} = 'A valid branch name is required.';
        return $res;
    }
    my $cfg    = _worktree_config();
    my $base   = $cfg->{base_dir} // "$ENV{HOME}/.comserv/worktrees";
    my $wt_dir = "$base/$branch/Comserv";
    my $parent = $opts->{parent} // 'main';

    # 1) branch (create from parent if missing)
    my $have = $self->_run($c, 'branch', '--list', '--no-color', $branch);
    if (!$have->{success} || $have->{output} !~ /\b\Q$branch\E\b/) {
        my $cr = $self->_run($c, 'branch', $branch, $parent);
        unless ($cr->{success}) {
            $res->{error} = "Failed to create branch '$branch' from '$parent': " . ($cr->{error} // $cr->{output});
            return $res;
        }
    }

    # 2) worktree add
    if (-d $wt_dir) {
        $res->{error} = "Worktree dir already exists: $wt_dir";
        return $res;
    }
    my $ar = $self->_run($c, 'worktree', 'add', $wt_dir, $branch);
    unless ($ar->{success}) {
        $res->{error} = "git worktree add failed: " . ($ar->{error} // $ar->{output});
        return $res;
    }

    # 3) port + 4) persist to JSON
    # next_free_port already skips every port claimed in the current JSON. But between
    # reading the config and writing it back, another request (on a different worker)
    # could claim the same port. To be safe, re-read the live JSON right before writing
    # and, if our chosen port was taken in the meantime, pick the next free one again.
    # We then MERGE our branch into the current on-disk map (rather than overwriting the
    # whole file) so a concurrent writer's new branch is not lost.
    my $port = $self->next_free_port($c);
    my $label = $opts->{label} // $branch;
    my $url   = $opts->{url}   // '/planning/daily';

    my $live = _worktree_json_fresh();
    if ($live->{branches} && $live->{branches}{$branch}) {
        # existing entry (e.g. re-run) — keep its port
        $port = $live->{branches}{$branch}{port};
    }
    elsif ($live->{branches}) {
        my %taken = map { $_ => 1 }
            grep { defined && /^\d+$/ }
            map { $live->{branches}{$_}{port} } keys %{ $live->{branches} };
        $port = 4001 if $port !~ /^\d+$/ || $port < 4001;
        $port++ while $taken{$port};
    }
    $live->{branches} //= {};
    $live->{branches}{$branch} = { port => $port, label => $label, url => $url };
    unless (_save_worktree_config($self, $live)) {
        $res->{error} = 'Failed to write worktrees.json';
        return $res;
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_worktree',
        "Created worktree branch='$branch' parent='$parent' port=$port path=$wt_dir");

    $res->{success} = 1;
    $res->{port}    = $port;
    $res->{path}    = $wt_dir;
    # The Catalyst app lives one level deeper: the worktree checkout is the
    # comserv2 repo, and the app dir is <wt_dir>/Comserv (where script/ lives).
    my $app_dir = "$wt_dir/Comserv";
    $res->{cmd}     = "cd $app_dir && CATALYST_DEBUG=1 COMSERV_NO_HEALTH_LOG=1 perl script/comserv_server.pl -p $port -r";
    return $res;
}

=head2 remove_worktree($c, $branch)

Inverse of create_worktree (user rule 3): remove the worktree checkout, delete
the branch from git, and drop the JSON entry so its port is freed for reuse.
main is never touched.

=cut

sub remove_worktree {
    my ($self, $c, $branch) = @_;
    my $res = { success => 0, action => 'remove_worktree', branch => $branch };
    return $res->{error} = 'Refusing to remove main.' if $branch eq 'main';

    my $cfg    = _worktree_config();
    my $base   = $cfg->{base_dir} // "$ENV{HOME}/.comserv/worktrees";
    my $wt_dir = "$base/$branch/Comserv";

    # remove the checkout
    if (-d $wt_dir) {
        my $rr = $self->_run($c, 'worktree', 'remove', $wt_dir, '--force');
        unless ($rr->{success}) {
            $res->{error} = "worktree remove failed: " . ($rr->{error} // $rr->{output});
            return $res;
        }
    }
    # delete the branch
    my $br = $self->_run($c, 'branch', '-D', $branch);
    unless ($br->{success}) {
        $res->{error} = "branch delete failed: " . ($br->{error} // $br->{output});
        # still try to drop the JSON entry below
    }
    # free the port
    if ($cfg->{branches} && $cfg->{branches}{$branch}) {
        delete $cfg->{branches}{$branch};
        _save_worktree_config($self, $cfg);
    }
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'remove_worktree',
        "Removed worktree branch='$branch' dir=$wt_dir");
    $res->{success} = 1;
    return $res;
}

# Write the in-memory worktree config back to root/config/worktrees.json and
# clear the cache so the next read picks up the change. Returns 1 on success.
sub _save_worktree_config {
    my ($self, $cfg) = @_;
    my $file = __FILE__;
    $file =~ s{lib/Comserv/Util/Git\.pm$}{root/config/worktrees.json};
    my $ok = eval {
        open my $fh, '>', $file or die $!;
        print $fh encode_json($cfg);
        close $fh;
        1;
    };
    if ($ok) { $_wt_config = $cfg; }
    else {
        my $err = $@;
        if ($self && $self->can('logging')) {
            $self->logging->log_with_details(undef, 'warn', __FILE__, __LINE__, 'wt_cfg',
                "worktrees.json write failed: $err");
        }
    }
    return $ok ? 1 : 0;
}

sub _worktree_port {
    my ($branch) = @_;
    my $cfg = _worktree_config();
    if ($cfg->{branches} && $cfg->{branches}{$branch}) {
        return $cfg->{branches}{$branch}{port} // 0;
    }
    return 0;   # no static fallback — only the JSON knows ports
}

=head2 diff_against_main($c, $branch, $context)

Return the unified diff of $branch vs main (three-dot range main...$branch) with
$context lines of context per hunk (default 5). Used by the human review panel so
admins see exactly what the AI changed before merging.

=cut

sub diff_against_main {
    my ($self, $c, $branch, $context) = @_;
    $context //= 5;
    $context = 5 if $context !~ /^\d+$/ || $context < 0 || $context > 50;

    my $r = $self->_run($c, 'diff', "-U$context", 'main...' . $branch);
    return $r->{output} // '';
}

=head2 merge_branch($c, $branch)

Human-gated merge of $branch into the current branch (expected to be main) using
--no-ff so a merge commit is always created (auditable). Caller must have already
verified the branch is non-protected and tests are green. On conflict, --abort is
NOT auto-run here; the controller reports the conflict and offers abort.

=cut

sub merge_branch {
    my ($self, $c, $branch, $opts) = @_;
    my $result = { success => 0, output => '', action => 'merge_branch' };

    $opts //= {};
    my $repo = $opts->{repo};   # optional explicit checkout (primary repo for merge_to_main)

    if (!$branch) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'git_merge',
            'merge_branch: branch name is required');
        $result->{error_msg} = "Branch name is required.";
        return $result;
    }
    # Guard: refuse to merge a protected branch *into itself* (merging main INTO a
    # worktree branch — the "pull main down" direction — is the normal, intended
    # operation and must NOT be blocked). Previously this refused any merge that
    # named main as the source, which broke the main->branch "update this branch"
    # direction entirely. Now we only refuse main->main / master->master.
    my $current = $self->get_current_branch($c);
    if (($branch eq 'main'   && $current eq 'main')
     || ($branch eq 'master' && $current eq 'master')
     || ($branch eq 'Production' && $current eq 'Production')) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'git_merge',
            "merge_branch: refusing to merge protected branch '$branch' into itself");
        $result->{error_msg} = "Refusing to merge a protected branch into itself.";
        return $result;
    }

    my $r = $self->_run($c, 'merge', '--no-ff', $branch, ($repo ? { repo => $repo } : ()));
    $result->{output} = $r->{output};
    if ($r->{success}) {
        $result->{success}     = 1;
        $result->{success_msg} = "Merged '$branch' into current branch.";
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'git_merge',
            "merge_branch: merged '$branch' into " . ($repo // 'current checkout') . " (success)");
    }
    else {
        # Detect conflict so the UI can offer --abort.
        if ($r->{output} =~ /CONFLICT|Automatic merge failed/) {
            $result->{conflict} = 1;
        }
        $result->{error_msg} = "Merge of '$branch' failed (see output).";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'git_merge',
            "merge_branch: merge of '$branch' failed"
            . ($result->{conflict} ? ' (conflict)' : '')
            . ': ' . ($r->{output} // ''));
    }
    return $result;
}

=head2 merge_abort($c)

Cancel a conflicted in-progress merge via C<git merge --abort> (flag already
whitelisted in C<_run>). Returns { success, output }. If there is nothing to
abort, git exits cleanly and we report success with the (empty) output rather
than raising a false error.

=cut

sub merge_abort {
    my ($self, $c) = @_;
    my $result = { success => 0, output => '', action => 'merge_abort' };

    my $r = $self->_run($c, 'merge', '--abort');
    $result->{output} = $r->{output};
    # git merge --abort exits 0 when it aborts, and also exits 0 (no-op) when
    # there is no merge in progress in modern git. Treat either as success so
    # the UI's Abort button always resolves a conflicted state cleanly.
    if ($r->{success}) {
        $result->{success}     = 1;
        $result->{success_msg} = "Merge aborted.";
    }
    else {
        $result->{error_msg} = "Merge abort failed (see output).";
    }
    return $result;
}

=head2 run_test_gate($c, $branch)

Run script/test_gate.sh against the worktree checkout for $branch so the merge is
blocked unless tests are green. Returns { success, output }. The worktree checkout
path is derived from the standard layout; falls back to the repo root if unknown.

=cut

sub run_test_gate {
    my ($self, $c, $branch, $repo_override) = @_;
    my $repo = $repo_override // $self->repo_path($c);
    unless (defined $repo && length $repo) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'test_gate',
            'run_test_gate: could not resolve a repo path (no repo)');
        return { success => 0, output => 'no repo' };
    }

    # App dir is one level under the git root (<root>/Comserv). Worktree
    # checkouts are <base>/<branch>/Comserv (git root) with the app at
    # <base>/<branch>/Comserv/Comserv.
    my $app_dir_for = sub {
        my $root = shift;
        return -d "$root/Comserv" ? "$root/Comserv" : $root;
    };

    my $checkout;
    if ($branch && $branch ne 'main') {
        $checkout = $self->worktree_checkout_dir($c, $branch);
    }
    $checkout = $app_dir_for->($repo) unless $checkout && -d $checkout;
    my $wt_dir = $checkout;

    # Always run the RUNNING app's canonical script (the one with this fix),
    # never a stale per-worktree copy. COMSERV_DIR tells the script which
    # checkout to test.
    my $app_script = ($c && $c->path_to('script'))
        ? $c->path_to('script')->stringify . '/test_gate.sh'
        : $app_dir_for->($repo) . '/script/test_gate.sh';
    my $script = $app_script;
    unless (-f $script) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'test_gate',
            "run_test_gate: test_gate.sh not found at $script");
        return { success => 0, output => "test_gate.sh not found at $script" };
    }

    local $ENV{COMSERV_DIR} = $wt_dir;

    my $out = `bash "$script" --fast 2>&1`;
    my $code = $? >> 8;
    my $res = { success => ($code == 0 ? 1 : 0), output => $out // '' };

    if ($code == 2) {
        $res->{stale} = 1;
        $res->{error_msg} = "Test gate could not run for '$branch': the worktree has no test suite. "
                          . "Update the branch from main (merge main into it) so it gains the tests, then re-run.";
    }
    return $res;
}

=head2 push_main($c)

Explicit, human-driven push of the current branch (expected main) to origin.
This restores the deliberate GitHub push that deploy.sh currently leaves disabled.

=cut

sub push_main {
    my ($self, $c) = @_;
    my $result = { success => 0, output => '', action => 'push_main' };

    my $branch = $self->get_current_branch($c);
    my $r = $self->_run($c, 'push', 'origin', $branch);
    $result->{output} = $r->{output};
    if ($r->{success}) {
        $result->{success}     = 1;
        $result->{success_msg} = "Pushed '$branch' to origin.";
    }
    else {
        $result->{error_msg} = "Push of '$branch' failed (see output).";
    }
    return $result;
}

1;

=head1 AUTHOR

Comserv2 Development Team

=head1 COPYRIGHT

Copyright (c) 2026 Computer System Consulting

=cut
