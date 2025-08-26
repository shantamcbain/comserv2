package Comserv::View::JSON;

use strict;
use warnings;
use base 'Catalyst::View';
use JSON;

=head1 NAME

Comserv::View::JSON - JSON View for Comserv

=head1 DESCRIPTION

Catalyst JSON View.

=head1 METHODS

=cut

sub process {
    my ($self, $c) = @_;
    
    # Get the JSON data from the stash
    my $json_data = $c->stash->{json} || {};
    
    # Set the content type to JSON
    $c->response->content_type('application/json; charset=utf-8');
    
    # Encode the data as JSON
    my $json = JSON->new->utf8->pretty->encode($json_data);
    
    # Set the response body
    $c->response->body($json);
    
    return 1;
}

=head1 AUTHOR

Comserv

=head1 LICENSE

This library is free software, you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

1;