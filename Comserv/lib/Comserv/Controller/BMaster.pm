package Comserv::Controller::BMaster;
use Moose;
use namespace::autoclean;

BEGIN { extends 'Catalyst::Controller'; }
sub base :Chained('/') :PathPart('BMaster') :CaptureArgs(0) {
    my ( $self, $c ) = @_;
    # This will capture /BMaster in the URL
}


sub index :Path :Args(0) {
    my ( $self, $c ) = @_;
    $c->stash(template => 'BMaster/BMaster.tt');
    $c->forward($c->view('TT'));
}

sub api_frames :Chained('base') :PathPart('api/frames') :Args(0) {
    my ( $self, $c ) = @_;

    # Fetch the data for the frames
    my $data = $c->model('BMaster')->get_frames_data();

    # Set the response body to the JSON representation of the data
    $c->response->body( $c->stash->{json}->($data) );
}
sub products :Chained('base') :PathPath('products') :Args(0) {
    my ( $self, $c ) = @_;
    $c->stash(template => 'BMaster/products.tt');
}

sub frames :Chained('base') :PathPart('frames') :Args(1) {
    my ( $self, $c, $queen_tag_number ) = @_;

    # Call an existing method in the BMaster model
    my $frames = $c->model('BMaster')->existing_method($queen_tag_number);

    # Rest of the method...
}

sub yards :Chained('base') :PathPart('yards') :Args(0) {
    my ( $self, $c ) = @_;

    # Call an existing method in the BMaster model
    my $yards = $c->model('BMaster')->existing_method();

    # Rest of the method...
}


# Define an action for each link in BMaster.tt

sub apiary :Chained('base') :PathPart('apiary') :Args(0){
    my ( $self, $c ) = @_;
    $c->log->debug('Entered apiary');
    # Set the TT template to use
    $c->stash->{template} = 'BMaster/apiary.tt';
    $c->forward($c->view('TT'));
}

sub queens :Chained('base') :PathPart('Queens') :Args(0) {
    my ( $self, $c ) = @_;
    $c->stash->{template} = 'BMaster/Queens.tt';
}

sub hive :Chained('base') :PathPart('hive') :Args(0){
    my ( $self, $c ) = @_;
    $c->stash->{template} = 'BMaster/hive.tt';
}

sub honey :Chained('base') :PathPart('honey') :Args(0){
    my ( $self, $c ) = @_;
    $c->stash->{template} = 'BMaster/honey.tt';
}

sub beehealth :Chained('base') :PathPart('beehealth') :Args(0){
    my ( $self, $c ) = @_;
    $c->stash->{template} = 'BMaster/beehealth.tt';
}

sub environment :Chained('base') :PathPart('environment') :Args(0){
    my ( $self, $c ) = @_;
    $c->stash->{template} = 'BMaster/environment.tt';
}

sub education :Chained('base') :PathPart('education') :Args(0){
    my ( $self, $c ) = @_;
    $c->stash->{template} = 'BMaster/education.tt';
}


__PACKAGE__->meta->make_immutable;

1;
