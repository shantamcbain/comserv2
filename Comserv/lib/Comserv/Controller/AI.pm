package Comserv::Controller::AI;
use Moose;
use namespace::autoclean;
use HTTP::Request::Common qw(POST);
use LWP::UserAgent;
use JSON;

BEGIN { extends 'Catalyst::Controller'; }


package Comserv::Controller::AI;
use Moose;
use namespace::autoclean;
use HTTP::Request::Common qw(POST);
use LWP::UserAgent;
use JSON;

BEGIN { extends 'Catalyst::Controller'; }

sub index :Path :Args(0) {
    my ( $self, $c ) = @_;

    # Check if the request method is GET
    if ($c->request->method eq 'GET') {
        # Render the index.tt template
        $c->stash(template => 'ai/index.tt');
    } else {
        # Get the question from the request
        my $question = $c->request->body_data->{question};

        # Check if $question is defined
        if (defined $question) {
            # Start the long-running operation
            my $operation_data = $c->model('AI')->start_operation($question);

            # Rest of the code...
        } else {
            # $question is not defined, render the index.tt template
            $c->stash(template => 'ai/index.tt');
        }
    }
}

sub get_answer :Path('get_answer') :Args(1) {
    my ( $self, $c, $operation_id ) = @_;

    # Get the answer if it's ready
    my $answer = $c->model('AI')->get_answer($operation_id);

    # Check if the answer is ready
    if (defined $answer) {
        # The answer is ready, send it in the response
        $c->response->body(encode_json({ answer => $answer }));
    } else {
        # The answer is not ready, send a "still thinking" message
        $c->response->body(encode_json({ message => "Still thinking..." }));
    }
}

__PACKAGE__->meta->make_immutable;

1;
sub operation_status :Path('operation_status') :Args(1) {
    my ( $self, $c, $operation_id ) = @_;

    # Get the status of the operation
    my $status = $c->model('AI')->get_operation_status($operation_id);

    # Return the status in the response
    $c->response->body(encode_json($status));
}
__PACKAGE__->meta->make_immutable;

1;