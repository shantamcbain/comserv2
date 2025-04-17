package Comserv::Model::BMaster;
use Moose;
use namespace::autoclean;
use Comserv::Model::ApiaryModel;

# This package extends the Catalyst::Model class
extends 'Catalyst::Model';

has 'apiary_model' => (
    is => 'ro',
    default => sub { Comserv::Model::ApiaryModel->new }
);

# This subroutine fetches frames for a given queen
# @param $queen_tag_number - The tag number of the queen for which frames are to be fetched
# @return \@frames - An array reference containing the frames for the given queen
sub get_frames_for_queen {
    my ($self, $queen_tag_number) = @_;

    warn "DEPRECATED: get_frames_for_queen in BMaster.pm is deprecated. Please use ApiaryModel->get_frames_for_queen instead.";

    # Forward to the ApiaryModel implementation
    return $self->apiary_model->get_frames_for_queen($queen_tag_number);
}

# This subroutine fetches yards for a given site
# @param $site_name - The name of the site for which yards are to be fetched
# @return \@yards - An array reference containing the yards for the given site
sub get_yards_for_site {
    my ($self, $site_name) = @_;

    warn "DEPRECATED: get_yards_for_site in BMaster.pm is deprecated. Please use ApiaryModel->get_yards_for_site instead.";

    # Forward to the ApiaryModel implementation
    return $self->apiary_model->get_yards_for_site($site_name);
}

# This subroutine counts the number of queens
# @return $count - The number of queens
sub count_queens {
    my ($self) = @_;

    warn "DEPRECATED: count_queens in BMaster.pm is deprecated. Please use ApiaryModel->count_queens instead.";

    # Forward to the ApiaryModel implementation
    return $self->apiary_model->count_queens();
}

# This subroutine adds a yard
# @param $c - The Catalyst context object
# @param $yard_name - The name of the yard to be added
# @return 1 - Returns 1 if the yard is successfully added
sub add_yard {
    my ($self, $c, $yard_name) = @_;

    warn "DEPRECATED: add_yard in BMaster.pm is deprecated. Please use ApiaryModel->add_yard instead.";

    # Forward to the ApiaryModel implementation
    return $self->apiary_model->add_yard($c, $yard_name);
}

# This subroutine counts the number of frames
# @return $count - The number of frames
sub count_frames {
    my ($self) = @_;

    warn "DEPRECATED: count_frames in BMaster.pm is deprecated. Please use ApiaryModel->count_frames instead.";

    # Forward to the ApiaryModel implementation
    return $self->apiary_model->count_frames();
}

# This line makes the package immutable
__PACKAGE__->meta->make_immutable;

1;