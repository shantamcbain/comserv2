package Comserv::Controller::Root;
use Moose;
use namespace::autoclean;
use Try::Tiny;
use Comserv::Util::Logging;
use Data::Dumper;  # Ensure Dumper is imported for debugging

BEGIN { extends 'Catalyst::Controller'; }

__PACKAGE__->config(namespace => '');

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

=head1 NAME
Comserv::Controller::Root - Root Controller for Comserv application
=cut

sub auto :Action {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, __FILE__, __LINE__, "Starting auto action");

    # Check if we already have site info in session
    if (!$c->session->{SiteName}) {
        my $site_setup = $c->model('Site')->setup_site($c);
        $self->logging->log_with_details($c, __FILE__, __LINE__, "Site setup called");

        unless ($site_setup) {
            $self->logging->log_with_details($c, __FILE__, __LINE__, "Site setup failed");
            $c->stash(error_msg => "Failed to setup site configuration");
            $c->detach;  # Detach to prevent further processing
        }
    } else {
        $self->logging->log_with_details($c, __FILE__, __LINE__, "Site name already set: $c->session->{site_name}");
    }

    # Debug mode toggle
    my $debug_param = $c->req->param('debug');
    if (defined $debug_param) {
        if ($debug_param eq '1') {
            $c->session->{debug_mode} = 1;
        } elsif ($debug_param eq '0') {
            $c->session->{debug_mode} = 0;
        }
    }
    my $SiteName = $c->session->{site_name};
    # If a SiteName is set in the session, forward to the corresponding controller's index action
    $self->logging->log_with_details($c, __FILE__, __LINE__, "Attempting to forward to controller for site: $c->session->{site_name} $SiteName");
    if ($c->session->{SiteName} && $c->controller($c->session->{site_name})) {
        $c->forward("/$SiteName/index");
        return 1; # Return to indicate success
    }

    return 1;  # Return to indicate success
}

sub index :Action :Path('/') :Args(0) {
    my ($self, $c) = @_;

    # Log entry into the index action
    $self->logging->log_with_details($c, __FILE__, __LINE__, "Entered root index action");

    # Get the SiteName from the session
    my $SiteName = $c->session->{site_name};
    $self->logging->log_with_details($c, __FILE__, __LINE__, "Current SiteName: $SiteName");

    $c->log->debug("Attempting to render index for site: $SiteName");
    $self->logging->log_with_details($c, __FILE__, __LINE__, "Rendering index template for site: $SiteName");
    if ($SiteName && $c->controller($SiteName)) {
        # Forward to the appropriate site controller's index action
        $c->forward(uc $SiteName . "/index");
    } else {
        # If no SiteName is set, render the default index template
        $c->log->debug("No SiteName found, rendering default index template");
        $c->stash(template => 'index.tt');
    }
if ($SiteName && $c->can($SiteName . '::index')) {
    # Forward to the appropriate site controller's index action
    $c->forward($SiteName . "/index");
} else {
    # If no SiteName is set, render the default index template
    $c->log->debug("No SiteName found, rendering default index template");
    $c->stash(template => 'index.tt');
}    $c->forward($c->view('TT'));  # Ensure the view is rendered
}

sub debug :Action :Path('/debug') :Args(0) {
    my ($self, $c) = @_;
    # Add debug information to the stash
    $c->stash(
        template => 'debug.tt',
        debug_info => $c->session,
        current_url => $c->req->uri
    );
    $c->forward($c->view('TT'));
}

sub workshop :Action :Path('/workshop') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, __FILE__, __LINE__, "Entered workshop action");

    # Log the template path and session data
    $c->log->debug("Template path: " . $c->path_to('root', 'WorkShops', 'workshops.tt'));
    $c->log->debug("Session data: " . Dumper($c->session));

    # Check if the template exists before rendering
    if (-e $c->path_to('root', 'WorkShops', 'workshops.tt') && $c->controller('WorkShop')) {
        $c->stash(template => 'WorkShops/workshops.tt');
        $c->forward($c->view('TT'));
    } else {
        $self->logging->log_with_details($c, __FILE__, __LINE__, "Template not found: WorkShops/workshops.tt");
        $c->stash(template => 'error.tt', error_msg => "Template not found.");
    }
    $c->forward($c->view('TT'));
}

sub default :Path {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, __FILE__, __LINE__, "404 Not Found");
    $c->response->body('Page not found');
    $c->response->status(404);
}

sub documentation :Path('documentation') :Args(0) {
    my ( $self, $c ) = @_;

    # Logging to stash
    push @{$c->stash->{error_msg}}, "Entered documentation action in Root.pm";

    # Ensure the template path is correct
    my $template_path = 'Documentation/Documentation.tt';
    if (!-e $c->path_to('root', $template_path)) {
        push @{$c->stash->{error_msg}}, "Template file not found: $template_path";
        $c->response->body('Template file not found');
        $c->response->status(500);
        return;
    }

    $c->stash(template => $template_path);

    # Logging to stash
    push @{$c->stash->{error_msg}}, "Template set to $template_path";

    $c->forward($c->view('TT'));
}

__PACKAGE__->meta->make_immutable;
1;
