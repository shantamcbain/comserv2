package Comserv::View::JSON;
use Moose;
use namespace::autoclean;
use JSON::MaybeXS;

extends 'Catalyst::View';

sub process {
    my ($self, $c) = @_;
    
    # Get the data from the stash
    my $data = {};
    foreach my $key (qw(json_data records schema_info errors)) {
        $data->{$key} = $c->stash->{$key} if exists $c->stash->{$key};
    }
    
    # Convert to JSON
    my $json = JSON::MaybeXS->new(
        pretty => 1,
        canonical => 1,
        convert_blessed => 1,
        allow_blessed => 1,
        allow_nonref => 1
    )->encode($data);
    
    # Set the response
    $c->response->content_type('application/json');
    $c->response->body($json);
    
    return 1;
}

=head1 NAME

Comserv::View::JSON - JSON View for Comserv

=head1 DESCRIPTION

JSON View for the Comserv application.

=cut

1;