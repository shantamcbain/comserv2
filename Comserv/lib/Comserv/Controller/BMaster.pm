package Comserv::Controller::BMaster;
use Moose;
use namespace::autoclean;
use DateTime; 
use DateTime::Event::Recurrence;
use Comserv::Model::BMasterModel;
use Comserv::Model::DBForager;
BEGIN { extends 'Catalyst::Controller'; }
has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

sub base :Chained('/') :PathPart('BMaster') :CaptureArgs(0) {
    my ($self, $c) = @_;
    # This will be the root of the chained actions
    # You can put common setup code here if needed
}
sub index :Path('/BMaster') :Args(0) {
    my ( $self, $c ) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "BMaster direct index method called");

    # Forward to the chained index action
    $c->forward('chained_index');
}

sub chained_index :Chained('base') :Path('') :Args(0) {
    my ( $self, $c ) = @_;

    # Add detailed logging
    eval {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "BMaster index method called");
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Setting template to BMaster/BMaster.tt");
        
        # Set the template
        $c->stash(template => 'BMaster/BMaster.tt');

        # Forward to the TT view
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Forwarding to TT view");
        $c->forward($c->view('TT'));

        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "BMaster index method completed successfully");
    };
    if ($@) {
        # Log any errors
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'index', "Error in BMaster index method: $@");
    }
}

1;
