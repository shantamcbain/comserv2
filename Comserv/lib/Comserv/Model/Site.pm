package Comserv::Model::Site;

use Moose;
use namespace::autoclean;
use Try::Tiny;

extends 'Catalyst::Model';

has 'schema' => (
    is => 'ro',
    required => 1,
);

sub COMPONENT {
    my ($class, $app, $args) = @_;

    my $schema = $app->model('DBEncy')->schema;
    return $class->new({ %$args, schema => $schema });
}

sub get_all_sites {
    my ($self) = @_;
    $self->schema->storage->ensure_connected;
    my $site_rs = $self->schema->resultset('Site');
    my @sites = $site_rs->all;
    return \@sites;
}

sub get_site_domain {
    my ($self, $domain) = @_;
    try {
        my $result = $self->schema->resultset('SiteDomain')->find({ domain => $domain });
        return $result;
    } catch {
        if ($_ =~ /Table 'ency\.sitedomain' doesn't exist/) {
            Catalyst::Exception->throw("Schema update required");
        } else {
            die $_;
        }
    };
}

sub add_site {
    my ($self, $site_details) = @_;
    my $site_rs = $self->schema->resultset('Site');
    my $new_site = $site_rs->create($site_details);
    return $new_site;
}

sub update_site {
    my ($self, $site_id, $new_site_details) = @_;
    my $site_rs = $self->schema->resultset('Site');
    my $site = $site_rs->find($site_id);
    $site->update($new_site_details) if $site;
    return $site;
}

sub delete_site {
    my ($self, $site_id) = @_;
    my $site_rs = $self->schema->resultset('Site');
    my $site = $site_rs->find($site_id);
    $site->delete if $site;
    return $site;
}

sub get_site_details_by_name {
    my ($self, $site_name) = @_;
    my $site_rs = $self->schema->resultset('Site');
    return $site_rs->find({ name => $site_name });
}

sub get_site_details {
    my ($self, $site_id) = @_;
    my $site_rs = $self->schema->resultset('Site');
    my $site = $site_rs->find({ id => $site_id });
    return $site;
}

__PACKAGE__->meta->make_immutable;

1;