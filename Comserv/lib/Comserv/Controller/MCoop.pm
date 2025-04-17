package Comserv::Controller::MCoop;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

BEGIN { extends 'Catalyst::Controller'; }

# Set the namespace for this controller
__PACKAGE__->config(namespace => 'mcoop');

sub auto :Private {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "MCoop controller auto method called");
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "Request path: " . $c->req->uri->path);
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "Request method: " . $c->req->method);
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "Controller: " . __PACKAGE__);

    # If there's an uppercase MCOOP in the session, remove it
    if ($c->session->{"theme_" . lc("MCOOP")}) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "Removing uppercase MCOOP theme from session");
        delete $c->session->{"theme_" . lc("MCOOP")};
    }

    return 1; # Allow the request to proceed
}

# Base chain for all MCoop actions
sub base :Chained('/') :PathPart('MCoop') :CaptureArgs(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'base', "Base chained method called");

    # Common setup for all MCoop actions
    $c->stash->{main_website} = "https://monasheecoop.ca";

    # Set theme consistently
    $c->stash->{theme_name} = "mcoop";
    $c->session->{"theme_mcoop"} = "mcoop";
    $c->session->{theme_name} = "mcoop";
    $c->session->{"theme_" . lc("MCoop")} = "mcoop";

    # Initialize debug_errors array if needed
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};
    $c->stash->{debug_mode} = $c->session->{debug_mode} || 0;
}

# Main index page at /MCoop
sub index :Chained('base') :PathPart('') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', 'Enter MCoop index method');

    # Set mail server
    $c->session->{MailServer} = "http://webmail.computersystemconsulting.ca";

    # Generate theme CSS if needed
    $c->model('ThemeConfig')->generate_all_theme_css($c);

    # Make sure we're using the correct case for the site name
    $c->model('ThemeConfig')->set_site_theme($c, "MCoop", "mcoop");

    # Use the standard debug message system
    if ($c->session->{debug_mode}) {
        $c->stash->{debug_msg} = [] unless defined $c->stash->{debug_msg};
        push @{$c->stash->{debug_msg}}, "MCoop controller index view - Using mcoop theme";
    }

    # Set template and forward to view
    $c->stash(template => 'coop/index.tt');
    $c->forward($c->view('TT'));
}

# Direct access to index for backward compatibility
sub direct_index :Path('/MCoop') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'direct_index', "Direct index method called, forwarding to chained index");
    $c->forward('index');
}

# Server room plan section
sub server_room_plan_base :Chained('base') :PathPart('server_room_plan') :CaptureArgs(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'server_room_plan_base', 'Enter server_room_plan_base method');

    # Set up common elements for server room plan pages
    $c->stash->{help_message} = "This is the server room proposal for the Monashee Coop transition team.";
    $c->stash->{account_message} = "For more information or to provide feedback, please contact the IT department.";
}

# Main server room plan page at /MCoop/server_room_plan
sub server_room_plan :Chained('server_room_plan_base') :PathPart('') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'server_room_plan', 'Enter server_room_plan method');

    # Use the standard debug message system
    if ($c->session->{debug_mode}) {
        $c->stash->{debug_msg} = [] unless defined $c->stash->{debug_msg};
        push @{$c->stash->{debug_msg}}, "MCoop controller server_room_plan view - Template: coop/server_room_plan.tt";
    }

    # Set template and forward to view
    $c->stash(template => 'coop/server_room_plan.tt');
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'server_room_plan', 'Set template to coop/server_room_plan.tt');
    $c->forward($c->view('TT'));
}

# Direct access to server_room_plan for backward compatibility
sub direct_server_room_plan :Path('/MCoop/server_room_plan') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'direct_server_room_plan', 'Direct server_room_plan method called');
    $c->forward('server_room_plan');
}

# Handle the hyphenated version for backward compatibility
sub server_room_plan_hyphen :Path('/MCoop/server-room-plan') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'server_room_plan_hyphen', 'Enter server_room_plan_hyphen method');
    $c->forward('server_room_plan');
}

# Catch-all for any other MCoop paths
sub default :Private {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'default', "Default method called, forwarding to index");
    $c->forward('index');
}

__PACKAGE__->meta->make_immutable;

1;