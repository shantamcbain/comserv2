package Comserv::Model::BMasterModel;
use Moose;
use namespace::autoclean;
use Comserv::Model::ApiaryModel;

extends 'Catalyst::Model';

# These methods are now deprecated and will be removed in a future version
# Please use the equivalent methods in Comserv::Model::ApiaryModel instead

sub get_frames_for_queen {
    my ($self, $queen_tag_number) = @_;

    warn "DEPRECATED: get_frames_for_queen in BMasterModel is deprecated. Please use ApiaryModel->get_frames_for_queen instead.";

    # Forward to the ApiaryModel implementation
    my $apiary_model = Comserv::Model::ApiaryModel->new;
    return $apiary_model->get_frames_for_queen($queen_tag_number);
}

sub get_yards_for_site {
    my ($self, $site_name) = @_;

    warn "DEPRECATED: get_yards_for_site in BMasterModel is deprecated. Please use ApiaryModel->get_yards_for_site instead.";

    # Forward to the ApiaryModel implementation
    my $apiary_model = Comserv::Model::ApiaryModel->new;
    return $apiary_model->get_yards_for_site($site_name);
}

__PACKAGE__->meta->make_immutable;

1;
