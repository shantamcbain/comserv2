package Comserv::Controller::AI2;

use Moose;
use namespace::autoclean -except => [qw(try catch finally)];  # keep Try::Tiny subs (Perl 5.40)

use Try::Tiny;
use JSON;
use File::Spec;
use File::Path qw(make_path);
use Comserv::Util::EditorFile;
use DateTime;

use Comserv::Util::Logging;
use Comserv::Util::ModelCatalog;
use Comserv::Util::AdminAuth;

BEGIN { extends 'Catalyst::Controller' }

__PACKAGE__->config(namespace => 'ai2');

# ===================================================================
# AI2 Controller - Clean, thin HTTP layer
# All business logic delegated to Model::AI2::*
# ===================================================================

has 'logging' => (
    is      => 'ro',
    lazy    => 1,
    default => sub { Comserv::Util::Logging->instance },
);

# Thin index action example
sub index :Path :Args(0) {
    my ($self, $c) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
        'ai2_index', "AI2 interface accessed");

    $c->stash(
        template => 'ai/index.tt',  # reuse or create ai2/index.tt later
        page_title => 'AI Assistant (New)',
        # minimal stash - let Model provide data
    );
}

# Example thin models action
sub models :Local :Args(0) {
    my ($self, $c) = @_;

    my $models_data = $c->model('AI2')->get_available_models($c);

    $c->stash(
        template    => 'ai/models.tt',
        models_data => $models_data,
        page_title  => 'AI Models Management',
    );
}

# Add more thin actions as needed (chat, sync, etc.)

# JSON provider catalog for the chat widget. Returns the v1-compatible
# `providers` shape that local-chat.js consumes, sourced from the v2 Router
# (Ollama + Grok + OpenRouter + any keyed OpenAI-compatible service). This is
# what makes admin users see ALL available models in the chat dropdown.
sub providers :Local :Args(0) {
    my ($self, $c) = @_;

    my $roles = $c->session->{roles} || [];
    $roles = [split(/\s*,\s*/, $roles)] unless ref $roles;
    my $is_admin = grep { $_ =~ /^(admin|developer|editor)$/i } @$roles;

    my $catalog = try { $c->model('AI2')->get_available_models($c) } || [];

    # Group v2 catalog (each: name, provider, label, local) into providers[].
    my %by_service;
    for my $m (@$catalog) {
        # Defensive: the catalog is built from upstream provider JSON (Ollama
        # /api/tags, OpenRouter /v1/models). If a provider returns a malformed
        # entry (e.g. a bare string instead of an object), a single bad element
        # must NOT 500 the entire /ai2/providers endpoint for every user. Skip
        # it and log the offending element so the source can be fixed.
        if (ref $m ne 'HASH') {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
                'ai2_providers', "Skipping non-hash catalog element: "
                . (defined $m ? (ref $m ? ref($m) : "'$m'") : 'undef'));
            next;
        }
        my $svc = $m->{provider} || 'unknown';
        $by_service{$svc} ||= { service => $svc, models => [], name => ucfirst($svc) };
        # v2 Router carries { name, provider, label, local, price_prompt,
        # price_completion, pricing } for external models. Pass the pricing
        # through so JS surfaces (and ModelCatalog->prime, called below) can
        # show real per-token cost — otherwise the dropdown shows provider but
        # a blank fee (AIMPS-P1/#253 regression).
        push @{ $by_service{$svc}{models} }, {
            id              => $m->{name},
            label           => $m->{label},
            unreachable     => $m->{unreachable} ? 1 : 0,
            local           => $m->{local}     ? 1 : 0,
            price_prompt    => $m->{price_prompt}     // 0,
            price_completion=> $m->{price_completion} // 0,
            pricing         => $m->{pricing}         || {},
        };
    }

    my @providers = values %by_service;

    # Ollama gets a friendly name + active host hint for the admin switcher.
    for my $p (@providers) {
        if ($p->{service} eq 'ollama') {
            $p->{name}       = 'Ollama (Local AI)';
            $p->{active_host}= do {
                my ($h) = $c->model('AI2::Provider::Ollama')->resolve_host($c);
                $h;
            };
        }
        elsif ($p->{service} eq 'supergrok') {
            $p->{name} = 'SuperGrok (prepaid)';
        }
        elsif ($p->{service} eq 'grok') {
            $p->{name} = 'xAI (Grok)';
        }
    }

    # Prime the shared catalog cache from the catalog we just built, so every
    # other surface (Root auto -> stash -> ai/model_select.tt) reuses it instead
    # of hitting the provider APIs again. Single source of truth lives in
    # Comserv::Util::ModelCatalog.
    eval { Comserv::Util::ModelCatalog->prime($c, $catalog); };

    $c->res->content_type('application/json');
    $c->res->body(encode_json({
        success           => 1,
        providers         => \@providers,
        is_admin          => $is_admin ? 1 : 0,
        can_access_history=> $is_admin ? 1 : 0,
        is_guest          => 0,
        username          => $c->session->{username} || 'Guest',
    }));
}


# PyCharm-like AI Code Editor popup (new clean system)
sub editing_widget_popup :Local :Args(0) {
    my ($self, $c) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
        'ai2_editing_widget_popup', "AI2 code editor popup opened");

    my $router = eval { $c->model('AI2::Router') } || undef;

    my $selected_model = $router ? $router->select_best_model($c) : 'grok-beta';
    my $recommended_models = $router ? $router->get_recommended_models($c) : ['grok-beta','ollama/llama3','ollama/codellama'];
    my $branches = $router ? $router->get_available_branches($c) : ['main','ai2-refactor','feature/ai2-popup'];

    # Sort branches: current branch first, then alphabetically
    my $current_branch = 'main';
    @$branches = sort { $a eq $current_branch ? -1 : $b eq $current_branch ? 1 : $a cmp $b } @$branches;

    # Accept optional file path to load on open
    my $file_to_load = $c->req->param('file') || '';

    $c->stash(
        template            => 'ai2/editor/editing_widget_popup.tt',
        selected_model      => $selected_model,
        recommended_models  => $recommended_models,
        branches            => $branches,
        no_wrapper          => 1,
        ai_popup_mode       => 1,   # triggers conditional loading of ai2editor/*.js in js_load.tt
        show_ai2_editor     => 1,
        file_to_load        => $file_to_load,
    );
    # Catalyst will render the fragment into the dialog
}

# Right-side docked editor panels (PyCharm-style tool windows)
sub right_dock_panel   :Local :Args(0) { my ($self,$c)=@_; $c->stash(template=>'ai2/editor/right_dock_panel.tt',   no_wrapper=>1); }
sub right_dock_project :Local :Args(0) { my ($self,$c)=@_; $c->stash(template=>'ai2/editor/right_dock_project.tt', no_wrapper=>1); }
sub right_dock_commit  :Local :Args(0) { my ($self,$c)=@_; $c->stash(template=>'ai2/editor/right_dock_commit.tt',  no_wrapper=>1); }
sub right_dock_terminal:Local :Args(0) { my ($self,$c)=@_; $c->stash(template=>'ai2/editor/right_dock_terminal.tt',no_wrapper=>1); }
sub right_dock_settings:Local :Args(0) { my ($self,$c)=@_; $c->stash(template=>'ai2/editor/right_dock_settings.tt',no_wrapper=>1); }

# -------------------------------------------------------------------
# Secure file loading for the AI2 editor
# -------------------------------------------------------------------

# GET /ai2/load_file?path=...
sub load_file :Local :Args(0) {
    my ($self, $c) = @_;

    my $rel_path = $c->req->param('path') || '';
    my $ef       = Comserv::Util::EditorFile->new($c);
    my $result   = $ef->read_file($c, $rel_path);

    if ($result->{error}) {
        my $status = $result->{error} eq 'Forbidden' ? 403 : 404;
        $c->res->status($status);
        $c->res->body($result->{error});
        return;
    }

    $c->res->content_type('application/json');
    $c->res->body(encode_json($result));
}

# GET /ai2/file_checksum?path=...
sub file_checksum :Local :Args(0) {
    my ($self, $c) = @_;

    my $rel_path = $c->req->param('path') || '';
    my $root     = $c->path_to('');
    my $full     = $root->file($rel_path)->absolute;

    unless ($full =~ /^\Q$root\E/) {
        $c->res->status(403);
        $c->res->body('Forbidden');
        return;
    }
    unless (-e $full) {
        $c->res->status(404);
        $c->res->body('Not found');
        return;
    }

    my $mtime = (stat($full))[9];

    $c->res->content_type('application/json');
    $c->res->body(encode_json({
        path  => "$full",
        mtime => $mtime,
    }));
}

# -------------------------------------------------------------------
# Secure file saving for the AI2 editor
# -------------------------------------------------------------------

# POST /ai2/save_file
sub save_file :Local :Args(0) {
    my ($self, $c) = @_;

    $c->res->content_type('application/json');

    my $body;
    try {
        my $body_fh = $c->req->body;
        my $json_text = $body_fh ? do { local $/; <$body_fh> } : '';
        $body = decode_json($json_text || '{}');
    } catch {
        $c->res->status(400);
        $c->res->body(encode_json({ success => 0, error => 'Invalid JSON' }));
        return;
    };

    my $rel_path = $body->{path} || '';
    my $content  = $body->{content};

    my $ef     = Comserv::Util::EditorFile->new($c);
    my $result = $ef->write_file($c, $rel_path, $content);

    if ($result->{success}) {
        $c->res->body(encode_json($result));
    } else {
        my $status = $result->{error} eq 'Forbidden' ? 403
                   : $result->{error} eq 'Syntax error' ? 422
                   : $result->{error} eq 'No content provided' ? 400
                   : 500;
        $c->res->status($status);
        $c->res->body(encode_json($result));
    }
}

# -------------------------------------------------------------------
# Git diff for the AI2 editor
#
# Lets the code editor show the working-tree diff (vs HEAD) of the file
# currently open/modified, and a parsed change-set so the file tree can be
# badged (M / U). Reuses Comserv::Util::Git so it inherits the same repo
# resolution and argv whitelisting. Auth mirrors the rest of AI2: a logged-in
# user with an editor/admin/developer role.
# -------------------------------------------------------------------

sub _ai2_require_editor_role {
    my ($self, $c) = @_;
    return 1 if $c->session->{username}
        && grep { $_ =~ /^(admin|developer|editor)$/i }
               (ref($c->session->{roles}) ? @{$c->session->{roles}}
                : split(/\s*,\s*/, $c->session->{roles} || ''));
    $c->res->status(403);
    $c->res->content_type('application/json');
    $c->res->body(encode_json({ success => 0, error => 'Editor access required' }));
    return 0;
}

# Map an app-relative editor path (rooted at the Catalyst app dir) to the
# path git sees (rooted at the repo root, typically one level up). We do this
# by resolving both to absolute paths and stripping the repo-root prefix, so
# it is correct regardless of which subdir the file lives in.
# Map an app-relative editor path (rooted at the Catalyst app dir) to the
# path git sees. CRITICAL: the git repo root is resolved by the SAME
# Util::Git->repo_path() that the git _run uses (config git_repo_path /
# $ENV{COMSERV_GIT_REPO} / path_to('..')). In some deployments the repo root
# IS the app dir (Comserv/), not one level up -- so we must strip that actual
# repo root, never a hardcoded path_to('..'). Absolute paths are also accepted.
# Map an app-relative editor path (rooted at the Catalyst app dir) to the
# path git sees. The diff is run with `git -C $repo` (Util::Git->_run), and
# $repo may point at a subdir of the real repository (e.g. Comserv/ while the
# actual .git lives one level up at comserv2/). git interprets a relative diff
# path against the REPO TOPLEVEL, not against $repo, so we must strip the true
# toplevel prefix -- resolved live via `git rev-parse --show-toplevel` (with a
# repo_path() fallback). Absolute paths are also accepted.
# Map an app-relative editor path (as the frontend sends it) to the path
# git expects. We deliberately do NOT hardcode any app/repo directory: everything
# is derived from the running process and from git itself, so this works under
# any deployment (Zenflow-style workflow, Docker, monorepo, app-dir repo, etc.).
#
#   * The app directory is wherever THIS code runs (Catalyst path_to(''), made
#     absolute via Cwd) -- never a literal string.
#   * git is run from repo_path() (Util::Git->_run already does `git -C <repo>`).
#   * git tells us how to express a path relative to the repo root via
#     `git rev-parse --show-prefix` (e.g. "Comserv/" when the app dir is a
#     subdir of the repo, or "" when the app dir IS the repo). So the
#     toplevel-relative path = show-prefix + app-relative path. No string math
#     on "Comserv"/"comserv2" that could double up.
sub _ai2_repo_rel_path {
    my ($self, $c, $rel_path) = @_;
    require Cwd;
    require File::Spec;
    my $app_dir = Cwd::abs_path($c->path_to('')->stringify) || $c->path_to('')->absolute->stringify;
    $app_dir = File::Spec->canonpath($app_dir);

    my $git = Comserv::Util::Git->new(logging => $self->logging);

    # The directory git actually runs in (Util::Git->_run does `git -C <repo>`).
    my $repo_root = $git->repo_path($c);
    $repo_root = $c->path_to('..')->absolute->stringify unless $repo_root;
    $repo_root = File::Spec->canonpath(Cwd::abs_path($repo_root) || $repo_root);

    # The path git wants is relative to $repo_root. Compute it as the relative
    # path from $repo_root down to the app dir (e.g. "Comserv/"), joined with the
    # app-relative file path. This is deployment-agnostic: it does not depend on
    # git's current working directory or any hardcoded string, so it works for a
    # Zenflow/Docker/monorepo layout as well as an app-dir repo.
    my $prefix = '';
    eval {
        my $rel = File::Spec->abs2rel($app_dir, $repo_root);
        $rel =~ s#\\#/#g;
        if (length $rel && $rel ne '.') {
            $prefix = $rel;
            $prefix .= '/' unless $prefix =~ m#/$#;
        }
    };

    # Normalise the incoming path. The frontend usually sends an app-relative
    # path, but it may also send an absolute path (e.g. the full repo path) or
    # one carrying a "Comserv/" repo-subdir prefix. Strip a leading slash, a
    # leading "Comserv/" prefix, AND any leading absolute prefix that equals the
    # resolved repo root or app dir so the result is always repo-relative. This
    # prevents the doubled-path bug (app_dir + absolute path => ".../Comserv/../home/.../Comserv/...").
    my $p = $rel_path;
    $p =~ s#\\#/#g;
    $p =~ s#^/+##;
    $p =~ s#^Comserv/##;
    for my $base ($app_dir, $repo_root) {
        my $qb = quotemeta($base);
        $p =~ s#^$qb/?##;
    }
    $p =~ s#^/+##;

    my $repo_rel = $prefix . $p;
    $repo_rel =~ s#^/+##;
    return $repo_rel;
}

# GET /ai2/git_status
# Returns parsed working-tree status so the editor can badge changed files.
sub git_status :Local :Args(0) {
    my ($self, $c) = @_;
    $c->res->content_type('application/json');
    return unless $self->_ai2_require_editor_role($c);

    my $git = Comserv::Util::Git->new(logging => $self->logging);
    my $st  = $git->get_git_status($c);

    $c->res->body(encode_json({
        success          => 1,
        has_changes      => $st->{has_changes} ? 1 : 0,
        staged_files     => $st->{staged_files}    // [],
        modified_files   => $st->{modified_files}  // [],
        untracked_files  => $st->{untracked_files} // [],
    }));
}

# GET /ai2/file_diff?path=<app-relative editor path>
# Returns the unified diff of that file vs HEAD. For untracked (new) files we
# diff against /dev/null so the full new content shows as additions.
sub file_diff :Local :Args(0) {
    my ($self, $c) = @_;
    $c->res->content_type('application/json');
    return unless $self->_ai2_require_editor_role($c);

    my $rel_path = $c->req->param('path') || '';
    unless (length $rel_path) {
        $c->res->status(400);
        $c->res->body(encode_json({ success => 0, error => 'path required' }));
        return;
    }

    my $repo_rel = $self->_ai2_repo_rel_path($c, $rel_path);
    unless (defined $repo_rel) {
        $c->res->status(400);
        $c->res->body(encode_json({ success => 0, error => 'Invalid path' }));
        return;
    }

    my $git  = Comserv::Util::Git->new(logging => $self->logging);

    # Resolve the REAL on-disk location of the file WITHOUT any hardcoded path.
    # The frontend sends an app-relative editor path (it may already include a
    # "Comserv/" prefix or the repo root, and may even be absolute). Blindly
    # catfile()'ing it onto $app_dir double-appends the repo/app dir and produces
    # a bogus path like "Comserv/../home/.../Comserv/Comserv/..." (observed in the
    # error audit). Instead derive the on-disk path from the SAME repo_rel that
    # git itself uses (computed above via _ai2_repo_rel_path) joined to the
    # resolved git repo root, then confine it to that root to block traversal.
    my $repo_root = $git->repo_path($c);
    $repo_root = $c->path_to('..')->absolute->stringify unless $repo_root;
    $repo_root = File::Spec->canonpath(Cwd::abs_path($repo_root) || $repo_root);
    my $abs = File::Spec->canonpath(File::Spec->catfile($repo_root, $repo_rel));
    my $repo_re = quotemeta($repo_root);
    unless ($abs =~ /^$repo_re/) {
        $c->res->status(400);
        $c->res->body(encode_json({ success => 0, error => 'Invalid path' }));
        return;
    }

    # "New" means git does not track it (untracked) — not merely "not found
    # under the configured repo path". Use ls-files so the tracked-vs-new
    # decision matches what git diff will actually show.
    my $tracked = $git->_run($c, 'ls-files', '--error-unmatch', '--', $repo_rel);
    my $is_new = ($tracked && $tracked->{success}) ? 0 : 1;

    # git diff exits 1 when there ARE differences (expected, not an error), so
    # we treat "exit != 0 but produced output" as success. For untracked (new)
    # files diff against /dev/null so the full new content shows as additions.
    my $r = $is_new
        ? $git->_run($c, 'diff', '--no-index', '/dev/null', $abs)
        : $git->_run($c, 'diff', 'HEAD', '--', $repo_rel);

    if (!$r->{success} && !length($r->{output} // '')) {
        $c->res->status(500);
        $c->res->body(encode_json({ success => 0, error => $r->{error} || 'diff failed' }));
        return;
    }

    $c->res->body(encode_json({
        success  => 1,
        path     => $rel_path,
        is_new   => $is_new ? 1 : 0,
        diff     => $r->{output} // '',
    }));
}

# GET /ai2/file_tree
# Returns the full project file tree (rooted at the app dir, $c->path_to(''))
# as a nested structure so the editor Project panel can render every file,
# with changed files surfaced at the top by the frontend (via /ai2/git_status).
# Editor/admin/developer role, same guard as the rest of AI2. No shell, no
# chdir — pure readdir recursion, path-confined to the project root.
sub file_tree :Local :Args(0) {
    my ($self, $c) = @_;
    $c->res->content_type('application/json');
    return unless $self->_ai2_require_editor_role($c);

    my $root = $c->path_to('')->absolute->stringify;

    # Directories that are never part of the editable source tree.
    my %SKIP_DIR = map { $_ => 1 } qw(
        .git node_modules blib .hermes logs tmp
        static/vendor static/js/vendor vendor
    );

    my @tree;

    my $walk;
    $walk = sub {
        my ($abs_dir, $rel_dir, $into) = @_;
        opendir(my $dh, $abs_dir) or return;
        my @entries = grep { $_ ne '.' && $_ ne '..' } readdir($dh);
        closedir($dh);

        my (@dirs, @files);
        for my $name (sort @entries) {
            my $abs = File::Spec->catfile($abs_dir, $name);
            my $rel = length($rel_dir) ? "$rel_dir/$name" : $name;
            if (-d $abs) {
                next if $SKIP_DIR{$name} || $SKIP_DIR{$rel};
                push @dirs, { type => 'dir', name => $name, path => $rel, children => [] };
            } elsif (-f $abs) {
                # Skip backup files, swap, and editor temp artifacts.
                next if $name =~ /\.(bak|swp|tmp)$/;
                push @files, { type => 'file', name => $name, path => $rel };
            }
        }
        # Dirs first (so the tree reads like a real explorer), then files.
        for my $d (@dirs) {
            my $child_abs = File::Spec->catfile($abs_dir, $d->{name});
            $walk->($child_abs, $d->{path}, $d->{children});
            push @$into, $d;
        }
        push @$into, @files;
    };

    $walk->($root, '', \@tree);

    $c->res->body(encode_json({
        success => 1,
        root    => $root,
        tree    => \@tree,
    }));
}

# -------------------------------------------------------------------
# Diagnostic / test surface for the v2 AI system.
#
# These exist so the system can be inspected and exercised WITHOUT a browser
# login — the AI tester logs in via /ai2/token-login (acting as the real
# user) and then calls /ai2/diagnostics and /ai2/test_model to see
# exactly what the user would see. No app restart required (Starman -r
# reloads .pm on save).
# -------------------------------------------------------------------

# Resolve the path to the application event log (Util::Logging writes here).
sub _app_log_file {
    my ($self, $c) = @_;
    my $dir = $ENV{'COMSERV_LOG_DIR'}
        || File::Spec->catdir($c->path_to('')->stringify, 'logs');
    return File::Spec->catfile($dir, 'application.log');
}

# GET /ai2/diagnostics — live "what is the system doing" snapshot.
# Auth: any logged-in user may read their own view; admins see key state.
sub diagnostics :Local :Args(0) {
    my ($self, $c) = @_;

    $c->res->content_type('application/json');

    unless ($c->session->{username}) {
        $c->res->status(401);
        $c->res->body(encode_json({ success => 0, error => 'Authentication required' }));
        return;
    }

    my $is_admin = grep { $_ =~ /^(admin|developer|editor)$/i }
        (ref($c->session->{roles}) ? @{$c->session->{roles}}
         : split(/\s*,\s*/, $c->session->{roles} || ''));

    my %diag;

    # --- Ollama: live model tags from the configured host ---
    try {
        my $ollama = $c->model('AI2::Provider::Ollama');
        my ($host, $port) = $ollama->resolve_host($c);
        my $ua   = LWP::UserAgent->new(timeout => 5);
        my $res  = $ua->get("http://$host:$port/api/tags");
        if ($res && $res->is_success) {
            my $d = eval { decode_json($res->decoded_content) };
            $diag{ollama} = {
                host        => $host,
                port        => $port,
                reachable   => 1,
                model_count => $d && $d->{models} ? scalar(@{$d->{models}}) : 0,
                models      => [ map { $_->{name} } @{$d->{models} || []} ],
            };
        } else {
            $diag{ollama} = { host => $host, port => $port, reachable => 0 };
        }
    } catch {
        $diag{ollama} = { error => "probe failed: $_" };
    };

    # --- Provider key state (admin only — never expose keys) ---
    if ($is_admin) {
        my %keys;
        for my $svc (qw(grok openrouter)) {
            my $cls = $svc eq 'grok' ? 'AI2::Provider::Grok'
                                         : 'AI2::Provider::OpenRouter';
            my $prov = try { $c->model($cls) } catch { undef };
            my $has  = try { $prov && $prov->can('_resolve_api_key')
                                  && $prov->_resolve_api_key($c) } catch { undef };
            $keys{$svc} = $has ? 1 : 0;
        }
        $diag{provider_keys} = \%keys;
    }

    # --- Router context preferences (what the brain prefers per role) ---
    try {
        my $router = $c->model('AI2::Router');
        $diag{router} = {
            context_prefs => $router->context_prefs,
            hardcoded_fallback => 'phi4:14b',
        };
    } catch {
        $diag{router} = { error => "unavailable: $_" };
    };

    # --- v2 catalog the widget would actually show (as this user) ---
    try {
        $diag{catalog} = $c->model('AI2')->get_available_models($c);
    } catch {
        $diag{catalog} = { error => "unavailable: $_" };
    };

    # --- Recent application.log lines (tail) ---
    try {
        my $log = $self->_app_log_file($c);
        my @lines;
        if (-f $log) {
            open my $fh, '<', $log or die "open $log: $!";
            my @all = <$fh>;
            close $fh;
            my @tail = @all > 40 ? @all[-40 .. $#all] : @all;
            @lines = map { s/^\s+|\s+$//gr } @tail;
        }
        $diag{recent_log} = \@lines;
    } catch {
        $diag{recent_log} = [ "log read failed: $_" ];
    };

    $diag{auth} = {
        username  => $c->session->{username},
        is_admin  => $is_admin ? 1 : 0,
        roles     => $c->session->{roles},
    };

    # --- Persist the snapshot so it can be reviewed later (the
    # "translation" of live system state, not lost in a terminal). ---
    try {
        my $dir = File::Spec->catdir($c->path_to('')->stringify, 'logs', 'ai2_diagnostics');
        make_path($dir) unless -d $dir;
        my $stamp = DateTime->now->ymd . '-' . do { my @t = localtime; sprintf '%02d%02d%02d', $t[2], $t[1], $t[0] };
        my $who = $c->session->{username} || 'guest';
        $who =~ s/[^A-Za-z0-9_.-]/_/g;
        my $out = File::Spec->catfile($dir, "$stamp-$who.json");
        if (open my $ofh, '>', $out) {
            print $ofh encode_json({ %diag });
            close $ofh;
            $diag{saved_snapshot} = "logs/ai2_diagnostics/" . "$stamp-$who.json";
        }
    } catch {
        $diag{saved_snapshot} = "save failed: $_";
    };

    $c->res->body(encode_json({ success => 1, diagnostics => \%diag }));
}

# GET /ai2/test_model?provider=ollama&model=phi4:14b — self-test a
# provider/model the way the user would, returning the raw model reply.
# Auth: any logged-in user (admin for external providers).
sub test_model :Local :Args(0) {
    my ($self, $c) = @_;

    $c->res->content_type('application/json');

    unless ($c->session->{username}) {
        $c->res->status(401);
        $c->res->body(encode_json({ success => 0, error => 'Authentication required' }));
        return;
    }

    my $provider = $c->req->param('provider') || 'ollama';
    my $model    = $c->req->param('model')    || '';
    unless ($model) {
        $c->res->status(400);
        $c->res->body(encode_json({ success => 0, error => 'model parameter required' }));
        return;
    }

    # External providers require admin key resolution.
    my $is_admin = grep { $_ =~ /^(admin|developer|editor)$/i }
        (ref($c->session->{roles}) ? @{$c->session->{roles}}
         : split(/\s*,\s*/, $c->session->{roles} || ''));
    if ($provider ne 'ollama' && !$is_admin) {
        $c->res->status(403);
        $c->res->body(encode_json({ success => 0, error => 'Admin role required for external provider test' }));
        return;
    }

    my $result = try {
        my $dispatch = {
            ollama     => 'AI2::Provider::Ollama',
            grok       => 'AI2::Provider::Grok',
            openrouter => 'AI2::Provider::OpenRouter',
            external   => 'AI2::Provider::OpenRouter',
        };
        my $cls = $dispatch->{$provider} || 'AI2::Provider::Ollama';
        my $prov = $c->model($cls);
        unless ($prov && $prov->can('chat')) {
            die "No chat client for provider $provider";
        }
        my ($host, $port) = $prov->can('resolve_host')
            ? $prov->resolve_host($c)
            : ($c->config->{Ollama}{host} || '192.168.1.199',
               $c->config->{Ollama}{port} || 11434);
        $prov->chat($c,
            messages => [{ role => 'user',
                content => "Reply with exactly the word PONG to confirm you are working." }],
            model    => $model,
            host     => $host,
            port     => $port,
        );
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'ai2_test_model', "test failed: $_");
        { success => 0, error => "Test threw: $_" };
    };

    $result //= { success => 0, error => 'No response' };
    $c->res->body(encode_json({
        success  => $result->{success} ? 1 : 0,
        provider => $provider,
        model    => $result->{model} || $model,
        response => $result->{response} // '',
        error    => $result->{error},
    }));
}

# POST /ai2/token-login — agent/test harness login.
#
# Mirrors the existing /api/* Bearer-token model: an admin generates a
# token (here, via the same ApiToken table), and this endpoint exchanges a
# token for a real authenticated Catalyst session — so a CLI/agent can act
# as the user and see exactly what the user would see (the v2 catalog,
# chat, diagnostics). Local + token only; never a browser login.
sub token_login :Local :Args(0) {
    my ($self, $c) = @_;

    $c->res->content_type('application/json');

    unless ($c->request->method eq 'POST') {
        $c->res->status(405);
        $c->res->body(encode_json({ success => 0, error => 'Method not allowed' }));
        return;
    }

    my $body = {};
    try {
        if ($c->req->can('data') && ref($c->req->data) eq 'HASH') {
            $body = $c->req->data;
        } elsif (my $raw = $c->req->body) {
            $body = decode_json($raw) if length($raw);
        }
    } catch { };
    $body = {} unless ref($body) eq 'HASH';

    # Accept the token from JSON body, form params, OR query string so the
    # endpoint is testable without fighting Catalyst's POST-body buffering.
    my $token = $body->{token}
             || $c->req->param('token')
             || $c->req->query_params->{token}
             || '';
    unless ($token) {
        $c->res->status(400);
        $c->res->body(encode_json({ success => 0, error => 'token required' }));
        return;
    }

    my $validation = Comserv::Util::ApiTokenValidator->validate_token($c, $token);
    unless ($validation->{valid}) {
        $c->res->status(401);
        $c->res->body(encode_json({ success => 0, error => $validation->{error} || 'Invalid token' }));
        return;
    }

    my $schema = try { $c->model('DBEncy')->schema } catch { undef };
    my $user   = $schema && $schema->resultset('User')->find($validation->{user_id});
    unless ($user) {
        $c->res->status(401);
        $c->res->body(encode_json({ success => 0, error => 'Token user not found' }));
        return;
    }

    # Establish the real Catalyst session exactly as User.pm login does.
    $c->session->{user_id}  = $user->id;
    $c->session->{username} = $user->username;
    $c->session->{roles}    = $user->roles || 'user';
    $c->session->{SiteName} = $user->sitename if $user->can('sitename') && $user->sitename;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
        'ai2_token_login', "Agent session established for user " . $user->username);

    $c->res->body(encode_json({
        success  => 1,
        user_id  => $user->id,
        username => $user->username,
        roles    => $user->roles,
        message  => 'Session established. Subsequent /ai2/* calls act as this user.',
    }));
}

# -------------------------------------------------------------------
# Main chat endpoint (v2). Mirrors the v1 /ai/chat request/response
# contract so local-chat.js needs no other changes — just point
# config.apiEndpoints.generateResponse at /ai2/chat. Routing of
# provider+model is delegated to Model::AI2::Router (openrouter/grok/
# ollama all handled), so any model in the dropdown works.
# -------------------------------------------------------------------
sub chat :Local :Args(0) {
    my ($self, $c) = @_;

    $c->response->content_type('application/json');

    my $username = $c->session->{username} || 'Guest';
    my $user_id  = $c->session->{user_id};

    # Parse JSON body (mirrors v1 parsing)
    my $json_data = {};
    my $content_type = $c->request->content_type || '';
    if ($content_type =~ /application\/json/i) {
        try {
            my $raw = $c->req->can('content') ? $c->req->content : $c->request->body;
            $raw = do { local $/; <$raw> } if ref($raw);
            $json_data = decode_json($raw) if $raw && length($raw);
        } catch {
            $c->res->body(encode_json({ success => 0, error => 'Invalid JSON' }));
            return;
        };
    }
    $json_data //= {};

    my $prompt  = $json_data->{prompt} // '';
    my $model   = $json_data->{model}  // '';
    my $history = $json_data->{history} // [];
    my $agent_id= $json_data->{agent_id} // '';
    my $system  = $json_data->{system} // '';
    my $page_path   = $json_data->{page_path} // '';
    my $page_title  = $json_data->{page_title} // '';
    my $page_content= $json_data->{page_content} // '';
    my $use_search  = $json_data->{use_search} ? 1 : 0;
    my $conversation_id = $json_data->{conversation_id};
    my $project_id = $json_data->{project_id};
    my $task_id    = $json_data->{task_id};
    # Voice recording linkage: when the prompt is a voice transcript, the widget
    # sends the File-table ids from /ai2/transcribe so the saved conversation
    # message can be attached to its audio + transcript files.
    my $audio_file_id      = $json_data->{audio_file_id};
    my $transcript_file_id = $json_data->{transcript_file_id};

    # The dropdown sends "provider|model" (e.g. openrouter|anthropic/...,
    # grok|grok-4..., ollama|llama3...). Extract the real model name.
    if ($model && $model =~ /^\s*([^|]+)\|(.+?)\s*$/) {
        $model = $2;
    }

    unless ($prompt && length($prompt) > 0) {
        $c->res->body(encode_json({ success => 0, error => 'Prompt is required' }));
        return;
    }

    # ── Create-todo intent: do this BEFORE the LLM. Free/small models invent
    # a fake "Add" box instead of emitting [ACTION: create_todo]. One brain:
    # Model::AI2::TodoCreate (same as /ai2/action and the 📝 button).
    # Use ->new not $c->model: a newly added Model::* is not in Catalyst's
    # component registry until the next process start (we must not restart).
    my $todo_hit = eval {
        require Comserv::Model::AI2::TodoCreate;
        my $brain = eval { $c->model('AI2::TodoCreate') };
        $brain = Comserv::Model::AI2::TodoCreate->new if !$brain || !ref $brain;
        $brain->try_chat_create($c,
            prompt    => $prompt,
            page_path => $page_path,
        );
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'ai2_chat', "TodoCreate try_chat_create threw: $@");
    }
    if ($todo_hit && $todo_hit->{handled}) {
        $c->res->body(encode_json({
            success         => $todo_hit->{success} ? 1 : 0,
            response        => $todo_hit->{response} // '',
            model           => $todo_hit->{model} // '(todo-create)',
            provider        => $todo_hit->{provider} // 'ai2-todo',
            needs_web_search=> 0,
            error           => $todo_hit->{error},
            todo_action     => $todo_hit->{todo_action},
            conversation_id => $conversation_id,
            thinking        => [],
        }));
        return;
    }

    # ── Focus-Tune agent: "what are my top 5 todos by function?" ──
    # Delegates to Model::AI2::FocusTune (the SAME brain the /api/focus/top5
    # UI button uses) so the question is answerable from Chat-with-AI too.
    # Triggered by the 'focustune' agent_id OR a natural-language intent.
    my $is_focus = (lc($agent_id) eq 'focustune')
        || ($prompt =~ /\b(top\s*5|top five|most important|should i (do|work on|tackle)|what (todo|todos) (should|to) i|priorit)/i
            && $prompt =~ /\b(todo|todos|task|tasks|plan|next step|next steps|build)\b/i);
    if ($is_focus) {
        my $tune = $c->model('AI2::FocusTune');
        my $now_epoch = time();
        my ($top, $rbid) = $tune->gather_candidates($c, $now_epoch);
        my @plan_docs = $tune->plan_docs($c);
        my ($system, $user_prompt) = $tune->build_prompt($c, $top, \@plan_docs);

        # Honor an explicit model from the dropdown; otherwise require one via
        # the UI (no silent default). If none supplied, surface a clear error.
        my $req_model = $model || '';
        unless ($req_model) {
            $c->res->body(encode_json({ success => 0, error => 'Select a model',
                detail => 'The Focus-Tune agent needs an explicit model (no default). Pick one in the chat model dropdown.' }));
            return;
        }
        my $can_select = 0;
        my $roles = $c->session->{roles} || [];
        $roles = [split(/\s*,\s*/, $roles)] unless ref $roles;
        $can_select = grep { $_ =~ /^(admin|developer|editor)$/i } @$roles ? 1 : 0;

        my $raw = $tune->run_one($c, { name => $req_model }, $system, $user_prompt, $can_select);
        my $parsed = $tune->parse_result($c, $raw, $top, $rbid, $now_epoch);
        my $payload = {
            %$parsed,
            agent_id => 'focustune',
            note => 'Top-5-by-function from the AI Focus-Tune brain (shared with /api/focus/top5). Advisory only — does not reorder or mutate todos.',
        };
        $c->res->body(encode_json($payload));
        return;
    }

    my $result = try {
        $c->model('AI2::Chat')->process($c,
            prompt          => $prompt,
            model           => $model,
            history         => $history,
            agent_id        => $agent_id,
            system          => $system,
            page_path       => $page_path,
            page_title      => $page_title,
            page_content    => $page_content,
            use_search      => $use_search,
            conversation_id => $conversation_id,
            project_id      => $project_id,
            task_id         => $task_id,
            audio_file_id      => $audio_file_id,
            transcript_file_id => $transcript_file_id,
        );
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'ai2_chat', "Chat process threw: $_");
        { success => 0, error => "Chat failed: $_" };
    };

    $result //= { success => 0, error => 'No response' };

    $c->res->body(encode_json({
        success          => $result->{success} ? 1 : 0,
        response         => $result->{response} // '',
        model            => $result->{model} // $model,
        provider         => $result->{provider} // '',
        needs_web_search => 0,
        error            => $result->{error},
        conversation_id  => $result->{conversation_id},
        title            => $result->{title},
        created_at       => $result->{created_at},
        thinking         => $result->{thinking} // [],
    }));
}

# -------------------------------------------------------------------
# v2 voice pipeline + agentic actions (ported from v1 /ai/* 2026-07-24).
# Thin dispatch: all logic lives in Model::AI2::{Transcribe,Actions}.
# -------------------------------------------------------------------

# POST /ai2/transcribe — audio upload -> whisper background job (job_id).
sub transcribe :Local :Args(0) {
    my ($self, $c) = @_;
    $c->model('AI2::Transcribe')->run($c);
}

# GET /ai2/transcribe_status?job_id= — poll; on done returns transcript
# + archives audio/transcript File rows.
sub transcribe_status :Local :Args(0) {
    my ($self, $c) = @_;
    $c->model('AI2::Transcribe')->status($c);
}

# -------------------------------------------------------------------
# Beekeeping voice endpoints (2026-07-25).
# Thin dispatch to Model::AI2::Beekeeping (domain logic). The actual
# whisper transcription is performed by /ai2/transcribe (which reads the
# hive_id/inspection_id form fields and persists to voice_transcripts +
# an editable inspection draft). These two endpoints cover the form-side
# operations: fetch hives for the selected yard, and save the edited draft.
# -------------------------------------------------------------------

# GET /ai2/apiary_voice_hives?yard_id= — JSON list of hives for the voice form.
sub apiary_voice_hives :Local :Args(0) {
    my ($self, $c) = @_;
    $c->response->content_type('application/json; charset=utf-8');

    unless ($c->session->{username}) {
        $c->response->status(401);
        $c->response->body(encode_json({ success => 0, error => 'Authentication required' }));
        return;
    }

    my $yard_id = int($c->request->param('yard_id') || 0);
    my @hives;
    try {
        my $schema = $c->model('DBEncy');
        my $rs = $schema->resultset('Hive');
        my $search = $yard_id ? { yard_id => $yard_id } : {};
        @hives = map { { id => $_->id, label => ($_->hive_number // '') . ($_->queen_code ? ' (' . $_->queen_code . ')' : '') } }
                 $rs->search($search, { order_by => 'hive_number' })->all;
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'apiary_voice_hives', "$_");
    };

    $c->response->body(encode_json({ success => 1, hives => \@hives }));
}

# POST /ai2/apiary_voice_save — save the edited inspection draft (from the
# voice form). Delegates to AI2::Beekeeping->update_inspection.
sub apiary_voice_save :Local :Args(0) {
    my ($self, $c) = @_;
    if ($c->request->method ne 'POST') {
        $c->response->status(405);
        $c->response->body(encode_json({ success => 0, error => 'POST required' }));
        return;
    }
    $c->model('AI2::Beekeeping')->update_inspection($c);
}

# POST /ai2/action — agentic write actions (create_inspection, create_hive,
# create_yard, create_queen, todos, projects, helpdesk...).
sub action :Local :Args(0) {
    my ($self, $c) = @_;
    $c->model('AI2::Actions')->perform($c);
}

__PACKAGE__->meta->make_immutable;

1;

__END__

=head1 NAME

Comserv::Controller::AI2 - Clean thin Controller for AI functionality

=cut