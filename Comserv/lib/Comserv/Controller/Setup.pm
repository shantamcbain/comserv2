package Comserv::Controller::Setup;
use Moose;
use namespace::autoclean;

BEGIN { extends 'Catalyst::Controller'; }

=head1 NAME

Comserv::Controller::Setup - Catalyst Controller

=head1 DESCRIPTION

Catalyst Controller for handling the setup process.

=head1 METHODS

=cut

=head2 index

Display the setup page.

=cut

sub index :Path :Args(0) {
    my ( $self, $c ) = @_;

    # Render the setup template
    $c->stash(template => 'setup/index.tt');
}

=head2 process

Handle the setup form submission.

=cut

sub process :Path('process') :Args(0) {
    my ( $self, $c ) = @_;

    # Process the setup form submission
    my $db_schema_manager = $c->model('DBSchemaManager')->new();

    try {
        $db_schema_manager->deploy_schema('DBEncy');
        $db_schema_manager->deploy_schema('DBForager');
        $c->stash(success_msg => 'Databases have been successfully set up.');
    } catch {
        $c->stash(error_msg => "Error setting up databases: $_");
    };

    # Render the setup template
    $c->stash(template => 'setup/index.tt');
}

=encoding utf8

=head1 AUTHOR

Shanta McBain

=head1 LICENSE

This library is free software. You can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

__PACKAGE__->meta->make_immutable;

1;