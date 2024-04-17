package Comserv::Model::AI;
use Moose;
use namespace::autoclean;
use JSON qw(encode_json decode_json);

extends 'Catalyst::Model';

sub process_data {
    my ($self, $c, $data) = @_;
    my $processed_data;
    $c->stash(answer => $data->{answer});
    return $processed_data;
}
sub start_operation {
    my ($self, $question) = @_;

    # Create a user agent
    my $ua = LWP::UserAgent->new;

    # Define the URL of the AI API
    my $url = 'http://0.0.0.0:4000/ask'; # Replace with your actual AI API URL

    # Define the headers
    my $headers = HTTP::Headers->new(
        'Content-Type' => 'application/json'
    );

    # Define the body
    my $body = encode_json({ question => $question });

    # Create a POST request
    my $request = HTTP::Request->new('POST', $url, $headers, $body);

    # Send the request
    my $response = $ua->request($request);

    # Check if the request was successful
    if ($response->is_success) {
        # The request was successful, parse the response body
        my $data = decode_json($response->decoded_content);

        # Extract the operation_id from the response data
        my $operation_id = $data->{operation_id};

        # Return the operation_id immediately and handle the time delay of getting the answer elsewhere
        return { operation_id => $operation_id };
    } else {
        # The request failed, return an error message
        return { error => 'Failed to connect to AI.' };
    }
}
__PACKAGE__->meta->make_immutable;

1;