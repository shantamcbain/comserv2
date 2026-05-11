package Comserv::Model::BeekeepingModel;
use Moose;
use namespace::autoclean;

extends 'Catalyst::Model';

=head1 NAME

Comserv::Model::BeekeepingModel - Model for Beekeeping feature operations

=head1 DESCRIPTION

Provides yard and hive-list helpers for the Beekeeping controller hierarchy.
Inspection and queen-assignment helpers remain in ApiaryModel.

=head1 METHODS

=head2 get_yards_for_site

Retrieves all bee yards for a given site from the Beekeeping::Yard resultset.

=cut

sub get_yards_for_site {
    my ($self, $c, $sitename) = @_;
    my @yards;
    eval {
        @yards = $c->model('DBEncy')->resultset('Beekeeping::Yard')->search(
            { sitename => $sitename },
            { order_by => 'yard_name' }
        )->all;
    };
    if ($@) {
        warn "BeekeepingModel->get_yards_for_site error: $@";
        return [];
    }
    return \@yards;
}

=head2 get_hives_for_yard

Retrieves all hives in a specific yard from the Beekeeping::Hive resultset.

=cut

sub get_hives_for_yard {
    my ($self, $c, $yard_id) = @_;
    my @hives;
    eval {
        @hives = $c->model('DBEncy')->resultset('Beekeeping::Hive')->search(
            { yard_id => $yard_id },
            { order_by => 'hive_name' }
        )->all;
    };
    if ($@) {
        warn "BeekeepingModel->get_hives_for_yard error: $@";
        return [];
    }
    return \@hives;
}

=head2 create_yard

Creates a new yard record for a site.

=cut

sub create_yard {
    my ($self, $c, $params) = @_;
    eval {
        $c->model('DBEncy')->resultset('Beekeeping::Yard')->create({
            yard_code        => $params->{yard_code},
            yard_name        => $params->{yard_name},
            sitename         => $params->{sitename},
            total_yard_size  => $params->{total_yard_size} || 0,
            date_established => $params->{date_established} || undef,
            notes            => $params->{notes} || '',
        });
    };
    if ($@) {
        warn "BeekeepingModel->create_yard error: $@";
        return (0, $@);
    }
    return (1, undef);
}

__PACKAGE__->meta->make_immutable;

1;
