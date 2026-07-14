package Comserv::Controller::AI2;

use Moose;
use namespace::autoclean;

use Try::Tiny;
use JSON;
use Comserv::Util::EditorFile;
use DateTime;

use Comserv::Util::Logging;
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

__PACKAGE__->meta->make_immutable;

1;

__END__

=head1 NAME

Comserv::Controller::AI2 - Clean thin Controller for AI functionality

=cut