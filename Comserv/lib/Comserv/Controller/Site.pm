package Comserv::Controller::Site;
use Moose;
use namespace::autoclean;

BEGIN { extends 'Catalyst::Controller'; }
sub index :Path :Args(0) {
    my ( $self, $c ) = @_;

    $c->response->body('Matched Comserv::Controller::Site in Site.');
}
sub add_site :Local {
    my ($self, $c) = @_;

    # Get the site details from the request
    my $site = $c->request->body_parameters;

    # Get a DBIx::Class::Schema object
    my $schema = $c->model('DBEncy');

    # Get the Site resultset
    my $site_rs = $schema->resultset('Site');

    # Add the site to the database
    $site_rs->create({
        name => $site->{name},
        description => $site->{description},
    });

    # Pass a success message to the template
    $c->flash->{message} = 'Site added successfully';

    # Redirect to the add_site_form action
    $c->res->redirect($c->uri_for($self->action_for('add_site_form')));
}

sub add_site_form :Local {
    my ($self, $c) = @_;

    # Get a DBIx::Class::Schema object
    my $schema = $c->model('DBEncy');

    # Get the Site resultset
    my $site_rs = $schema->resultset('Site');

    # Get all sites
    my @sites = $site_rs->all;

    # Pass the sites to the template
    $c->stash->{sites} = \@sites;

    # Render the add_site_form.tt template
    $c->stash(template => 'todo/add_site.tt');
}
__PACKAGE__->meta->make_immutable;

1;
