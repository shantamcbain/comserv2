package Comserv::Controller::BMaster;
use Moose;
use namespace::autoclean;
use DateTime;
use DateTime::Event::Recurrence;
use Comserv::Model::BMaster;
use Comserv::Model::ApiaryModel;
use Comserv::Model::DBForager;
use Comserv::Util::Logging;
use Data::Dumper;

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

has 'apiary_model' => (
    is => 'ro',
    default => sub { Comserv::Model::ApiaryModel->new }
);

BEGIN { extends 'Catalyst::Controller'; }

sub base :Chained('/') :PathPart('BMaster') :CaptureArgs(0) {
    my ($self, $c) = @_;
    # This will be the root of the chained actions
    # You can put common setup code here if needed
}

sub index :Path('/BMaster') :Args(0) {
    my ( $self, $c ) = @_;

    # Initialize debug_errors array
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};

    # Add detailed logging
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "BMaster direct index method called");
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Request path: " . $c->req->path);
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Request URI: " . $c->req->uri);

    push @{$c->stash->{debug_errors}}, "BMaster direct index method called";
    push @{$c->stash->{debug_errors}}, "Request path: " . $c->req->path;
    push @{$c->stash->{debug_errors}}, "Request URI: " . $c->req->uri;

    # Set up the template directly instead of forwarding
    $c->stash(template => 'BMaster/BMaster.tt');
    
    # Ensure debug_msg is always an array
    $c->stash->{debug_msg} = [] unless ref $c->stash->{debug_msg} eq 'ARRAY';
    push @{$c->stash->{debug_msg}}, "BMaster Module - Main Dashboard";

    # Log the stash for debugging
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Template set to: " . $c->stash->{template});
}

sub chained_index :Chained('base') :PathPart('') :Args(0) {
    my ( $self, $c ) = @_;

    # Initialize debug_errors array
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};

    # Add detailed logging
    eval {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'chained_index', "BMaster chained_index method called");
        push @{$c->stash->{debug_errors}}, "BMaster chained_index method called";

        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'chained_index', "Setting template to BMaster/BMaster.tt");

        # Set the template
        $c->stash(template => 'BMaster/BMaster.tt');
        
        # Ensure debug_msg is always an array
        $c->stash->{debug_msg} = [] unless ref $c->stash->{debug_msg} eq 'ARRAY';
        push @{$c->stash->{debug_msg}}, "BMaster Module - Main Dashboard";

        # No need to forward to the TT view here, let Catalyst handle it
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'chained_index', "BMaster chained_index method completed successfully");
    };
    if ($@) {
        # Log any errors
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'chained_index', "Error in BMaster chained_index method: $@");
        push @{$c->stash->{debug_errors}}, "Error in BMaster chained_index method: $@";
    }
}

# Route for Bee Pasture
sub bee_pasture :Path('/BMaster/bee_pasture') :Args(0) {
    my ($self, $c) = @_;

    # Initialize debug_errors array
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'bee_pasture', "BMaster bee_pasture method called");
    push @{$c->stash->{debug_errors}}, "BMaster bee_pasture method called";

    # Redirect to the ENCY BeePastureView
    $c->response->redirect('/ENCY/BeePastureView');
}

# Route for Apiary Management System
sub apiary :Path('/BMaster/apiary') :Args(0) {
    my ($self, $c) = @_;

    # Initialize debug_errors array
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'apiary', "BMaster apiary method called");
    push @{$c->stash->{debug_errors}}, "BMaster apiary method called";

    # Redirect to the Apiary controller
    $c->response->redirect('/Apiary');
}

# Route for Queen Rearing System
sub queens :Path('/BMaster/Queens') :Args(0) {
    my ($self, $c) = @_;

    # Initialize debug_errors array
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'queens', "BMaster queens method called");
    push @{$c->stash->{debug_errors}}, "BMaster queens method called";

    # Redirect to the Queen Rearing page
    $c->response->redirect('/Apiary/QueenRearing');
}

# Route for Hive Management
sub hive :Path('/BMaster/hive') :Args(0) {
    my ($self, $c) = @_;

    # Initialize debug_errors array
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'hive', "BMaster hive method called");
    push @{$c->stash->{debug_errors}}, "BMaster hive method called";

    # Redirect to the Hive Management page
    $c->response->redirect('/Apiary/HiveManagement');
}

# Route for Bee Health
sub beehealth :Path('/BMaster/beehealth') :Args(0) {
    my ($self, $c) = @_;

    # Initialize debug_errors array
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'beehealth', "BMaster beehealth method called");
    push @{$c->stash->{debug_errors}}, "BMaster beehealth method called";

    # Redirect to the Bee Health page
    $c->response->redirect('/Apiary/BeeHealth');
}

# Placeholder routes for sections that don't have dedicated pages yet
sub honey :Path('/BMaster/honey') :Args(0) {
    my ($self, $c) = @_;

    # Initialize debug_errors array
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'honey', "BMaster honey method called");
    push @{$c->stash->{debug_errors}}, "BMaster honey method called";

    # Set up a placeholder page
    $c->stash(
        title => 'Honey Production',
        message => 'The Honey Production system is currently under development. Please check back soon.',
        template => 'BMaster/placeholder.tt',
        debug_msg => "Honey Production - Under Development"
    );
}

sub environment :Path('/BMaster/environment') :Args(0) {
    my ($self, $c) = @_;

    # Initialize debug_errors array
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'environment', "BMaster environment method called");
    push @{$c->stash->{debug_errors}}, "BMaster environment method called";

    # Set up a placeholder page
    $c->stash(
        title => 'Environmental Considerations',
        message => 'The Environmental Considerations system is currently under development. Please check back soon.',
        template => 'BMaster/placeholder.tt',
        debug_msg => "Environmental Considerations - Under Development"
    );
}

sub education :Path('/BMaster/education') :Args(0) {
    my ($self, $c) = @_;

    # Initialize debug_errors array
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'education', "BMaster education method called");
    push @{$c->stash->{debug_errors}}, "BMaster education method called";

    # Set up a placeholder page
    $c->stash(
        title => 'Education and Collaboration',
        message => 'The Education and Collaboration system is currently under development. Please check back soon.',
        template => 'BMaster/placeholder.tt',
        debug_msg => "Education and Collaboration - Under Development"
    );
}

# Default action to handle any undefined routes
sub default :Path :Args {
    my ($self, $c) = @_;

    # Initialize debug_errors array
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'default', "BMaster default method called for path: " . $c->req->path);
    push @{$c->stash->{debug_errors}}, "BMaster default method called for path: " . $c->req->path;

    # Redirect to the BMaster index page
    $c->response->redirect('/BMaster');
    $c->detach();
}

1;
