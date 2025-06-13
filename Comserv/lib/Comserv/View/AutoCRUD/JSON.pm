package Comserv::View::AutoCRUD::JSON;
use Moose;
use namespace::autoclean;

BEGIN {
    # Try to load the real module
    eval {
        require Catalyst::View::JSON;
    };
    
    if ($@) {
        # If we can't load the module, extend the custom JSON view instead
        warn "Cannot load Catalyst::View::JSON: $@\n";
        warn "Using Comserv::View::JSON instead.\n";
        require Comserv::View::JSON;
        extends 'Comserv::View::JSON';
    } else {
        # If we can load the module, extend it
        extends 'Catalyst::View::JSON';
    }
}

# Override the process method to handle AutoCRUD specific data
sub process {
    my ($self, $c) = @_;
    
    # Get the JSON data from the stash - check for AutoCRUD specific keys first
    my $json_data = $c->stash->{json_data} || 
                   $c->stash->{records} || 
                   $c->stash->{schema_info} || 
                   $c->stash->{errors} || 
                   $c->stash->{json} || 
                   {};
    
    # If we're using Catalyst::View::JSON, set up the stash appropriately
    if ($self->isa('Catalyst::View::JSON')) {
        # Catalyst::View::JSON expects data in specific stash keys
        $c->stash->{json} = $json_data;
    } else {
        # Comserv::View::JSON expects data in the json key
        $c->stash->{json} = $json_data;
    }
    
    # Call the parent process method
    return $self->SUPER::process($c);
}

=head1 NAME

Comserv::View::AutoCRUD::JSON - JSON View for AutoCRUD

=head1 DESCRIPTION

JSON View for the AutoCRUD interface.

=cut

1;
