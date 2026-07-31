package Comserv::Controller::Admin::Git;

use Moose;
use namespace::autoclean -except => [qw(try catch finally)];  # keep Try::Tiny subs (Perl 5.40)
use Comserv::Util::Logging;
use Comserv::Util::AdminAuth;
use Comserv::Util::BackupManager;
use Try::Tiny;
use File::Temp;
use File::Copy;
use File::Path qw(make_path);
use Archive::Tar;
use POSIX qw(strftime);
use JSON;

BEGIN { extends 'Catalyst::Controller'; }

sub auto : Private {
    my ( $self, $c ) = @_;
    return 1;
}

=head1 NAME

Comserv::Controller::Admin::Git - Git operations controller

=head1 DESCRIPTION

Handles all Git-related administrative operations including pull, deployment, and branch management.
Separated from main Admin controller to reduce file size and improve maintainability.

=cut

# Returns an instance of the logging utility
sub logging {
    my ($self) = @_;
    return Comserv::Util::Logging->instance();
}

# Returns an instance of the admin auth utility
sub admin_auth {
    my ($self) = @_;
    return Comserv::Util::AdminAuth->new();
}

# Returns an instance of the backup manager utility
sub backup_manager {
    my ($self, $c) = @_;
    my $app_dir = $c ? $c->config->{home} : undef;
    return Comserv::Util::BackupManager->new($app_dir ? (app_dir => $app_dir) : ());
}

=head2 repo_path

Resolve the git repository root.

CRITICAL: this replaced 15 hardcoded C<chdir('/home/shanta/PycharmProjects/comserv2')> calls.
Those calls permanently changed the working directory of the persistent Twiggy/Starman worker,
which broke Plack::Middleware::Static / Catalyst::Plugin::Static::Simple. Static::Simple is
configured in Comserv.pm with C<< include_path => [ 'root' ] >> — a RELATIVE path. Once the worker
chdir'd to the repo root, 'root' resolved to C<comserv2/root> (which exists but contains only
ai/ and session/, no static/) instead of C<comserv2/Comserv/root>, so every /static/*.css and
/static/*.js 404'd for that worker until the app was manually restarted.

Never chdir in a request handler. Use C<git -C $repo> instead.

Resolution order: config C<git_repo_path> -> env COMSERV_GIT_REPO -> C<< $c->path_to('..') >>.

=cut

sub repo_path {
    my ($self, $c) = @_;

    my $path;
    $path = $c->config->{git_repo_path} if $c && $c->config->{git_repo_path};
    $path ||= $ENV{COMSERV_GIT_REPO};
    $path ||= $c->path_to('..')->stringify if $c;

    return $path;
}

=head2 _git

Run a git command against the repository WITHOUT changing the process working directory.

Takes the argument string exactly as it would appear after 'git' (e.g. 'status --porcelain').
Returns the combined stdout/stderr, matching the previous backtick behaviour so callers are
unchanged.

=cut

sub _git {
    my ($self, $c, $args) = @_;

    my $repo = $self->repo_path($c);
    return '' unless defined $repo && length $repo;

    # -C makes git operate on $repo without touching our cwd.
    return `git -C "$repo" $args`;
}

=head2 _git_list

Run a git command with EXPLICIT ARGUMENT LIST — no shell, no interpolation.

Unlike _git (which builds a shell string and is fine for fixed internal commands), _git_list
is the ONLY safe way to pass browser-supplied values (file paths, messages) to git: each argument
is handed to git as a distinct argv element via IPC::Run3, so shell metacharacters in a filename
or commit message can never be interpreted.

Usage: my ($out, $code) = $self->_git_list($c, 'add', '--', @paths);
Returns (combined_output, exit_code). Returns ('', -1) if the repo path can't be resolved.

=cut

sub _git_list {
    my ($self, $c, @argv) = @_;

    my $repo = $self->repo_path($c);
    return ('', -1) unless defined $repo && length $repo;

    require IPC::Run3;
    my $out = '';
    IPC::Run3::run3([ 'git', '-C', $repo, @argv ], \undef, \$out, \$out);
    my $code = $? >> 8;
    return ($out, $code);
}

=head2 _validate_paths

Gate browser-supplied file paths before any write. A path is accepted ONLY if it appears in the
current C<git status --porcelain> (tracked-changed OR untracked). Anything else — a path not in the
working-tree change set, an absolute path, a C<..> traversal, or a symlink whose real target escapes
the repo root — is rejected and logged at 'warn'.

Returns a hashref:
  { valid => [\@ok_paths], invalid => [\@rejected], untracked => { path => 1, ... } }

=cut

sub _validate_paths {
    my ($self, $c, $paths) = @_;

    my %known;       # path => tracked|untracked
    my $porcelain = $self->_git($c, 'status --porcelain 2>&1');
    for my $line (split /\n/, $porcelain) {
        # format: XY <path>   (XY = two status chars, then a space)
        next unless $line =~ /^(..)\s(.+)$/;
        my ($xy, $file) = ($1, $2);
        # porcelain may quote paths with odd chars or show "old -> new" on renames
        $file =~ s/^"(.*)"$/$1/;
        $file = (split / -> /, $file)[-1] if $file =~ / -> /;
        $known{$file} = ($xy eq '??') ? 'untracked' : 'tracked';
    }

    my $repo = $self->repo_path($c);
    my (@valid, @invalid, %untracked);

    for my $p (@{ $paths || [] }) {
        next unless defined $p && length $p;

        if ($p =~ m{(?:^|/)\.\.(?:/|$)} || $p =~ m{^/}) {
            push @invalid, $p; next;   # traversal or absolute
        }
        unless (exists $known{$p}) {
            push @invalid, $p; next;   # not in the working-tree change set
        }
        # symlink-escape guard: real path must sit under the repo root
        my $full = "$repo/$p";
        if (-l $full) {
            require Cwd;
            my $real = Cwd::abs_path($full);
            if (!$real || index($real, $repo) != 0) { push @invalid, $p; next; }
        }

        push @valid, $p;
        $untracked{$p} = 1 if $known{$p} eq 'untracked';
    }

    if (@invalid) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, '_validate_paths',
            "Rejected git paths (not in working-tree change set or unsafe): " . join(', ', @invalid));
    }

    return { valid => \@valid, invalid => \@invalid, untracked => \%untracked };
}

=head2 dashboard_action

Single POST endpoint for all Git dashboard write operations. POST-only, admin-gated,
requires C<confirm=1>, and dispatches on the C<op> parameter. Every file-targeted op runs its
paths through _validate_paths first and passes them to git as an explicit argv list (never a shell
string). On completion it redirects back to /admin/git with a flash message (PRG pattern).

Ops: stage, unstage, commit, push, delete, gitignore, stash.

=cut

sub dashboard_action :Path('/admin/git/action') :Args(0) {
    my ($self, $c) = @_;

    return unless $self->admin_auth->require_admin_access($c, 'git_dashboard_action');

    # Every write is POST + confirm.
    unless ($c->req->method eq 'POST' && $c->req->param('confirm')) {
        $c->flash->{error_msg} = 'Git actions require a confirmed POST.';
        $c->response->redirect($c->uri_for('/admin/git'));
        return;
    }

    my $op       = $c->req->param('op') || '';
    my @paths    = $c->req->param('paths');
    my $username = $c->session->{username} || ($c->user ? $c->user->username : 'unknown');

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'dashboard_action',
        "user=$username op=$op paths=" . join(',', @paths));

    my %needs_paths = map { $_ => 1 } qw(stage unstage delete gitignore stash);
    my $validated;
    if ($needs_paths{$op}) {
        $validated = $self->_validate_paths($c, \@paths);
        if (@{ $validated->{invalid} }) {
            $c->flash->{error_msg} =
                "Rejected unsafe or unknown path(s): " . join(', ', @{ $validated->{invalid} });
            $c->response->redirect($c->uri_for('/admin/git'));
            return;
        }
        unless (@{ $validated->{valid} }) {
            $c->flash->{error_msg} = 'No files selected.';
            $c->response->redirect($c->uri_for('/admin/git'));
            return;
        }
    }

    my $ok = 0;
    my $msg = '';

    if ($op eq 'stage') {
        my ($out, $code) = $self->_git_list($c, 'add', '--', @{ $validated->{valid} });
        $ok = ($code == 0);
        $msg = $ok ? "Staged " . scalar(@{ $validated->{valid} }) . " file(s)." : "Stage failed: $out";
    }
    elsif ($op eq 'unstage') {
        my ($out, $code) = $self->_git_list($c, 'restore', '--staged', '--', @{ $validated->{valid} });
        $ok = ($code == 0);
        $msg = $ok ? "Unstaged " . scalar(@{ $validated->{valid} }) . " file(s)." : "Unstage failed: $out";
    }
    elsif ($op eq 'commit') {
        my $message = $c->req->param('message') || '';
        $message =~ s/^\s+|\s+$//g;
        $message = substr($message, 0, 2000);
        if (!length $message) {
            $msg = 'Commit message is required.';
        }
        else {
            my ($out, $code) = $self->_git_list($c, 'commit', '-m', $message);
            $ok = ($code == 0);
            $msg = $ok ? "Committed staged changes." : "Commit failed: $out";
        }
    }
    elsif ($op eq 'push') {
        my $branch = $self->get_current_branch($c);
        my $tracking = $self->get_tracking_info($c);
        if (!$tracking->{upstream} && !$c->req->param('set_upstream')) {
            $msg = "Branch '$branch' has no upstream. Re-submit with 'set upstream' checked to push.";
        }
        else {
            my @cmd = ('push');
            push @cmd, '--set-upstream' if !$tracking->{upstream};
            push @cmd, 'origin', $branch;
            my ($out, $code) = $self->_git_list($c, @cmd);
            $ok = ($code == 0);
            $msg = $ok ? "Pushed '$branch' to origin." : "Push failed: $out";
        }
    }
    elsif ($op eq 'delete') {
        my @tracked   = grep { !$validated->{untracked}{$_} } @{ $validated->{valid} };
        my @untracked = grep {  $validated->{untracked}{$_} } @{ $validated->{valid} };
        my @done;

        # Tracked files: git rm (recoverable via history).
        if (@tracked) {
            my ($out, $code) = $self->_git_list($c, 'rm', '--', @tracked);
            if ($code == 0) { push @done, @tracked; } else { $msg .= "git rm failed: $out "; }
        }

        # Untracked files: irreversible unlink -> requires the SECOND confirmation.
        if (@untracked) {
            if (!$c->req->param('confirm_permanent')) {
                $msg .= "Permanent delete of untracked file(s) needs the extra confirmation: "
                      . join(', ', @untracked) . ". ";
            }
            else {
                my $repo = $self->repo_path($c);
                for my $p (@untracked) {
                    if (unlink "$repo/$p") { push @done, $p; }
                    else { $msg .= "Failed to delete $p: $! "; }
                }
            }
        }

        $ok = (@done > 0);
        $msg = "Deleted: " . join(', ', @done) . ". $msg" if @done;
        $msg ||= 'Nothing deleted.';
    }
    elsif ($op eq 'gitignore') {
        # Only untracked files may be gitignored (tracked ones need git rm --cached first).
        my @tracked = grep { !$validated->{untracked}{$_} } @{ $validated->{valid} };
        my @ignore  = grep {  $validated->{untracked}{$_} } @{ $validated->{valid} };
        $ok = $self->_append_gitignore($c, \@ignore);
        $msg  = @ignore ? ($ok ? "Added to .gitignore: " . join(', ', @ignore) . "."
                               : "Failed to update .gitignore.") : '';
        $msg .= " Skipped (tracked — run 'git rm --cached' first): " . join(', ', @tracked) . "."
            if @tracked;
        $ok = 1 if @tracked && !@ignore;   # informational, not a failure
    }
    elsif ($op eq 'stash') {
        my $message = $c->req->param('message') || '';
        $message =~ s/^\s+|\s+$//g;
        my @cmd = ('stash', 'push');
        push @cmd, '-m', substr($message, 0, 500) if length $message;
        push @cmd, '--', @{ $validated->{valid} };
        my ($out, $code) = $self->_git_list($c, @cmd);
        $ok = ($code == 0);
        $msg = $ok ? "Stashed " . scalar(@{ $validated->{valid} }) . " file(s)." : "Stash failed: $out";
    }
    else {
        $msg = "Unknown git operation: $op";
    }

    $self->logging->log_with_details($c, ($ok ? 'info' : 'warn'), __FILE__, __LINE__,
        'dashboard_action', "op=$op result=" . ($ok ? 'ok' : 'fail') . " : $msg");

    if ($ok) { $c->flash->{success_msg} = $msg; }
    else     { $c->flash->{error_msg}   = $msg; }

    $c->response->redirect($c->uri_for('/admin/git'));
}

=head2 suggest_commit_message

AJAX endpoint: read the current diff and ask the local AI to draft a commit message.

POST /admin/git/suggest_message
  - optional repeated 'paths' params: diff only those files (validated against git status);
    with none, uses the staged diff, falling back to the full working-tree diff.

Reuses the existing AI2 provider stack (Router picks provider+model, Ollama client runs it)
so no new AI plumbing is introduced. One-shot call — does NOT create a conversation. Returns
JSON: { success, message, model } or { success => 0, error }.

=cut

sub suggest_commit_message :Path('/admin/git/suggest_message') :Args(0) {
    my ($self, $c) = @_;

    $c->response->content_type('application/json');
    return unless $self->admin_auth->require_admin_access($c, 'git_suggest_message');

    unless ($c->req->method eq 'POST') {
        $c->response->body(encode_json({ success => 0, error => 'POST required' }));
        return;
    }

    # Build the diff. Selected paths (validated) narrow it; else staged, else working tree.
    my @paths = $c->req->param('paths');
    my $diff  = '';
    my $scope = '';

    if (@paths) {
        my $v = $self->_validate_paths($c, \@paths);
        if (@{ $v->{invalid} }) {
            $c->response->body(encode_json({
                success => 0,
                error   => 'Rejected unsafe/unknown path(s): ' . join(', ', @{ $v->{invalid} }),
            }));
            return;
        }
        if (@{ $v->{valid} }) {
            my ($out, $code) = $self->_git_list($c, 'diff', 'HEAD', '--', @{ $v->{valid} });
            $diff  = $out;
            $scope = 'selected files: ' . join(', ', @{ $v->{valid} });
        }
    }

    if (!length $diff) {
        my ($staged) = $self->_git_list($c, 'diff', '--cached');
        if (length $staged) { $diff = $staged; $scope = 'staged changes'; }
    }
    if (!length $diff) {
        my ($wt) = $self->_git_list($c, 'diff', 'HEAD');
        if (length $wt) { $diff = $wt; $scope = 'working-tree changes'; }
    }

    unless (length $diff) {
        $c->response->body(encode_json({
            success => 0,
            error   => 'No changes to describe (nothing staged or modified).',
        }));
        return;
    }

    # Cap the diff so a huge changeset can't blow the model context / timeout.
    my $MAX = 12000;
    my $truncated = 0;
    if (length($diff) > $MAX) {
        $diff = substr($diff, 0, $MAX);
        $truncated = 1;
    }

    # Also give the model the file name-status for structure.
    my ($namestat) = $self->_git_list($c, 'diff', '--stat', 'HEAD');

    my $prompt = <<"PROMPT";
You are writing a git commit message for a Perl/Catalyst web application (Comserv2).
Write a Conventional Commits style message: a concise imperative subject line
(<= 72 chars, e.g. "fix(git): ..."), a blank line, then 1-4 short bullet points
explaining WHAT changed and WHY. Do NOT include backticks, code fences, or any
preamble like "Here is". Output ONLY the commit message text.

Scope: $scope

File summary:
$namestat

Diff${\ ($truncated ? ' (truncated)' : '')}:
$diff
PROMPT

    # Resolve an installed local model via the same Router the chat uses.
    my $provider = try { $c->model('AI2::Provider::Ollama') } catch { undef };
    unless ($provider && $provider->can('chat')) {
        $c->response->body(encode_json({ success => 0, error => 'AI provider unavailable' }));
        return;
    }

    my $installed = try { $provider->list_models($c) } catch { [] };
    my ($prov_name, $model) = $c->model('AI2::Router')->select_model($c,
        installed_models => $installed,
        agent_id         => 'coding',
    );

    my ($host, $port) = $provider->resolve_host($c);

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'suggest_commit_message',
        "Generating commit message via $prov_name/$model for $scope");

    my $resp = try {
        $provider->chat($c,
            model    => $model,
            host     => $host,
            port     => $port,
            messages => [
                { role => 'system', content => 'You are a precise git commit message generator.' },
                { role => 'user',   content => $prompt },
            ],
        );
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'suggest_commit_message', "AI call threw: $_");
        undef;
    };

    unless ($resp && $resp->{success} && length($resp->{response} // '')) {
        $c->response->body(encode_json({
            success => 0,
            error   => ($resp && $resp->{error}) ? $resp->{error} : 'AI returned no message',
        }));
        return;
    }

    my $message = $resp->{response};
    $message =~ s/^\s+//; $message =~ s/\s+$//;
    # Strip any stray code fences the model may add despite instructions.
    $message =~ s/^```[a-zA-Z]*\n?//; $message =~ s/\n?```$//;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'suggest_commit_message',
        "Suggested commit message (" . length($message) . " chars) via $model");

    $c->response->body(encode_json({
        success => 1,
        message => $message,
        model   => $resp->{model} // $model,
    }));
}

=head2 _append_gitignore

Append paths to the repo-root .gitignore, one per line, skipping any already present.
Pure file operation — does not call git. Returns 1 on success.

=cut

sub _append_gitignore {
    my ($self, $c, $paths) = @_;
    return 1 unless $paths && @$paths;

    my $repo = $self->repo_path($c);
    return 0 unless defined $repo && length $repo;
    my $file = "$repo/.gitignore";

    my %existing;
    if (-f $file) {
        open my $rfh, '<', $file or do {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_append_gitignore',
                "Cannot read $file: $!");
            return 0;
        };
        while (my $l = <$rfh>) { chomp $l; $existing{$l} = 1; }
        close $rfh;
    }

    my @to_add = grep { !$existing{$_} } @$paths;
    return 1 unless @to_add;   # nothing new

    open my $wfh, '>>', $file or do {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_append_gitignore',
            "Cannot write $file: $!");
        return 0;
    };
    print $wfh "$_\n" for @to_add;
    close $wfh;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_append_gitignore',
        "Added to .gitignore: " . join(', ', @to_add));
    return 1;
}

=head2 index

Git dashboard — the SINGLE entry point for all git functionality.

Route lives HERE in Admin::Git, deliberately NOT in Admin.pm: every route added to this
controller instead of Admin.pm keeps Admin.pm shrinking (see the Git Subsystem Refactor Plan,
Appendix A — Admin.pm is 7,882 lines against a 4,000 hard limit).

Read-only. All write operations remain on their existing pages until Phase G moves them here
as panels.

=cut

sub index :Path('/admin/git') :Args(0) {
    my ($self, $c) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
        "Starting git dashboard");

    return unless $self->admin_auth->require_admin_access($c, 'git_dashboard');

    my $status = $self->get_git_status($c);

    $c->stash(
        repo_path       => $self->repo_path($c),
        current_branch  => $self->get_current_branch($c),
        local_branches  => $self->get_local_branches($c),
        recent_commits  => $self->get_recent_commits($c),
        git_status      => $status,
        stash_list      => $self->get_git_stash_list($c),
        tracking        => $self->get_tracking_info($c),
        template        => 'admin/git/index.tt',
    );

    if ($c->session->{debug_mode}) {
        push @{$c->stash->{debug_msg}}, "Git dashboard - Template: admin/git/index.tt";
        push @{$c->stash->{debug_msg}}, "Repo: " . ($self->repo_path($c) || 'unresolved');
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
        "Completed git dashboard");
}

=head2 get_tracking_info

Ahead/behind counts against the upstream branch. Read-only; does not fetch.

Returns a hashref: upstream, ahead, behind. upstream is undef when the branch has no upstream.

=cut

sub get_tracking_info {
    my ($self, $c) = @_;

    my $info = { upstream => undef, ahead => 0, behind => 0 };

    try {
        my $upstream = $self->_git($c, 'rev-parse --abbrev-ref --symbolic-full-name @{u} 2>&1');
        chomp $upstream;

        # No upstream configured -> git prints an error; leave counts at zero.
        return $info if !$upstream || $upstream =~ /fatal|no upstream/i;

        $info->{upstream} = $upstream;

        my $counts = $self->_git($c, 'rev-list --left-right --count @{u}...HEAD 2>&1');
        chomp $counts;
        if ($counts =~ /^(\d+)\s+(\d+)$/) {
            $info->{behind} = $1;
            $info->{ahead}  = $2;
        }
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_tracking_info',
            "Error getting tracking info: $_");
    };

    return $info;
}

=head2 git_pull

Git pull functionality with enhanced CSC admin support

=cut

sub git_pull :Path('/admin/git_pull') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'git_pull', 
        "Starting git_pull action");
    
    # Debug: Add some basic info to stash to see if we get this far
    $c->stash->{debug_info} = "Git controller git_pull method called";
    
    # Check admin access
    return unless $self->admin_auth->require_admin_access($c, 'git_pull');
    
    # Debug: Check if user exists and log session info
    my $user_exists = $c->user_exists ? 'true' : 'false';
    my $username = $c->session->{username} || ($c->user ? $c->user->username : 'none');
    my $sitename = $c->session->{SiteName} || 'none';
    my $roles = $c->session->{roles} || [];
    my $roles_str = ref($roles) eq 'ARRAY' ? join(',', @$roles) : ($roles || 'none');
    
    # Enhanced debug - check all possible username sources
    my $session_username = $c->session->{username} || 'none';
    my $user_obj_username = ($c->user ? $c->user->username : 'none');
    my $session_user_id = $c->session->{user_id} || 'none';
    
    # Check why user_exists is false - it requires BOTH username AND user_id
    my $has_username = $c->session->{username} ? 'YES' : 'NO';
    my $has_user_id = $c->session->{user_id} ? 'YES' : 'NO';
    my $user_exists_reason = "username=$has_username, user_id=$has_user_id";
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'git_pull', 
        "DEBUG - user_exists: $user_exists ($user_exists_reason), session_username: $session_username, user_obj_username: $user_obj_username, session_user_id: $session_user_id, sitename: $sitename, roles: $roles_str");
    
    # Enhanced debug info for template
    $c->stash->{debug_session_info} = "UserExists: $user_exists ($user_exists_reason), SessionUser: $session_username, UserObj: $user_obj_username, UserID: $session_user_id, Site: $sitename, Roles: $roles_str";
    
    # Check if this is a POST request (user confirmed the git pull)
    if ($c->req->method eq 'POST' && $c->req->param('confirm')) {
        
        my $selected_branch = $c->req->param('branch') || 'main';
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'git_pull', 
            "Git pull confirmed for branch '$selected_branch', executing");
        
        # Execute the git pull operation with branch selection
        my ($success, $output, $warning) = $self->execute_git_pull($c, $selected_branch);
        
        # Store the results in stash for the template
        $c->stash(
            output => $output,
            selected_branch => $selected_branch,
            success_msg => $success ? "Git pull completed successfully for branch '$selected_branch'." : undef,
            error_msg => $success ? undef : "Git pull failed for branch '$selected_branch'. See output for details.",
            warning_msg => $warning
        );
    }
    
    # Get current branch and available branches for the interface
    my $current_branch = $self->get_current_branch($c);
    my $available_branches = $self->get_available_branches($c);
    
    # Log branch information for debugging
    my $branches_str = ref($available_branches) eq 'ARRAY' ? join(',', @$available_branches) : 'none';
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'git_pull', 
        "Branch info - current: $current_branch, available: $branches_str");
    
    # Add branch information to stash
    $c->stash(
        current_branch => $current_branch,
        available_branches => $available_branches
    );
    
    # Use the standard debug message system
    if ($c->session->{debug_mode}) {
        push @{$c->stash->{debug_msg}}, "Git controller git_pull view - Template: admin/git_pull.tt";
    }
    
    # Set the template
    $c->stash(template => 'admin/git_pull.tt');
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'git_pull', 
        "Completed git_pull action");
}

=head2 execute_git_pull

Execute the actual git pull operation

=cut

sub execute_git_pull {
    my ($self, $c, $branch) = @_;
    
    $branch ||= 'main';
    my $output = '';
    my $success = 0;
    my $warning = undef;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'execute_git_pull', 
        "Starting git pull execution for branch '$branch'");
    
    try {
        my $app_dir = $self->repo_path($c);

        # Check if theme_mappings.json has local changes
        my $theme_file = "$app_dir/Comserv/root/static/config/theme_mappings.json";
        my $has_theme_changes = 0;
        
        if (-f $theme_file) {
            my $git_status = $self->_git($c, "status --porcelain \"$theme_file\" 2>&1");
            if ($git_status && $git_status =~ /^\s*M/) {
                $has_theme_changes = 1;
                $output .= "Detected local changes in theme_mappings.json\n";
                
                # Create backup
                my $backup_file = "$theme_file.backup." . time();
                if (copy($theme_file, $backup_file)) {
                    $output .= "Created backup: $backup_file\n";
                } else {
                    $output .= "Warning: Could not create backup of theme_mappings.json\n";
                }
                
                # Stash changes
                my $stash_output = $self->_git($c, "stash push -m \"Auto-stash theme_mappings.json before pull\" \"$theme_file\" 2>&1");
                $output .= "Stashed changes: $stash_output\n";
            }
        }
        
        # Fetch latest changes
        $output .= "Fetching latest changes...\n";
        my $fetch_output = $self->_git($c, "fetch origin 2>&1");
        $output .= $fetch_output;
        
        # Switch to the specified branch if not already on it
        my $current_branch = $self->_git($c, "branch --show-current 2>&1");
        chomp($current_branch);
        
        if ($current_branch ne $branch) {
            $output .= "Switching to branch '$branch'...\n";
            my $checkout_output = $self->_git($c, "checkout \"$branch\" 2>&1");
            $output .= $checkout_output;
            
            if ($? != 0) {
                die "Failed to switch to branch '$branch'";
            }
        }
        
        # Pull changes
        $output .= "Pulling changes from origin/$branch...\n";
        my $pull_output = $self->_git($c, "pull origin \"$branch\" 2>&1");
        $output .= $pull_output;
        
        if ($? == 0) {
            $success = 1;
            $output .= "Git pull completed successfully.\n";
            
            # If we had theme changes, try to reapply them
            if ($has_theme_changes) {
                $output .= "Attempting to reapply theme_mappings.json changes...\n";
                my $stash_pop_output = $self->_git($c, "stash pop 2>&1");
                $output .= $stash_pop_output;
                
                if ($? != 0) {
                    $warning = "Git pull successful, but could not automatically reapply theme_mappings.json changes. Please check the backup file and resolve manually.";
                }
            }
        } else {
            die "Git pull failed";
        }
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'execute_git_pull', 
            "Git pull completed successfully");
    } catch {
        my $error = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'execute_git_pull', 
            "Error during git pull: $error");
        $output .= "Error: $error\n";
        return (0, $output, undef);
    };
    
    return ($success, $output, $warning);
}

=head2 get_current_branch

Get the current Git branch

=cut

sub get_current_branch {
    my ($self, $c) = @_;
    
    try {
        
        my $branch = $self->_git($c, "branch --show-current 2>&1");
        chomp($branch);
        return $branch || 'unknown';
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_current_branch', 
            "Error getting current branch: $_");
        return 'unknown';
    };
}

=head2 get_available_branches

Get list of available Git branches

=cut

sub get_available_branches {
    my ($self, $c) = @_;
    
    try {
        
        # First fetch to ensure we have latest remote branch info
        my $fetch_output = $self->_git($c, "fetch origin 2>&1");
        
        # Use --no-color to avoid ANSI color codes that interfere with parsing
        my $branches_output = $self->_git($c, "branch -r --no-color 2>&1");
        my @branches = ();
        my %excluded_branches = (
            'master' => 1,    # Exclude master branch as requested
            'master2' => 1,   # Exclude master2 as well
            'HEAD' => 1       # Always exclude HEAD
        );
        
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'get_available_branches', 
            "Raw git branch output: $branches_output");
        
        for my $line (split /\n/, $branches_output) {
            $line =~ s/^\s+|\s+$//g;  # trim whitespace
            $line =~ s/\x1b\[[0-9;]*m//g;  # remove any remaining ANSI color codes
            
            if ($line =~ /^origin\/(.+)$/) {
                my $branch_name = $1;
                # Skip excluded branches and HEAD pointer
                unless ($excluded_branches{$branch_name} || $branch_name =~ /^HEAD\s*->/) {
                    push @branches, $branch_name;
                }
            }
        }
        
        # Sort branches with main first, then alphabetically
        @branches = sort {
            return -1 if $a eq 'main' && $b ne 'main';
            return 1 if $b eq 'main' && $a ne 'main';
            return $a cmp $b;
        } @branches;
        
        # If no remote branches found, use main as fallback (no master)
        if (@branches == 0) {
            @branches = ('main');
            $self->logging->log_with_details($c, 'warning', __FILE__, __LINE__, 'get_available_branches', 
                "No remote branches found, using fallback: main");
        }
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_available_branches', 
            "Found branches: " . join(', ', @branches));
        
        return \@branches;
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_available_branches', 
            "Error getting available branches: $_");
        return ['main'];  # fallback without master
    };
}

=head2 safe_git_pull

Enhanced git pull with backup/restore functionality for production files

=cut

sub safe_git_pull :Path('/admin/safe_git_pull') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'safe_git_pull', 
        "Starting safe git pull with backup/restore");
    
    # Check admin access
    return unless $self->admin_auth->require_admin_access($c, 'safe_git_pull');
    
    # Check if this is a POST request (user confirmed the operation)
    if ($c->req->method eq 'POST' && $c->req->param('confirm')) {
        
        my $selected_branch = $c->req->param('branch') || 'main';
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'safe_git_pull', 
            "Safe git pull confirmed for branch '$selected_branch', executing");
        
        # Execute the safe git pull operation
        my $result = $self->execute_safe_git_pull($c, $selected_branch);
        
        # Store the results in stash for the template
        $c->stash(%$result);
    }
    
    # Get current branch and available branches for the interface
    my $current_branch = $self->get_current_branch($c);
    my $available_branches = $self->get_available_branches($c);
    
    # Get list of protected files
    my $protected_files = $self->get_protected_files($c);
    
    # Add information to stash
    $c->stash(
        current_branch => $current_branch,
        available_branches => $available_branches,
        protected_files => $protected_files
    );
    
    # Use the standard debug message system
    if ($c->session->{debug_mode}) {
        push @{$c->stash->{debug_msg}}, "Git controller safe_git_pull view - Template: admin/safe_git_pull.tt";
    }
    
    # Set the template
    $c->stash(template => 'admin/safe_git_pull.tt');
}

=head2 execute_safe_git_pull

Execute git pull with automatic backup and restore of protected files

=cut

sub execute_safe_git_pull {
    my ($self, $c, $branch) = @_;
    
    $branch ||= 'main';
    my $result = {
        success => 0,
        output => '',
        backup_info => {},
        restore_info => {},
        selected_branch => $branch
    };
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'execute_safe_git_pull', 
        "Starting safe git pull execution for branch '$branch'");
    
    try {
        # Step 1: Backup protected files
        $result->{output} .= "=== STEP 1: Backing up protected files ===\n";
        my $backup_result = $self->backup_protected_files($c);
        $result->{backup_info} = $backup_result;
        
        if (!$backup_result->{success}) {
            die "Backup failed: " . $backup_result->{message};
        }
        
        $result->{output} .= $backup_result->{output} . "\n";
        
        # Step 2: Execute git pull
        $result->{output} .= "=== STEP 2: Executing git pull ===\n";
        my ($pull_success, $pull_output, $pull_warning) = $self->execute_git_pull($c, $branch);
        $result->{output} .= $pull_output . "\n";
        
        if (!$pull_success) {
            die "Git pull failed";
        }
        
        # Step 3: Restore protected files
        $result->{output} .= "=== STEP 3: Restoring protected files ===\n";
        my $restore_result = $self->restore_protected_files($c, $backup_result->{backup_id});
        $result->{restore_info} = $restore_result;
        
        if (!$restore_result->{success}) {
            $result->{warning_msg} = "Git pull successful, but restore failed: " . $restore_result->{message} . 
                                   " Backup available at: " . $backup_result->{backup_path};
        }
        
        $result->{output} .= $restore_result->{output} . "\n";
        
        $result->{success} = 1;
        $result->{success_msg} = "Safe git pull completed successfully for branch '$branch'.";
        
        if ($pull_warning) {
            $result->{warning_msg} = $pull_warning;
        }
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'execute_safe_git_pull', 
            "Safe git pull completed successfully");
            
    } catch {
        my $error = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'execute_safe_git_pull', 
            "Error during safe git pull: $error");
        $result->{output} .= "Error: $error\n";
        $result->{error_msg} = "Safe git pull failed: $error";
        
        # If we have backup info, include it in the error message
        if ($result->{backup_info}->{backup_path}) {
            $result->{error_msg} .= " Backup available at: " . $result->{backup_info}->{backup_path};
        }
    };
    
    return $result;
}

=head2 backup_protected_files

Create backup of protected files before git operations

=cut

sub backup_protected_files {
    my ($self, $c) = @_;
    
    # Use centralized BackupManager for protected files backup
    my $username = $c->session->{username} || 'system';
    my $result = $self->backup_manager->create_protected_files_backup($username);
    
    # Log the backup operation
    if ($result->{success}) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'backup_protected_files', 
            "Successfully created protected files backup: $result->{backup_id}");
    } else {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'backup_protected_files', 
            "Failed to create protected files backup: $result->{message}");
    }
    
    return $result;
}

=head2 restore_protected_files

Restore protected files from backup

=cut

sub restore_protected_files {
    my ($self, $c, $backup_id) = @_;
    
    my $result = {
        success => 0,
        message => '',
        output => '',
        files_restored => []
    };
    
    return $result unless $backup_id;
    
    try {
        my $app_dir = $self->repo_path($c);
        my $backup_dir = "$app_dir/Comserv/backups";
        my $backup_path = "$backup_dir/$backup_id.tar.gz";
        
        unless (-f $backup_path) {
            die "Backup file not found: $backup_path";
        }
        
        # Read the tar archive
        my $tar = Archive::Tar->new();
        $tar->read($backup_path);
        
        # Extract files to their original locations
        my @files = $tar->get_files();
        
        for my $file (@files) {
            my $file_path = $file->full_path();
            
            # Extract to original location
            $tar->extract_file($file->name(), $file_path);
            
            # Get relative path for reporting
            my $rel_path = $file_path;
            $rel_path =~ s/^\Q$app_dir\E\///;
            
            push @{$result->{files_restored}}, $rel_path;
            $result->{output} .= "Restored: $rel_path\n";
        }
        
        $result->{success} = 1;
        $result->{message} = "Files restored successfully";
        $result->{output} .= "Restoration completed. Files restored: " . scalar(@{$result->{files_restored}}) . "\n";
        
    } catch {
        my $error = $_;
        $result->{message} = "Restore failed: $error";
        $result->{output} .= "Restore error: $error\n";
    };
    
    return $result;
}

=head2 restore_individual_file

Restore a single file from a specific backup

=cut

sub restore_individual_file :Path('/admin/restore_file') :Args(0) {
    my ($self, $c) = @_;
    
    # Check admin access
    return unless $self->admin_auth->require_admin_access($c, 'restore_file');
    
    if ($c->req->method eq 'POST') {
        my $backup_id = $c->req->param('backup_id');
        my $file_path = $c->req->param('file_path');
        
        if ($backup_id && $file_path) {
            my $result = $self->execute_individual_restore($c, $backup_id, $file_path);
            $c->stash(%$result);
        } else {
            $c->stash(error_msg => "Missing backup ID or file path");
        }
    }
    
    # Get available backups
    my $backups = $self->get_available_backups($c);
    $c->stash(available_backups => $backups);
    
    if ($c->session->{debug_mode}) {
        push @{$c->stash->{debug_msg}}, "Git controller restore_file view - Template: admin/restore_file.tt";
    }
    
    $c->stash(template => 'admin/restore_file.tt');
}

=head2 execute_individual_restore

Execute restoration of a single file from backup

=cut

sub execute_individual_restore {
    my ($self, $c, $backup_id, $file_path) = @_;
    
    my $result = {
        success => 0,
        message => '',
        output => '',
        backup_id => $backup_id,
        file_path => $file_path
    };
    
    try {
        my $app_dir = $self->repo_path($c);
        my $backup_dir = "$app_dir/Comserv/backups";
        my $backup_path = "$backup_dir/$backup_id.tar.gz";
        
        unless (-f $backup_path) {
            die "Backup file not found: $backup_path";
        }
        
        # Read the tar archive
        my $tar = Archive::Tar->new();
        $tar->read($backup_path);
        
        # Find the specific file in the archive
        my $target_file = undef;
        my @files = $tar->get_files();
        
        for my $file (@files) {
            my $archive_path = $file->full_path();
            if ($archive_path =~ /\Q$file_path\E$/) {
                $target_file = $file;
                last;
            }
        }
        
        unless ($target_file) {
            die "File '$file_path' not found in backup '$backup_id'";
        }
        
        # Extract the specific file
        my $full_target_path = "$app_dir/$file_path";
        $tar->extract_file($target_file->name(), $full_target_path);
        
        $result->{success} = 1;
        $result->{message} = "File restored successfully";
        $result->{output} = "Restored '$file_path' from backup '$backup_id'\n";
        $result->{success_msg} = "File '$file_path' has been restored from backup '$backup_id'";
        
    } catch {
        my $error = $_;
        $result->{message} = "Restore failed: $error";
        $result->{output} = "Restore error: $error\n";
        $result->{error_msg} = "Failed to restore file: $error";
    };
    
    return $result;
}

=head2 get_protected_files

Get list of files that should be protected during git operations

=cut

sub get_protected_files {
    my ($self, $c) = @_;
    
    # Use centralized BackupManager for protected files list
    return $self->backup_manager->protected_files;
}

=head2 get_available_backups

Get list of available backups for restore operations

=cut

sub get_available_backups {
    my ($self, $c) = @_;
    
    my $backups = [];
    
    try {
        my $app_dir = $self->repo_path($c);
        my $backup_dir = "$app_dir/Comserv/backups";
        
        return $backups unless -d $backup_dir;
        
        opendir(my $dh, $backup_dir) or die "Cannot open backup directory: $!";
        my @files = readdir($dh);
        closedir($dh);
        
        for my $file (@files) {
            next unless $file =~ /\.tar\.gz\.meta$/;
            
            my $meta_path = "$backup_dir/$file";
            next unless -f $meta_path;
            
            try {
                open(my $fh, '<', $meta_path) or die "Cannot read metadata: $!";
                my $content = do { local $/; <$fh> };
                close($fh);
                
                my $meta = decode_json($content);
                
                # Add backup ID (filename without .tar.gz.meta)
                my $backup_id = $file;
                $backup_id =~ s/\.tar\.gz\.meta$//;
                $meta->{backup_id} = $backup_id;
                
                # Format creation date
                if ($meta->{created_at}) {
                    $meta->{created_date} = strftime("%Y-%m-%d %H:%M:%S", localtime($meta->{created_at}));
                }
                
                push @$backups, $meta;
            } catch {
                # Skip invalid metadata files
            };
        }
        
        # Sort by creation time (newest first)
        @$backups = sort { ($b->{created_at} || 0) <=> ($a->{created_at} || 0) } @$backups;
        
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_available_backups', 
            "Error getting available backups: $_");
    };
    
    return $backups;
}

=head2 git_stash_management

Git stash management interface

=cut

sub git_stash_management :Path('/admin/git_stash') :Args(0) {
    my ($self, $c) = @_;
    
    # Check admin access
    return unless $self->admin_auth->require_admin_access($c, 'git_stash');
    
    if ($c->req->method eq 'POST') {
        my $action = $c->req->param('action');
        my $result = {};
        
        if ($action eq 'stash_push') {
            my $message = $c->req->param('stash_message') || 'Web interface stash';
            $result = $self->execute_git_stash_push($c, $message);
        } elsif ($action eq 'stash_pop') {
            my $stash_index = $c->req->param('stash_index') || 0;
            $result = $self->execute_git_stash_pop($c, $stash_index);
        } elsif ($action eq 'stash_drop') {
            my $stash_index = $c->req->param('stash_index') || 0;
            $result = $self->execute_git_stash_drop($c, $stash_index);
        }
        
        $c->stash(%$result) if $result;
    }
    
    # Get current stash list
    my $stash_list = $self->get_git_stash_list($c);
    $c->stash(stash_list => $stash_list);
    
    # Get current git status
    my $git_status = $self->get_git_status($c);
    $c->stash(git_status => $git_status);
    
    if ($c->session->{debug_mode}) {
        push @{$c->stash->{debug_msg}}, "Git controller git_stash view - Template: admin/git_stash.tt";
    }
    
    $c->stash(template => 'admin/git_stash.tt');
}

=head2 execute_git_stash_push

Execute git stash push operation

=cut

sub execute_git_stash_push {
    my ($self, $c, $message) = @_;
    
    my $result = {
        success => 0,
        output => '',
        message => $message
    };
    
    try {
        
        # Execute git stash push with message
        my $stash_output = $self->_git($c, "stash push -m \"$message\" 2>&1");
        $result->{output} = $stash_output;
        
        if ($? == 0) {
            $result->{success} = 1;
            $result->{success_msg} = "Changes stashed successfully with message: '$message'";
        } else {
            die "Git stash push failed: $stash_output";
        }
        
    } catch {
        my $error = $_;
        $result->{error_msg} = "Stash operation failed: $error";
        $result->{output} .= "\nError: $error";
    };
    
    return $result;
}

=head2 execute_git_stash_pop

Execute git stash pop operation

=cut

sub execute_git_stash_pop {
    my ($self, $c, $stash_index) = @_;
    
    my $result = {
        success => 0,
        output => '',
        stash_index => $stash_index
    };
    
    try {
        
        # Execute git stash pop
        my $stash_ref = $stash_index ? "stash\@{$stash_index}" : "stash\@{0}";
        my $pop_output = $self->_git($c, "stash pop \"$stash_ref\" 2>&1");
        $result->{output} = $pop_output;
        
        if ($? == 0) {
            $result->{success} = 1;
            $result->{success_msg} = "Stash applied and removed successfully";
        } else {
            die "Git stash pop failed: $pop_output";
        }
        
    } catch {
        my $error = $_;
        $result->{error_msg} = "Stash pop operation failed: $error";
        $result->{output} .= "\nError: $error";
    };
    
    return $result;
}

=head2 execute_git_stash_drop

Execute git stash drop operation

=cut

sub execute_git_stash_drop {
    my ($self, $c, $stash_index) = @_;
    
    my $result = {
        success => 0,
        output => '',
        stash_index => $stash_index
    };
    
    try {
        
        # Execute git stash drop
        my $stash_ref = $stash_index ? "stash\@{$stash_index}" : "stash\@{0}";
        my $drop_output = $self->_git($c, "stash drop \"$stash_ref\" 2>&1");
        $result->{output} = $drop_output;
        
        if ($? == 0) {
            $result->{success} = 1;
            $result->{success_msg} = "Stash dropped successfully";
        } else {
            die "Git stash drop failed: $drop_output";
        }
        
    } catch {
        my $error = $_;
        $result->{error_msg} = "Stash drop operation failed: $error";
        $result->{output} .= "\nError: $error";
    };
    
    return $result;
}

=head2 get_git_stash_list

Get list of current git stashes

=cut

sub get_git_stash_list {
    my ($self, $c) = @_;
    
    my $stashes = [];
    
    try {
        
        my $stash_output = $self->_git($c, "stash list 2>&1");
        
        if ($? == 0 && $stash_output) {
            my @lines = split /\n/, $stash_output;
            for my $line (@lines) {
                if ($line =~ /^(stash@\{(\d+)\}):\s*(.+)$/) {
                    push @$stashes, {
                        ref => $1,
                        index => $2,
                        message => $3
                    };
                }
            }
        }
        
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_git_stash_list', 
            "Error getting stash list: $_");
    };
    
    return $stashes;
}

=head2 get_git_status

Get current git status

=cut

sub get_git_status {
    my ($self, $c) = @_;
    
    my $status = {
        has_changes => 0,
        staged_files => [],
        modified_files => [],
        untracked_files => [],
        output => ''
    };
    
    try {
        
        my $status_output = $self->_git($c, "status --porcelain 2>&1");
        $status->{output} = $status_output;
        
        if ($? == 0 && $status_output) {
            $status->{has_changes} = 1;
            
            my @lines = split /\n/, $status_output;
            for my $line (@lines) {
                if ($line =~ /^(.)(.) (.+)$/) {
                    my ($staged, $modified, $file) = ($1, $2, $3);
                    
                    if ($staged ne ' ' && $staged ne '?') {
                        push @{$status->{staged_files}}, $file;
                    }
                    if ($modified ne ' ') {
                        push @{$status->{modified_files}}, $file;
                    }
                    if ($staged eq '?' && $modified eq '?') {
                        push @{$status->{untracked_files}}, $file;
                    }
                }
            }
        }
        
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_git_status', 
            "Error getting git status: $_");
    };
    
    return $status;
}

=head2 git_commit_management

Git commit management interface

=cut

sub git_commit_management :Path('/admin/git_commit') :Args(0) {
    my ($self, $c) = @_;
    
    # Check admin access
    return unless $self->admin_auth->require_admin_access($c, 'git_commit');
    
    if ($c->req->method eq 'POST') {
        my $action = $c->req->param('action');
        my $result = {};
        
        if ($action eq 'add_files') {
            my @files = $c->req->param('files');
            $result = $self->execute_git_add($c, \@files);
        } elsif ($action eq 'commit') {
            my $message = $c->req->param('commit_message');
            $result = $self->execute_git_commit($c, $message);
        } elsif ($action eq 'add_and_commit') {
            my @files = $c->req->param('files');
            my $message = $c->req->param('commit_message');
            $result = $self->execute_git_add_and_commit($c, \@files, $message);
        }
        
        $c->stash(%$result) if $result;
    }
    
    # Get current git status
    my $git_status = $self->get_git_status($c);
    $c->stash(git_status => $git_status);
    
    # Get recent commits
    my $recent_commits = $self->get_recent_commits($c);
    $c->stash(recent_commits => $recent_commits);
    
    if ($c->session->{debug_mode}) {
        push @{$c->stash->{debug_msg}}, "Git controller git_commit view - Template: admin/git_commit.tt";
    }
    
    $c->stash(template => 'admin/git_commit.tt');
}

=head2 execute_git_add

Execute git add operation

=cut

sub execute_git_add {
    my ($self, $c, $files) = @_;
    
    my $result = {
        success => 0,
        output => '',
        files => $files
    };
    
    return $result unless $files && @$files;
    
    try {
        
        # Add each file
        for my $file (@$files) {
            my $add_output = $self->_git($c, "add \"$file\" 2>&1");
            $result->{output} .= "Adding $file: $add_output\n";
            
            if ($? != 0) {
                die "Failed to add file '$file': $add_output";
            }
        }
        
        $result->{success} = 1;
        $result->{success_msg} = "Files added to staging area successfully";
        
    } catch {
        my $error = $_;
        $result->{error_msg} = "Git add operation failed: $error";
        $result->{output} .= "\nError: $error";
    };
    
    return $result;
}

=head2 execute_git_commit

Execute git commit operation

=cut

sub execute_git_commit {
    my ($self, $c, $message) = @_;
    
    my $result = {
        success => 0,
        output => '',
        message => $message
    };
    
    return $result unless $message;
    
    try {
        
        # Execute git commit
        my $commit_output = $self->_git($c, "commit -m \"$message\" 2>&1");
        $result->{output} = $commit_output;
        
        if ($? == 0) {
            $result->{success} = 1;
            $result->{success_msg} = "Commit created successfully";
        } else {
            die "Git commit failed: $commit_output";
        }
        
    } catch {
        my $error = $_;
        $result->{error_msg} = "Git commit operation failed: $error";
        $result->{output} .= "\nError: $error";
    };
    
    return $result;
}

=head2 execute_git_add_and_commit

Execute git add and commit in one operation

=cut

sub execute_git_add_and_commit {
    my ($self, $c, $files, $message) = @_;
    
    my $result = {
        success => 0,
        output => '',
        files => $files,
        message => $message
    };
    
    return $result unless $files && @$files && $message;
    
    try {
        # First add the files
        my $add_result = $self->execute_git_add($c, $files);
        $result->{output} .= $add_result->{output};
        
        if (!$add_result->{success}) {
            die "Add operation failed";
        }
        
        # Then commit
        my $commit_result = $self->execute_git_commit($c, $message);
        $result->{output} .= $commit_result->{output};
        
        if (!$commit_result->{success}) {
            die "Commit operation failed";
        }
        
        $result->{success} = 1;
        $result->{success_msg} = "Files added and committed successfully";
        
    } catch {
        my $error = $_;
        $result->{error_msg} = "Git add and commit operation failed: $error";
        $result->{output} .= "\nError: $error";
    };
    
    return $result;
}

=head2 get_recent_commits

Get list of recent commits

=cut

sub get_recent_commits {
    my ($self, $c) = @_;
    
    my $commits = [];
    
    try {
        
        my $log_output = $self->_git($c, "log --oneline -10 2>&1");
        
        if ($? == 0 && $log_output) {
            my @lines = split /\n/, $log_output;
            for my $line (@lines) {
                if ($line =~ /^([a-f0-9]+)\s+(.+)$/) {
                    push @$commits, {
                        hash => $1,
                        message => $2
                    };
                }
            }
        }
        
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_recent_commits', 
            "Error getting recent commits: $_");
    };
    
    return $commits;
}

=head2 branch_management

Branch management interface for admins

=cut

sub branch_management :Path('/admin/branch_management') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'branch_management', 
        "Starting branch management interface");
    
    # Check admin access
    return unless $self->admin_auth->require_admin_access($c, 'branch_management');
    
    # Handle POST requests for branch operations
    if ($c->req->method eq 'POST') {
        my $action = $c->req->param('action');
        my $result = {};
        
        if ($action eq 'create_branch') {
            my $branch_name = $c->req->param('branch_name');
            my $source_branch = $c->req->param('source_branch') || 'main';
            $result = $self->create_branch($c, $branch_name, $source_branch);
        } elsif ($action eq 'delete_branch') {
            my $branch_name = $c->req->param('branch_name');
            $result = $self->delete_branch($c, $branch_name);
        } elsif ($action eq 'switch_branch') {
            my $branch_name = $c->req->param('branch_name');
            $result = $self->switch_branch($c, $branch_name);
        }
        
        # Store results in stash
        $c->stash(%$result) if $result;
    }
    
    # Get current branch and available branches
    my $current_branch = $self->get_current_branch($c);
    my $available_branches = $self->get_available_branches($c);
    my $local_branches = $self->get_local_branches($c);
    
    # Add information to stash
    $c->stash(
        current_branch => $current_branch,
        available_branches => $available_branches,
        local_branches => $local_branches
    );
    
    # Use the standard debug message system
    if ($c->session->{debug_mode}) {
        push @{$c->stash->{debug_msg}}, "Git controller branch_management view - Template: admin/branch_management.tt";
    }
    
    # Set the template
    $c->stash(template => 'admin/branch_management.tt');
}

=head2 get_local_branches

Get list of local Git branches

=cut

sub get_local_branches {
    my ($self, $c) = @_;
    
    try {
        
        my $branches_output = $self->_git($c, "branch --no-color 2>&1");
        my @branches = ();
        
        for my $line (split /\n/, $branches_output) {
            $line =~ s/^\s*\*?\s*//;  # remove asterisk and whitespace
            $line =~ s/^\s+|\s+$//g;  # trim whitespace
            $line =~ s/\x1b\[[0-9;]*m//g;  # remove ANSI color codes
            
            # Skip empty lines and detached HEAD states
            next if !$line || $line =~ /^\(.*\)$/;
            
            push @branches, $line;
        }
        
        return \@branches;
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_local_branches', 
            "Error getting local branches: $_");
        return [];
    };
}

=head2 create_branch

Create a new Git branch

=cut

sub create_branch {
    my ($self, $c, $branch_name, $source_branch) = @_;
    
    my $result = {
        success => 0,
        output => '',
        action => 'create_branch'
    };
    
    # Validate branch name
    if (!$branch_name || $branch_name !~ /^[a-zA-Z0-9_\-\/]+$/) {
        $result->{error_msg} = "Invalid branch name. Use only letters, numbers, underscores, hyphens, and forward slashes.";
        return $result;
    }
    
    $source_branch ||= 'main';
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_branch', 
        "Creating branch '$branch_name' from '$source_branch'");
    
    try {
        
        # First, fetch latest changes
        $result->{output} .= "Fetching latest changes...\n";
        my $fetch_output = $self->_git($c, "fetch origin 2>&1");
        $result->{output} .= $fetch_output;
        
        # Check if branch already exists locally
        my $local_check = $self->_git($c, "branch --list \"$branch_name\" 2>&1");
        if ($local_check) {
            $result->{error_msg} = "Branch '$branch_name' already exists locally.";
            return $result;
        }
        
        # Check if branch exists on remote
        my $remote_check = $self->_git($c, "branch -r --list \"origin/$branch_name\" 2>&1");
        if ($remote_check) {
            $result->{error_msg} = "Branch '$branch_name' already exists on remote.";
            return $result;
        }
        
        # Create and switch to new branch
        $result->{output} .= "Creating branch '$branch_name' from '$source_branch'...\n";
        my $create_output = $self->_git($c, "checkout -b \"$branch_name\" \"origin/$source_branch\" 2>&1");
        $result->{output} .= $create_output;
        
        if ($? != 0) {
            die "Failed to create branch '$branch_name'";
        }
        
        # Push the new branch to remote
        $result->{output} .= "Pushing new branch to remote...\n";
        my $push_output = $self->_git($c, "push -u origin \"$branch_name\" 2>&1");
        $result->{output} .= $push_output;
        
        if ($? != 0) {
            die "Failed to push branch '$branch_name' to remote";
        }
        
        $result->{success} = 1;
        $result->{success_msg} = "Branch '$branch_name' created successfully and pushed to remote.";
        
    } catch {
        my $error = $_;
        $result->{error_msg} = "Failed to create branch '$branch_name': $error";
        $result->{output} .= "\nError: $error";
    };
    
    return $result;
}

=head2 delete_branch

Delete a Git branch (both local and remote)

=cut

sub delete_branch {
    my ($self, $c, $branch_name) = @_;
    
    my $result = {
        success => 0,
        output => '',
        action => 'delete_branch'
    };
    
    # Validate branch name and prevent deletion of important branches
    if (!$branch_name) {
        $result->{error_msg} = "Branch name is required.";
        return $result;
    }
    
    if ($branch_name eq 'main' || $branch_name eq 'master' || $branch_name eq 'Production') {
        $result->{error_msg} = "Cannot delete protected branch '$branch_name'.";
        return $result;
    }
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'delete_branch', 
        "Deleting branch '$branch_name'");
    
    try {
        
        # Get current branch to ensure we're not deleting the current branch
        my $current_branch = $self->_git($c, "branch --show-current 2>&1");
        chomp($current_branch);
        
        if ($current_branch eq $branch_name) {
            # Switch to main before deleting
            $result->{output} .= "Switching to main branch before deletion...\n";
            my $checkout_output = $self->_git($c, "checkout main 2>&1");
            $result->{output} .= $checkout_output;
            
            if ($? != 0) {
                die "Failed to switch to main branch";
            }
        }
        
        # Delete local branch
        $result->{output} .= "Deleting local branch '$branch_name'...\n";
        my $delete_local = $self->_git($c, "branch -D \"$branch_name\" 2>&1");
        $result->{output} .= $delete_local;
        
        # Delete remote branch (don't fail if it doesn't exist)
        $result->{output} .= "Deleting remote branch '$branch_name'...\n";
        my $delete_remote = $self->_git($c, "push origin --delete \"$branch_name\" 2>&1");
        $result->{output} .= $delete_remote;
        
        $result->{success} = 1;
        $result->{success_msg} = "Branch '$branch_name' deleted successfully.";
        
    } catch {
        my $error = $_;
        $result->{error_msg} = "Failed to delete branch '$branch_name': $error";
        $result->{output} .= "\nError: $error";
    };
    
    return $result;
}

=head2 switch_branch

Switch to a different Git branch

=cut

sub switch_branch {
    my ($self, $c, $branch_name) = @_;
    
    my $result = {
        success => 0,
        output => '',
        action => 'switch_branch'
    };
    
    if (!$branch_name) {
        $result->{error_msg} = "Branch name is required.";
        return $result;
    }
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'switch_branch', 
        "Switching to branch '$branch_name'");
    
    try {
        
        # Fetch latest changes
        $result->{output} .= "Fetching latest changes...\n";
        my $fetch_output = $self->_git($c, "fetch origin 2>&1");
        $result->{output} .= $fetch_output;
        
        # Check if we have uncommitted changes
        my $status_output = $self->_git($c, "status --porcelain 2>&1");
        if ($status_output) {
            $result->{output} .= "Warning: You have uncommitted changes:\n$status_output\n";
            $result->{output} .= "Stashing changes before branch switch...\n";
            my $stash_output = $self->_git($c, "stash push -m \"Auto-stash before branch switch to $branch_name\" 2>&1");
            $result->{output} .= $stash_output;
        }
        
        # Switch to the branch
        $result->{output} .= "Switching to branch '$branch_name'...\n";
        my $checkout_output = $self->_git($c, "checkout \"$branch_name\" 2>&1");
        $result->{output} .= $checkout_output;
        
        if ($? != 0) {
            # Try to create local branch from remote if it doesn't exist locally
            $result->{output} .= "Local branch not found, creating from remote...\n";
            my $create_output = $self->_git($c, "checkout -b \"$branch_name\" \"origin/$branch_name\" 2>&1");
            $result->{output} .= $create_output;
            
            if ($? != 0) {
                die "Failed to switch to or create branch '$branch_name'";
            }
        }
        
        # Pull latest changes for the branch
        $result->{output} .= "Pulling latest changes for branch '$branch_name'...\n";
        my $pull_output = $self->_git($c, "pull origin \"$branch_name\" 2>&1");
        $result->{output} .= $pull_output;
        
        $result->{success} = 1;
        $result->{success_msg} = "Successfully switched to branch '$branch_name'.";
        
    } catch {
        my $error = $_;
        $result->{error_msg} = "Failed to switch to branch '$branch_name': $error";
        $result->{output} .= "\nError: $error";
    };
    
    return $result;
}

__PACKAGE__->meta->make_immutable;

1;

=head1 AUTHOR

Development Team

=head1 COPYRIGHT

Copyright (c) 2025 Computer System Consulting

=cut
