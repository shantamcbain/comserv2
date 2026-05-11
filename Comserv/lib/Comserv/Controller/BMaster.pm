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

# Backward-compat stubs — redirect /BMaster/* to canonical /Beekeeping/* routes

sub bee_pasture :Path('/BMaster/bee_pasture') :Args(0) {
    my ($self, $c) = @_;
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'bee_pasture', "BMaster bee_pasture → /Beekeeping/bee_pasture");
    $c->response->redirect('/Beekeeping/bee_pasture');
}

sub apiary :Path('/BMaster/apiary') :Args(0) {
    my ($self, $c) = @_;
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'apiary', "BMaster apiary → /Beekeeping/apiary");
    $c->response->redirect('/Beekeeping/apiary');
}

sub queens :Path('/BMaster/Queens') :Args(0) {
    my ($self, $c) = @_;
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'queens', "BMaster queens → /Beekeeping/Queens");
    $c->response->redirect('/Beekeeping/Queens');
}

sub hive :Path('/BMaster/hive') :Args(0) {
    my ($self, $c) = @_;
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'hive', "BMaster hive → /Beekeeping/hive");
    $c->response->redirect('/Beekeeping/hive');
}

sub beehealth :Path('/BMaster/beehealth') :Args(0) {
    my ($self, $c) = @_;
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'beehealth', "BMaster beehealth → /Beekeeping/health");
    $c->response->redirect('/Beekeeping/health');
}

sub honey :Path('/BMaster/honey') :Args(0) {
    my ($self, $c) = @_;
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'honey', "BMaster honey → /Beekeeping/harvest");
    $c->response->redirect('/Beekeeping/harvest');
}

sub environment :Path('/BMaster/environment') :Args(0) {
    my ($self, $c) = @_;
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'environment', "BMaster environment → /Beekeeping/environment");
    $c->response->redirect('/Beekeeping/environment');
}

sub education :Path('/BMaster/education') :Args(0) {
    my ($self, $c) = @_;
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'education', "BMaster education → /Beekeeping/education");
    $c->response->redirect('/Beekeeping/education');
}

sub yards :Path('/BMaster/yards') :Args(0) {
    my ($self, $c) = @_;
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'yards', "BMaster yards → /Beekeeping/yards");
    $c->response->redirect('/Beekeeping/yards');
}

sub add_yard :Path('/BMaster/add_yard') :Args(0) {
    my ($self, $c) = @_;
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_yard', "BMaster add_yard → /Beekeeping/add_yard");
    $c->response->redirect('/Beekeeping/add_yard');
}

sub products :Path('/BMaster/products') :Args(0) {
    my ($self, $c) = @_;
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'products', "BMaster products → /Beekeeping/products");
    $c->response->redirect('/Beekeeping/products');
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
