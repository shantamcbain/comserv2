package Comserv::Controller::Admin::Git;

use Moose;
use namespace::autoclean -except => [qw(try catch finally)];  # keep Try::Tiny subs (Perl 5.40)
use Comserv::Util::Logging;
use Comserv::Util::AdminAuth;
use Comserv::Util::BackupManager;
use Comserv::Util::Git;
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

# Returns the Git service (Comserv::Util::Git). All low-level git execution now
# lives there; controller methods are thin delegates (Phase C).
sub git_service {
    my ($self) = @_;
    $self->{_git_service} ||= Comserv::Util::Git->new(logging => $self->logging);
    return $self->{_git_service};
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

=head2 _bind_target

Read the dashboard "target" selector (param 'target') and stash it for the rest
of the request. Every git op in this controller then runs against that target:
local (this app host) or a remote host reached over SSH by the service layer.
Returns the resolved key (or '' for local).

=cut

sub _bind_target {
    my ($self, $c) = @_;
    my $t = $c->req->param('target');
    $t = '' unless defined $t;
    $c->stash->{git_target} = $t;
    return $t;
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

    # Honor the per-request target bound by _bind_target (dashboard selector).
    # For a remote target we delegate to the service's SSH runner so file paths
    # and messages are still passed as discrete argv elements (no shell).
    if (my $t = $c->stash->{git_target}) {
        my $tinfo = $self->git_service->resolve_target($c, $t);
        if ($tinfo->{mode} eq 'ssh') {
            my $r = $self->git_service->_ssh_exec_git($c, $tinfo, @argv);
            return ($r->{output}, $r->{exit_code});
        }
    }

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

    my $tkey = $c->stash->{git_target} // '';
    my $tinfo = $self->git_service->resolve_target($c, $tkey);
    my $is_remote = ($tinfo->{mode} eq 'ssh');

    my %known;       # path => tracked|untracked
    # Read the change set from the TARGET repo (local or remote-over-SSH). For a
    # remote target this queries the remote server, so the file list we validate
    # against is the right one for where the write will actually land.
    my ($porcelain) = $self->_git_list($c, 'status', '--porcelain');
    for my $line (split /\n/, $porcelain // '') {
        # format: XY <path>   (XY = two status chars, then a space)
        next unless $line =~ /^(..)\s(.+)$/;
        my ($xy, $file) = ($1, $2);
        # porcelain may quote paths with odd chars or show "old -> new" on renames
        $file =~ s/^"(.*)"$/$1/;
        $file = (split / -> /, $file)[-1] if $file =~ / -> /;
        $known{$file} = ($xy eq '??') ? 'untracked' : 'tracked';
    }

    my $repo = $tinfo->{repo};
    my (@valid, @invalid, %untracked);

    for my $p (@{ $paths || [] }) {
        next unless defined $p && length $p;

        if ($p =~ m{(?:^|/)\.\.(?:/|$)} || $p =~ m{^/}) {
            push @invalid, $p; next;   # traversal or absolute
        }
        unless (exists $known{$p}) {
            push @invalid, $p; next;   # not in the working-tree change set
        }
        # symlink-escape guard: real path must sit under the repo root. Only
        # possible to check for a LOCAL target (remote files aren't stat-able here).
        if (!$is_remote) {
            my $full = "$repo/$p";
            if (-l $full) {
                require Cwd;
                my $real = Cwd::abs_path($full);
                if (!$real || index($real, $repo) != 0) { push @invalid, $p; next; }
            }
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

    # Route every op below to the selected target (local or remote-over-SSH).
    $self->_bind_target($c);

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
    # 'commit' also accepts ticked paths (to auto-stage them) but, unlike the
    # others, an empty selection is valid — it commits whatever is already staged.
    my %requires_selection = map { $_ => 1 } qw(stage unstage delete gitignore stash);
    my $validated;
    if ($needs_paths{$op} || $op eq 'commit') {
        $validated = $self->_validate_paths($c, \@paths);
        if (@{ $validated->{invalid} }) {
            $c->flash->{error_msg} =
                "Rejected unsafe or unknown path(s): " . join(', ', @{ $validated->{invalid} });
            $c->response->redirect($c->uri_for('/admin/git'));
            return;
        }
        if ($requires_selection{$op} && !@{ $validated->{valid} }) {
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
            # Convenience: if files were ticked, stage them first so a single
            # "select + message + Commit" click works. Selected paths are already
            # validated against git status above. With nothing ticked, commit
            # whatever is already staged.
            if ($validated && @{ $validated->{valid} }) {
                # Only stage paths that still have an UNSTAGED working-tree change.
                # A path already in the index (e.g. a staged deletion shown as 'D  '
                # in porcelain) must NOT be passed to `git add` — `git add` on a
                # staged-deleted file errors with "pathspec did not match any files",
                # which aborts the whole commit. Such paths are already staged and will
                # be committed as-is.
                my %stage_needed;
                {
                    my ($porc) = $self->_git_list($c, 'status', '--porcelain');
                    for my $line (split /\n/, $porc // '') {
                        next unless $line =~ /^(..)\s(.+)$/;
                        my ($xy, $file) = ($1, $2);
                        $file = (split / -> /, $file)[-1] if $file =~ / -> /;
                        # untracked, or any unstaged change in column 2
                        $stage_needed{$file} = 1 if ($xy eq '??' || substr($xy, 1, 1) ne ' ');
                    }
                }
                my @to_add = grep { $stage_needed{$_} } @{ $validated->{valid} };
                if (@to_add) {
                    my ($aout, $acode) = $self->_git_list($c, 'add', '--', @to_add);
                    if ($acode != 0) {
                        $msg = "Stage-before-commit failed: $aout";
                        goto COMMIT_DONE;
                    }
                }
            }

            # Refuse early with a clear message when there is nothing staged,
            # instead of surfacing raw "nothing to commit" git output.
            my ($staged_out) = $self->_git_list($c, 'diff', '--cached', '--name-only');
            if (!length $staged_out) {
                $msg = 'Nothing staged to commit. Tick the file(s) you want, then Commit '
                     . '(or use Stage first).';
                goto COMMIT_DONE;
            }

            my ($out, $code) = $self->_git_list($c, 'commit', '-m', $message);
            $ok = ($code == 0);
            $msg = $ok ? "Committed staged changes." : "Commit failed: $out";
        }
        COMMIT_DONE:
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
    elsif ($op eq 'switch') {
        # Switch to a branch that exists in the local branch list. Name validated
        # against that list — never interpolated or free-form.
        my $target = $c->req->param('branch') // '';
        # 'git' is a reserved word (collides with the git command) and is excluded
        # from get_local_branches, but reject it explicitly so the message is clear.
        if ($target eq 'git') {
            $msg = "The branch name 'git' is reserved and cannot be switched to.";
        }
        else {
        my %known  = map { $_ => 1 } @{ $self->get_local_branches($c) };
        if (!$known{$target}) {
            $msg = "Unknown local branch: '$target'.";
        }
        elsif ($target eq $self->get_current_branch($c)) {
            $ok = 1;
            $msg = "Already on '$target'.";
        }
        else {
            my $r = $self->git_service->switch_branch($c, $target);
            $ok  = $r->{success};
            $msg = $r->{success} ? ($r->{success_msg} || "Switched to '$target'.")
                                 : ($r->{error_msg}   || "Switch to '$target' failed.");
        }
        }
    }
    elsif ($op eq 'delbranch') {
        # Delete a local branch from the branch card. Name validated against the
        # local list; the service refuses protected/current branches.
        my $target = $c->req->param('branch') // '';
        my %known  = map { $_ => 1 } @{ $self->get_local_branches($c) };
        if (!$known{$target}) {
            $msg = "Unknown local branch: '$target'.";
        }
        else {
            my $r = $self->git_service->delete_branch($c, $target);
            $ok  = $r->{success};
            $msg = $r->{success} ? ($r->{success_msg} || "Deleted '$target'.")
                                 : ($r->{error_msg}   || "Delete of '$target' failed.");
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
        # Drafting a message is READ-ONLY, so unknown/clean paths are not an error
        # here (unlike the write actions). Diff only the valid ones; if the selection
        # yields nothing (e.g. all selected files are already committed), fall through
        # to the staged / working-tree diff below.
        my $v = $self->_validate_paths($c, \@paths);
        if (@{ $v->{valid} }) {
            my ($out, $code) = $self->_git_list($c, 'diff', 'HEAD', '--', @{ $v->{valid} });
            if (length $out) {
                $diff  = $out;
                $scope = 'selected files: ' . join(', ', @{ $v->{valid} });
            }
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

    # An explicit model from the Git dashboard wins. The dropdown offers the
    # FULL catalog (Ollama + Grok + OpenRouter); the selected value is
    # "provider|model" (e.g. "openrouter|tencent/hy3"). If empty, the Router
    # falls back to the app-wide default (openrouter|tencent/hy3) unless no
    # external key is configured, in which case it uses local Ollama — so the
    # behavior is consistent with the chat widget and editor.
    my $requested_model = $c->req->param('model') || '';
    $requested_model = '' if $requested_model =~ /[\x00\r\n]/;

    # SINGLE dispatch brain — identical code path to the chat widget and the
    # Focus-Tune agent (Model::AI2::Router::dispatch_chat). No bespoke Ollama
    # branch here: local vs external is decided once, in the Router, so the Git
    # dashboard can never diverge from the rest of the app.
    my $router = try { $c->model('AI2::Router') } catch { undef };
    unless ($router && $router->can('dispatch_chat')) {
        $c->response->body(encode_json({ success => 0, error => 'AI router unavailable' }));
        return;
    }

    my $messages = [
        { role => 'system', content => 'You are a precise git commit message generator.' },
        { role => 'user',   content => $prompt },
    ];

    my $resp = try {
        $router->dispatch_chat($c,
            $requested_model,
            $messages,
            can_select => 1,
        );
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'suggest_commit_message', "AI dispatch threw: $_");
        undef;
    };

    unless ($resp && $resp->{success} && length($resp->{response} // '')) {
        $c->response->body(encode_json({
            success => 0,
            error   => ($resp && $resp->{error}) ? $resp->{error} : 'AI returned no message',
        }));
        return;
    }

    my $used_model = $resp->{model} // $requested_model // 'unknown';
    my $message = $resp->{response};
    $message =~ s/^\s+//; $message =~ s/\s+$//;
    # Strip any stray code fences the model may add despite instructions.
    $message =~ s/^```[a-zA-Z]*\n?//; $message =~ s/\n?```$//;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'suggest_commit_message',
        "Suggested commit message (" . length($message) . " chars) via $used_model");

    $c->response->body(encode_json({
        success => 1,
        message => $message,
        model   => $used_model,
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

    # Honor ?target= so a direct link or the selector opens on a given host.
    $self->_bind_target($c);
    my $target_key = $c->stash->{git_target} // '';

    my $status = $self->get_git_status($c);

    $c->stash(
        repo_path       => $self->repo_path($c),
        current_branch  => $self->get_current_branch($c),
        local_branches  => $self->get_local_branches($c),
        branch_details  => $self->git_service->get_branch_details($c),
        recent_commits  => $self->get_recent_commits($c),
        git_status      => $status,
        stash_list      => $self->get_git_stash_list($c),
        tracking        => $self->get_tracking_info($c),
        git_targets     => $self->git_service->list_targets($c),
        git_target      => $target_key,
        # Develop-server (zenflow worktree) registry — single source of truth via
        # Comserv::Util::Git->build_worktree_list (reads root/config/worktrees.json).
        # The Git dashboard's "Develop Servers" card reuses the same data the planning
        # tab's "Branch Servers" panel shows, so the two can never drift.
        worktree_list   => $self->git_service->build_worktree_list,
        template        => 'admin/git/index.tt',
    );

    if ($c->session->{debug_mode}) {
        push @{$c->stash->{debug_msg}}, "Git dashboard - Template: admin/git/index.tt";
        push @{$c->stash->{debug_msg}}, "Repo: " . ($self->repo_path($c) || 'unresolved');
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
        "Completed git dashboard");
}

=head2 file_diff

GET /admin/git/file_diff?path=<repo-relative path>
Read-only: return the unified diff of a single working-tree file vs HEAD so the
dashboard can show exactly what an AI edit changed. For untracked (new) files we
diff against /dev/null so the full new content shows as additions. Admin-gated.
The path is validated to stay inside the resolved repo root (no traversal).

=cut

sub file_diff :Path('/admin/git/file_diff') :Args(0) {
    my ($self, $c) = @_;

    return unless $self->admin_auth->require_admin_access($c, 'git_dashboard');

    my $rel = $c->req->param('path') || '';
    $c->res->content_type('application/json');

    unless (length $rel) {
        $c->res->status(400);
        $c->res->body(encode_json({ success => 0, error => 'path required' }));
        return;
    }

    # Normalise and confine to the repo root (block ../ traversal).
    $rel =~ s#\\#/#g;
    $rel =~ s#^\/+##;
    if ($rel =~ /\.\./) {
        $c->res->status(400);
        $c->res->body(encode_json({ success => 0, error => 'Invalid path' }));
        return;
    }

    my $git     = $self->git_service;
    my $repo    = $git->repo_path($c);
    my $abs     = File::Spec->catfile($repo, $rel);
    my $repo_re = quotemeta($repo);
    # resolved path must live inside the repo root
    unless ($abs =~ /^$repo_re/) {
        $c->res->status(400);
        $c->res->body(encode_json({ success => 0, error => 'Invalid path' }));
        return;
    }

    my $is_new = (!-e $abs) ? 1 : 0;
    my $r = $is_new
        ? $git->_run($c, 'diff', '--no-index', '/dev/null', $abs)
        : $git->_run($c, 'diff', 'HEAD', '--', $rel);

    # git diff exits 1 when there ARE differences (expected, not an error).
    if (!$r->{success} && !length($r->{output} // '')) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'file_diff',
            "diff failed for path=$rel is_new=$is_new : " . ($r->{error} || 'unknown') .
            " (git exit " . ($r->{exit_code} // -1) . ")");
        $c->res->status(500);
        $c->res->body(encode_json({ success => 0, error => $r->{error} || 'diff failed' }));
        return;
    }

    $c->res->body(encode_json({
        success => 1,
        path    => $rel,
        is_new  => $is_new ? 1 : 0,
        diff    => $r->{output} // '',
    }));
}

=head2 get_tracking_info

Ahead/behind counts against the upstream branch. Read-only; does not fetch.

Returns a hashref: upstream, ahead, behind. upstream is undef when the branch has no upstream.

=cut

sub get_tracking_info {
    my ($self, $c) = @_;
    return $self->git_service->get_tracking_info($c);
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
        
        # Default to THIS checkout's branch, never bare 'main'. A worktree
        # server cannot `git checkout main` — already used by the primary
        # (exit 128 + ERROR audit todo).
        my $selected_branch = $c->req->param('branch');
        if (!defined $selected_branch || $selected_branch !~ /\S/) {
            $selected_branch = $self->get_current_branch($c);
            $selected_branch = 'main' if !$selected_branch || $selected_branch eq 'unknown';
        }
        
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
    return $self->git_service->pull($c, $branch);
}

=head2 get_current_branch

Get the current Git branch

=cut

sub get_current_branch {
    my ($self, $c) = @_;
    return $self->git_service->get_current_branch($c);
}

=head2 get_available_branches

Get list of available Git branches

=cut

sub get_available_branches {
    my ($self, $c) = @_;
    return $self->git_service->get_available_branches($c);
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
        
        my $selected_branch = $c->req->param('branch');
        if (!defined $selected_branch || $selected_branch !~ /\S/) {
            $selected_branch = $self->get_current_branch($c);
            $selected_branch = 'main' if !$selected_branch || $selected_branch eq 'unknown';
        }
        
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
    my $result = { success => 0, output => '', message => $message };
    my $r = $self->git_service->stash_push($c, [], $message);
    $result->{output}  = $r->{output} . ($r->{error} // '');
    $result->{success} = $r->{success};
    if ($r->{success}) { $result->{success_msg} = "Changes stashed successfully with message: '$message'"; }
    else               { $result->{error_msg}   = "Stash operation failed: " . ($r->{error} || $r->{output}); }
    return $result;
}

=head2 execute_git_stash_pop

Execute git stash pop operation

=cut

sub execute_git_stash_pop {
    my ($self, $c, $stash_index) = @_;
    my $result = { success => 0, output => '', stash_index => $stash_index };
    my $r = $self->git_service->stash_pop($c, $stash_index);
    $result->{output}  = $r->{output} . ($r->{error} // '');
    $result->{success} = $r->{success};
    if ($r->{success}) { $result->{success_msg} = "Stash applied and removed successfully"; }
    else               { $result->{error_msg}   = "Stash pop operation failed: " . ($r->{error} || $r->{output}); }
    return $result;
}

=head2 execute_git_stash_drop

Execute git stash drop operation

=cut

sub execute_git_stash_drop {
    my ($self, $c, $stash_index) = @_;
    my $result = { success => 0, output => '', stash_index => $stash_index };
    my $r = $self->git_service->stash_drop($c, $stash_index);
    $result->{output}  = $r->{output} . ($r->{error} // '');
    $result->{success} = $r->{success};
    if ($r->{success}) { $result->{success_msg} = "Stash dropped successfully"; }
    else               { $result->{error_msg}   = "Stash drop operation failed: " . ($r->{error} || $r->{output}); }
    return $result;
}

=head2 get_git_stash_list

Get list of current git stashes

=cut

sub get_git_stash_list {
    my ($self, $c) = @_;
    return $self->git_service->get_git_stash_list($c);
}

=head2 get_git_status

Get current git status

=cut

sub get_git_status {
    my ($self, $c) = @_;
    return $self->git_service->get_git_status($c);
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
    my $result = { success => 0, output => '', files => $files };
    return $result unless $files && @$files;
    my $r = $self->git_service->stage($c, $files);
    $result->{output}  = $r->{output} . ($r->{error} // '');
    $result->{success} = $r->{success};
    if ($r->{success}) { $result->{success_msg} = "Files added to staging area successfully"; }
    else               { $result->{error_msg}   = "Git add operation failed: " . ($r->{error} || $r->{output}); }
    return $result;
}

=head2 execute_git_commit

Execute git commit operation

=cut

sub execute_git_commit {
    my ($self, $c, $message) = @_;
    my $result = { success => 0, output => '', message => $message };
    return $result unless $message;
    my $r = $self->git_service->commit($c, $message);
    $result->{output}  = $r->{output} . ($r->{error} // '');
    $result->{success} = $r->{success};
    if ($r->{success}) { $result->{success_msg} = "Commit created successfully"; }
    else               { $result->{error_msg}   = "Git commit operation failed: " . ($r->{error} || $r->{output}); }
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
    return $self->git_service->get_recent_commits($c, 10);
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
            # New Branch is one isolation action: create the git branch, add its
            # worktree, allocate/register its port, and return the launch command.
            $result = $self->git_service->create_worktree($c, $branch_name,
                { parent => $source_branch, label => $branch_name, url => '/planning/daily' });
            $self->logging->log_with_details($c, $result->{success} ? 'info' : 'error',
                __FILE__, __LINE__, 'create_worktree',
                "branch='" . ($branch_name // '') . "' parent='$source_branch' port="
                . ($result->{port} // '?')
                . ($result->{error} ? " error=$result->{error}" : ''));
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
    return $self->git_service->get_local_branches($c);
}

=head2 create_branch

Create a new Git branch

=cut

sub create_branch {
    my ($self, $c, $branch_name, $source_branch) = @_;
    return $self->git_service->create_branch($c, $branch_name, $source_branch);
}

=head2 delete_branch

Delete a Git branch (both local and remote)

=cut

sub delete_branch {
    my ($self, $c, $branch_name) = @_;
    return $self->git_service->delete_branch($c, $branch_name);
}

=head2 switch_branch

Switch to a different Git branch

=cut

sub switch_branch {
    my ($self, $c, $branch_name) = @_;
    return $self->git_service->switch_branch($c, $branch_name);
}

=head2 worktree_list

GET /admin/git/worktrees
List git worktrees (main repo + each zenflow branch checkout) with branch, port,
and ahead/behind counts vs main. Drives the human review picker.

=cut

sub worktree_list :Path('/admin/git/worktrees') :Args(0) {
    my ($self, $c) = @_;
    $c->response->content_type('application/json');
    return unless $self->admin_auth->require_admin_access($c, 'git_worktrees');

    my $wts = $self->git_service->list_worktrees($c) || [];
    my $main_branch = 'main';
    for my $wt (@$wts) {
        next if $wt->{is_main};
        # ahead/behind of this worktree's branch vs main
        my $r = $self->git_service->_run($c, 'rev-list', '--left-right', '--count',
            "$main_branch...$wt->{branch}");
        if ($r->{success} && $r->{output} =~ /^(\d+)\s+(\d+)/) {
            $wt->{ahead}  = $1 + 0;
            $wt->{behind} = $2 + 0;
        }
        else {
            $wt->{ahead} = $wt->{behind} = 0;
        }
    }
    $c->response->body(encode_json({ success => 1, worktrees => $wts }));
}

=head2 review_diff

GET /admin/git/review/:branch
Return the unified diff of :branch vs main (context=8) for the human review panel.
Read-only.

=cut

sub review_diff :Path('/admin/git/review') :Args(1) {
    my ($self, $c, $branch) = @_;
    $c->response->content_type('application/json');
    return unless $self->admin_auth->require_admin_access($c, 'git_review');

    $branch //= '';
    if (!$branch || $branch eq 'main') {
        $c->response->body(encode_json({ success => 0, error => 'Select a worktree branch to review.' }));
        return;
    }
    my $diff = $self->git_service->diff_against_main($c, $branch, 8);
    $c->response->body(encode_json({ success => 1, branch => $branch, diff => $diff }));
}

=head2 test_gate

GET /admin/git/test_gate/:branch
Read-only: run script/test_gate.sh against the worktree checkout for :branch
and report pass/fail. Never merges. Drives the editor's "Run Tests" button so
it can probe the gate without triggering a merge.

=cut

sub test_gate :Path('/admin/git/test_gate') :Args(1) {
    my ($self, $c, $branch) = @_;
    $c->response->content_type('application/json');
    return unless $self->admin_auth->require_admin_access($c, 'git_review');

    $branch //= '';
    if (!$branch || $branch eq 'main') {
        $c->response->body(encode_json({ success => 0, error => 'Select a worktree branch to test.' }));
        return;
    }

    my $res = $self->git_service->run_test_gate($c, $branch);
    $c->response->body(encode_json({
        success => $res->{success} ? 1 : 0,
        branch  => $branch,
        stale   => $res->{stale} ? 1 : 0,
        output  => $res->{output},
        error   => $res->{error_msg},
    }));
}

=head2 merge_to_main

POST /admin/git/merge_to_main
Human-gated: runs the worktree test gate, then merges :branch into main (--no-ff).
Refuses if tests fail or the branch is protected. On conflict, reports it.

=cut

sub merge_to_main :Path('/admin/git/merge_to_main') :Args(0) {
    my ($self, $c) = @_;
    $c->response->content_type('application/json');
    return unless $self->admin_auth->require_admin_access($c, 'git_merge');
    unless ($c->request->method eq 'POST') {
        $c->response->body(encode_json({ success => 0, error => 'POST required' }));
        return;
    }

    my $branch = $c->req->param('branch') // '';
    if (!$branch || $branch eq 'main') {
        $c->response->body(encode_json({ success => 0, error => 'A worktree branch is required.' }));
        return;
    }

    # Land the merge in the PRIMARY checkout (where main is checked out).
    # Never switch_branch('main') from a linked worktree — git refuses
    # ("already checked out at <primary>") and merging inside the worktree
    # is a no-op ("Already up to date"). main is already checked out in the
    # primary, so no branch switch is required or attempted.
    my $main_repo = $self->git_service->main_repo_path($c);
    unless ($main_repo) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'git_merge',
            'merge_to_main: could not resolve the primary repo (main checkout)');
        $c->response->body(encode_json({ success => 0, error => 'Could not resolve the primary repo (main checkout).' }));
        return;
    }

    my $gate = $self->git_service->run_test_gate($c, $branch, $main_repo);
    unless ($gate->{success}) {
        # Prefer the gate's own diagnostic (e.g. a stale worktree with no test
        # suite) over the generic "fix tests" message, which is misleading when
        # no test actually ran.
        my $msg = $gate->{error_msg}
            || "Test gate FAILED for '$branch' — merge blocked. Fix tests in the worktree first.";
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'git_merge',
            "merge_to_main: test gate FAILED for '$branch'");
        $c->response->body(encode_json({
            success => 0,
            stale   => $gate->{stale} ? 1 : 0,
            error   => $msg,
            detail  => $gate->{output},
        }));
        return;
    }

    my $res = $self->git_service->merge_branch($c, $branch, { repo => $main_repo });
    if ($res->{conflict}) {
        $c->response->body(encode_json({
            success  => 0,
            conflict => 1,
            error    => "Merge conflict in '$branch'. Resolve in the worktree, then retry (or abort).",
            output   => $res->{output},
        }));
        return;
    }
    $c->response->body(encode_json({
        success => $res->{success} ? 1 : 0,
        output  => $res->{output},
        error   => $res->{error_msg},
    }));
}

=head2 push_main

POST /admin/git/push_main
Human-driven push of main to origin (restores the deliberate GitHub push that
deploy.sh currently leaves disabled). Admin-only.

=cut

=head2 merge

POST /admin/git/merge (admin-gated git_merge)
General merge dispatcher for the dashboard Merge card. Params C<source> and
C<target> (one branch each). The server is the single source of truth for
direction safety:

  * Rejects source eq target.
  * main -> branch (source=main, target=branch):
      switch_branch(target), then merge_branch('main'). No test gate
      (we are updating a worktree, not main).
  * branch -> main (source=branch, target=main):
      - Guard: get_current_branch must eq source (the branch must be the
        active/checked-out one, mirroring PyCharm). Else error.
      - run_test_gate(source); block on failure.
      - switch to main (idempotent), then merge_branch(source).
  * On conflict -> { conflict=>1, output=>... } so the UI can offer Abort.
  * Returns { success, target, direction, conflict, error, output }.

All git goes through git_service (_run whitelist). Logged via log_with_details.

=cut

sub merge :Path('/admin/git/merge') :Args(0) {
    my ($self, $c) = @_;
    $c->response->content_type('application/json');
    return unless $self->admin_auth->require_admin_access($c, 'git_merge');
    unless ($c->request->method eq 'POST') {
        $c->response->body(encode_json({ success => 0, error => 'POST required' }));
        return;
    }

    my $source = $c->req->param('source') // '';
    my $target = $c->req->param('target') // '';

    unless ($source && $target) {
        $c->response->body(encode_json({ success => 0, error => 'Both source and target are required.' }));
        return;
    }
    if ($source eq $target) {
        $c->response->body(encode_json({ success => 0, error => 'Cannot merge a branch into itself.' }));
        return;
    }

    # The literal 'git' branch is reserved (collides with the command). The UI
    # should never offer it, but reject defensively — same guard as op=switch.
    if ($source eq 'git' || $target eq 'git') {
        $c->response->body(encode_json({ success => 0, error => "Branch 'git' is reserved and cannot be merged." }));
        return;
    }

    my $direction;
    my $res;

    # Both directions run INSIDE the branch's own worktree checkout:
    #   * A worktree branch is already checked out in its own worktree, so it
    #     cannot be checked out (switch_branch) in the main repo — git refuses
    #     ("already used by worktree"). The worktree checkout is already on the
    #     branch, so we run the merge there directly.
    #   * run_test_gate runs script/test_gate.sh in that same worktree, so the
    #     gate decision and the merge happen in the SAME tree (authoritative).
    my $wt_path = $self->git_service->worktree_checkout_path_for_branch($c, $target);

    if ($source eq 'main' && $target ne 'main') {
        $direction = 'main->branch';
        my $current = $self->get_current_branch($c) // '';
        # Prefer THIS checkout when we are already on the target (the 3d
        # worktree server). Do not require a worktree-list lookup, and never
        # treat the dropdown defaulting to main as the destination.
        my $dest = ($current eq $target)
            ? $self->git_service->repo_path($c)
            : $wt_path;
        unless (defined $dest && length $dest) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'git_merge',
                "main->branch: no checkout path for '$target'");
            $c->response->body(encode_json({
                success => 0,
                error   => "Branch '$target' is not checked out in any worktree; cannot merge main into it from the dashboard.",
            }));
            return;
        }
        my $fetch = $self->git_service->_run($c, 'fetch', 'origin', { repo => $dest });
        # --autostash: the worktree routinely has uncommitted WIP; a plain merge
        # refuses ("Your local changes would be overwritten"). Autostash stashes
        # the WIP, merges, then reapplies. If reapplying conflicts, git KEEPS the
        # stash entry (recoverable via the dashboard's Stash Pop) — nothing lost.
        my $up = $self->git_service->_run($c, 'merge', '--no-ff', '--autostash', 'main',
            { repo => $dest });
        my $combined = join("\n", grep { defined && length }
            $fetch->{output}, $fetch->{error}, $up->{output}, $up->{error});
        my $autostash_used = ($combined // '') =~ /Created autostash|Applied autostash/ ? 1 : 0;
        # WIP could not be reapplied cleanly: git saved it as stash@{0}. Surface
        # that distinctly so the user knows to recover via Stash Pop.
        my $autostash_conflict = ($combined // '') =~ /Cannot store stash|Please commit or stash|stash.*conflict/i
            && $autostash_used ? 1 : 0;
        $res = {
            success   => $up->{success} ? 1 : 0,
            output    => $combined,
            autostash => $autostash_used,
            autostash_conflict => $autostash_conflict,
            error_msg => $up->{success} ? undef : ($up->{error} || $up->{output} || 'merge failed'),
            conflict  => ($combined // '') =~ /CONFLICT|Automatic merge failed|overwritten by merge/ ? 1 : 0,
        };
    }
    elsif ($source ne 'main' && $target eq 'main') {
        # branch -> main: merge the worktree branch's work into the main repo.
        #   - Gate: run the worktree test suite (authoritative for this branch).
        #   - Then merge the branch ref into the main repo (which is on 'main').
        #     We merge the branch by NAME, which is visible from the main repo
        #     (refs/heads/<branch>), so no worktree checkout is needed here.
        $direction = 'branch->main';
        my $main_repo = $self->git_service->main_repo_path($c);
        unless ($main_repo) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'git_merge',
                "merge: could not resolve primary repo for '$source' -> main");
            $c->response->body(encode_json({
                success => 0,
                error   => 'Could not resolve the primary repo (main checkout).',
            }));
            return;
        }
        my $gate = $self->git_service->run_test_gate($c, $source, $main_repo);
        unless ($gate->{success}) {
            my $msg = $gate->{error_msg}
                || "Test gate FAILED for '$source' — merge blocked. Fix tests in the worktree first.";
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'git_merge',
                "test gate FAILED for '$source' — merge blocked");
            $c->response->body(encode_json({
                success => 0,
                stale   => $gate->{stale} ? 1 : 0,
                error   => $msg,
                detail  => $gate->{output},
            }));
            return;
        }
        my $mr = $self->git_service->merge_branch($c, $source, { repo => $main_repo });
        $res = {
            success   => $mr->{success} ? 1 : 0,
            output    => $mr->{output} // '',
            error_msg => $mr->{error_msg},
            conflict  => $mr->{conflict} ? 1 : 0,
        };
    }
    else {
        $c->response->body(encode_json({
            success => 0,
            error   => "Unsupported merge direction: source='$source', target='$target'.",
        }));
        return;
    }

    if ($res->{conflict}) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'git_merge',
            "merge conflict: direction=$direction source=$source target=$target");
        $c->response->body(encode_json({
            success  => 0,
            conflict => 1,
            target   => $target,
            direction => $direction,
            error    => "Merge conflict. Resolve in the worktree, then retry (or abort).",
            output   => $res->{output},
        }));
        return;
    }

    $self->logging->log_with_details($c, $res->{success} ? 'info' : 'error', __FILE__, __LINE__,
        'git_merge', "direction=$direction source=$source target=$target success=" . ($res->{success} // 0));

    $c->response->body(encode_json({
        success   => $res->{success} ? 1 : 0,
        target    => $target,
        direction => $direction,
        conflict  => 0,
        autostash => $res->{autostash} ? 1 : 0,
        autostash_conflict => $res->{autostash_conflict} ? 1 : 0,
        error     => $res->{error_msg},
        output    => $res->{output},
    }));
}

=head2 merge_abort

POST /admin/git/merge/abort (admin-gated git_merge)
Cancel a conflicted in-progress merge. Wraps git_service->merge_abort
(git merge --abort, flag already whitelisted in _run). Returns
{ success, output, error }.

=cut

sub merge_abort :Path('/admin/git/merge/abort') :Args(0) {
    my ($self, $c) = @_;
    $c->response->content_type('application/json');
    return unless $self->admin_auth->require_admin_access($c, 'git_merge');
    unless ($c->request->method eq 'POST') {
        $c->response->body(encode_json({ success => 0, error => 'POST required' }));
        return;
    }

    my $res = $self->git_service->merge_abort($c);
    $self->logging->log_with_details($c, $res->{success} ? 'info' : 'error', __FILE__, __LINE__,
        'git_merge_abort', "success=" . ($res->{success} // 0));

    $c->response->body(encode_json({
        success => $res->{success} ? 1 : 0,
        output  => $res->{output},
        error   => $res->{error_msg},
    }));
}

sub push_main :Path('/admin/git/push_main') :Args(0) {
    my ($self, $c) = @_;
    $c->response->content_type('application/json');
    return unless $self->admin_auth->require_admin_access($c, 'git_push');
    unless ($c->request->method eq 'POST') {
        $c->response->body(encode_json({ success => 0, error => 'POST required' }));
        return;
    }

    my $res = $self->git_service->push_main($c);
    $c->response->body(encode_json({
        success => $res->{success} ? 1 : 0,
        output  => $res->{output},
        error   => $res->{error_msg},
    }));
}

sub create_worktree :Path('/admin/git/create_worktree') :Args(0) {
    my ($self, $c) = @_;
    $c->response->content_type('application/json');
    return unless $self->admin_auth->require_admin_access($c, 'git_worktrees');
    unless ($c->request->method eq 'POST') {
        $c->response->body(encode_json({ success => 0, error => 'POST required' }));
        return;
    }

    my $p       = $c->req->params;
    my $branch  = $p->{branch}  // '';
    my $parent  = $p->{parent}  // 'main';
    my $label   = $p->{label}   // $branch;
    my $url     = $p->{url}     // '/planning/daily';

    unless ($branch) {
        $c->response->body(encode_json({ success => 0, error => 'branch is required' }));
        return;
    }

    my $res = $self->git_service->create_worktree($c, $branch,
        { parent => $parent, label => $label, url => $url });

    $self->logging->log_with_details($c, $res->{success} ? 'info' : 'error', __FILE__, __LINE__,
        'create_worktree', "branch='$branch' parent='$parent' port=" . ($res->{port} // '?') .
        ($res->{error} ? " error=$res->{error}" : ''));

    $c->response->body(encode_json({
        success => $res->{success} ? 1 : 0,
        branch  => $branch,
        port    => $res->{port},
        path    => $res->{path},
        cmd     => $res->{cmd},
        ($res->{error} ? (error => $res->{error}) : ()),
    }));
}

sub remove_worktree :Path('/admin/git/remove_worktree') :Args(0) {
    my ($self, $c) = @_;
    $c->response->content_type('application/json');
    return unless $self->admin_auth->require_admin_access($c, 'git_worktrees');
    unless ($c->request->method eq 'POST') {
        $c->response->body(encode_json({ success => 0, error => 'POST required' }));
        return;
    }

    my $p      = $c->req->params;
    my $branch = $p->{branch} // '';
    unless ($branch) {
        $c->response->body(encode_json({ success => 0, error => 'branch is required' }));
        return;
    }

    my $res = $self->git_service->remove_worktree($c, $branch);
    $self->logging->log_with_details($c, $res->{success} ? 'info' : 'error', __FILE__, __LINE__,
        'remove_worktree', "branch='$branch'" . ($res->{error} ? " error=$res->{error}" : ''));

    $c->response->body(encode_json({
        success => $res->{success} ? 1 : 0,
        branch  => $branch,
        ($res->{error} ? (error => $res->{error}) : ()),
    }));
}

__PACKAGE__->meta->make_immutable;

1;

=head1 AUTHOR

Development Team

=head1 COPYRIGHT

Copyright (c) 2025 Computer System Consulting

=cut
