package Comserv::Model::Site;
use Moose;
use namespace::autoclean;

extends 'Catalyst::Model';

has 'schema' => (
    is => 'ro',
    required => 1,
);
sub COMPONENT {
    my ($class, $app, $args) = @_;

    my $schema = $app->model('DBEncy');
    return $class->new({ %$args, schema => $schema });
}
sub get_all_sites {
    my ($self) = @_;

    # Get the Site resultset
    my $site_rs = $self->schema->resultset('Site');

    # Get all sites
    my @sites = $site_rs->all;

    return \@sites;
}

sub get_site {
    my ($self, $site_id) = @_;

    # Get the Site resultset
    my $site_rs = $self->schema->resultset('Site');

    # Get the site
    my $site = $site_rs->find($site_id);

    return $site;
}

sub add_site {
    my ($self, $site_details) = @_;

    # Get the Site resultset
    my $site_rs = $self->schema->resultset('Site');

    # Add the site to the database
    my $new_site = $site_rs->create($site_details);

    return $new_site;
}

sub update_site {
    my ($self, $site_id, $new_site_details) = @_;

    # Get the Site resultset
    my $site_rs = $self->schema->resultset('Site');

    # Find the site
    my $site = $site_rs->find($site_id);

    # Update the site
    $site->update($new_site_details) if $site;

    return $site;
}

sub delete_site {
    my ($self, $site_id) = @_;

    # Get the Site resultset
    my $site_rs = $self->schema->resultset('Site');

    # Find the site
    my $site = $site_rs->find($site_id);

    # Delete the site
    $site->delete if $site;

    return $site;
}
sub get_site_details_by_name {
    my ($self, $site_name) = @_;
    my $site_rs = $self->schema->resultset('Site');
    return $site_rs->find({ name => $site_name });
}
sub get_site_domain {
    my ($self, $domain_name) = @_;
    my $site_domain_rs = $self->schema->resultset('SiteDomain');
    my $site_domain = $site_domain_rs->find({ domain => $domain_name });
    return $site_domain;
}
sub get_site_details {
    my ($self, $site_id) = @_;
    my $site_rs = $self->schema->resultset('Site');
    my $site = $site_rs->find({ id => $site_id });
    return $site;
}
__PACKAGE__->meta->make_immutable;

1;