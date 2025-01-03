package Comserv::View::AutoCRUD::JSON;
use Moose;
use namespace::autoclean;

extends 'Catalyst::View::JSON';

__PACKAGE__->config(
    expose_stash => 'json_data',
    json_encoder_args => {
        pretty => 1,
        canonical => 1,
    },
);

=head1 NAME

Comserv::View::AutoCRUD::JSON - JSON View for AutoCRUD

=head1 DESCRIPTION

JSON View for the AutoCRUD interface.

=cut

1;
