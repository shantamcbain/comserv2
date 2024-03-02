package Comserv::Model::WorkShop;
use Moose;
use namespace::autoclean;

extends 'Catalyst::Model';

# In Model/WorkShop.pm
sub get_active_workshops {
    my ($self, $c) = @_;

    # Get a DBIx::Class::Schema object
    my $schema = $c->model('DBEncy');

    # Get a DBIx::Class::ResultSet object for the 'WorkShop' table
    my $rs = $schema->resultset('WorkShop');

    my @workshops;
    my $error;
    eval {
        # Fetch the active workshops from today's date and are not private
        @workshops = $rs->search(
            {
                date => { '>=' => DateTime->today->ymd },
                share => 0
            },
            { order_by => { -asc => 'date' } }
        );
    };
    if ($@) {
        $error = "Error fetching active workshops: $@";
    }

    return (\@workshops, $error);
}
__PACKAGE__->meta->make_immutable;

1;
