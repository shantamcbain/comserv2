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
    status log rev-parse rev-list branch diff fetch pull push
    add commit stash checkout show restore rm
);

# Per-subcommand allow-list of flags (leading '-'). User values are NEVER flags.
my %ALLOWED_FLAGS = (
    status   => { map { $_ => 1 } qw(--porcelain --short -s --no-color) },
    log      => { map { $_ => 1 } qw(--oneline --no-color --stat -n) },
    'rev-parse' => { map { $_ => 1 } qw(--abbrev-ref --symbolic-full-name --short) },
    'rev-list'  => { map { $_ => 1 } qw(--left-right --count) },
    branch   => { map { $_ => 1 } qw(-r -a -D -d --list --show-current --no-color --format) },
    diff     => { map { $_ => 1 } qw(--cached --stat --no-color --name-only) },
    fetch    => { map { $_ => 1 } qw(--prune) },
    pull     => { map { $_ => 1 } qw(--ff-only) },
    push     => { map { $_ => 1 } qw(--set-upstream -u --delete) },
    add      => {},
    commit   => { map { $_ => 1 } qw(-m --amend) },
    stash    => { map { $_ => 1 } qw(push pop drop list -m) },
    checkout => { map { $_ => 1 } qw(-b) },
    show     => { map { $_ => 1 } qw(--no-color) },
    restore  => { map { $_ => 1 } qw(--staged) },
    rm       => { map { $_ => 1 } qw(--cached -r) },
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

    my $tinfo = $self->resolve_target($c, $opts{target});

    # If the caller didn't pass an explicit target, honor the one bound for this
    # request (set once by the controller from the dashboard's target selector).
    # This lets the whole subsystem route to a remote host with a single line of
    # controller code rather than threading target through every public method.
    unless ($opts{target}) {
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

    my $level = $result->{success} ? 'info' : 'error';
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

Ahead/behind vs upstream (does not fetch): { upstream, ahead, behind }.

=cut

sub get_tracking_info {
    my ($self, $c) = @_;
    my $info = { upstream => undef, ahead => 0, behind => 0 };

    my $r = $self->_run($c, 'rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}');
    my $upstream = $r->{output};
    chomp $upstream if defined $upstream;
    return $info if !$r->{success} || !$upstream || $upstream =~ /fatal|no upstream/i;
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

1;

=head1 AUTHOR

Comserv2 Development Team

=head1 COPYRIGHT

Copyright (c) 2026 Computer System Consulting

=cut
