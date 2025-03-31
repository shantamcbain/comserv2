package Comserv::Controller::MCoop;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

BEGIN { extends 'Catalyst::Controller'; }

__PACKAGE__->config(namespace => 'mcoop');

sub auto :Private {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "MCoop controller auto method called");
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "Request path: " . $c->req->uri->path);
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "Request method: " . $c->req->method);
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "Controller: " . __PACKAGE__);
    return 1; # Allow the request to proceed
}

sub index :Path :Args(0) {
    my ( $self, $c ) = @_;
    # Existing index logic remains unchanged...
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', 'Enter MCoop index method');
    $c->session->{MailServer} = "http://webmail.computersystemconsulting.ca";
    $c->model('ThemeConfig')->generate_all_theme_css($c);
    delete $c->session->{"theme_mcoop"};
    delete $c->session->{theme_name};
    delete $c->session->{"theme_" . lc("MCOOP")};
    $c->stash->{theme_name} = "mcoop";
    $c->session->{"theme_mcoop"} = "mcoop";
    $c->session->{theme_name} = "mcoop";
    $c->session->{"theme_" . lc("MCOOP")} = "mcoop";
    $c->model('ThemeConfig')->set_site_theme($c, "MCOOP", "mcoop");
    $c->stash->{help_message} = "Welcome to the Monashee Coop HelpDesk support portal. This is the administrative view of monasheecoop.ca.";
    $c->stash->{account_message} = "To access the public features of the Monashee Coop site, please create an account.";
    $c->stash->{main_website} = "https://monasheecoop.ca";
    $c->stash->{debug_msg} = "MCoop controller index view - Using mcoop theme";
    $c->stash->{debug_mode} = $c->session->{debug_mode} || 1;
    $c->stash(template => 'coop/index.tt');
    $c->forward($c->view('TT'));
}

sub server_room_plan :Path('server_room_plan') :Args(0) {
    my ( $self, $c ) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'server_room_plan', 'Enter MCoop server_room_plan method');

    $c->stash->{theme_name} = "mcoop";
    $c->session->{"theme_mcoop"} = "mcoop";
    $c->session->{theme_name} = "mcoop";
    $c->session->{"theme_" . lc("MCOOP")} = "mcoop";

    $c->stash->{help_message} = "This is the server room proposal for the Monashee Coop transition team.";
    $c->stash->{account_message} = "For more information or to provide feedback, please contact the IT department.";
    $c->stash->{main_website} = "https://monasheecoop.ca";

    $c->stash->{debug_msg} = "MCoop controller server_room_plan view - Template: coop/server_room_plan.tt";
    $c->stash->{debug_mode} = 1;

    $c->stash(template => 'coop/server_room_plan.tt');
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'server_room_plan', 'Set template to coop/server_room_plan.tt');

    $c->forward($c->view('TT'));
}

# Also handle the hyphenated version for backward compatibility
sub server_room_plan_hyphen :Path('server-room-plan') :Args(0) {
    my ( $self, $c ) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'server_room_plan_hyphen', 'Enter MCoop server_room_plan_hyphen method');
    $c->forward('server_room_plan');
}

# Method with underscore for Root controller compatibility
sub server_room_plan_underscore :Path('/mcoop/server_room_plan') :Args(0) {
    my ( $self, $c ) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'server_room_plan_underscore', 'Enter MCoop server_room_plan_underscore method');

    # Forward to the main server_room_plan method
    $c->forward('server_room_plan');
}

__PACKAGE__->meta->make_immutable;

1;