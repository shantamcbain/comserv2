package Comserv::Controller::AI2;

use Moose;
use namespace::autoclean;

use Try::Tiny;
use JSON;
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

    $c->stash(
        template            => 'ai2/editing_widget_popup.tt',
        selected_model      => $selected_model,
        recommended_models  => $recommended_models,
        branches            => $branches,
        no_wrapper          => 1,
    );
    # Catalyst will render the fragment into the dialog
}

__PACKAGE__->meta->make_immutable;

1;

__END__

=head1 NAME

Comserv::Controller::AI2 - Clean thin Controller for AI functionality

=cut