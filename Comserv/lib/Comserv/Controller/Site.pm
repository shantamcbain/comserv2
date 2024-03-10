package Comserv::Controller::Site;
use Moose;
use namespace::autoclean;

BEGIN { extends 'Catalyst::Controller'; }
# In your controller or script file
use Comserv::Model::Site;



sub index :Path :Args(0) {
    my ( $self, $c ) = @_;
# Get a DBIx::Class::Schema object
my $schema = $c->model('DBEncy');

# Create a new Comserv::Model::Site object
my $site_model = Comserv::Model::Site->new(schema => $schema);
   # Get all sites
    my $sites = $c->model('Site')->get_all_sites();

    # Pass the sites to the template
    $c->stash->{sites} = $sites;

    # Set the template to site/index.tt
    $c->stash(template => 'site/index.tt');
}
sub add_site :Local {
    my ($self, $c) = @_;

    # Get the site details from the request
    my $site = $c->request->body_parameters;

    # Check for empty strings in integer fields and set them to 0
    for my $field (qw(affiliate pid app_logo_width app_logo_height)) {
        if (exists $site->{$field} && $site->{$field} eq '') {
            $site->{$field} = 0;
        }
    }

    # Get a DBIx::Class::Schema object
    my $schema = $c->model('DBEncy');

    # Get the Site resultset
    my $site_rs = $schema->resultset('Site');

    # Add the site to the database
    $site_rs->create($site);

    # Pass a success message to the template
    $c->flash->{message} = 'Site added successfully';

    # Redirect to the add_site_form action
    $c->res->redirect($c->uri_for($self->action_for('add_site_form')));
}
sub add_site_form :Local {
    my ($self, $c) = @_;

    # Your code here...

    # Set the template to site/add_site_form.tt
    $c->stash(template => 'site/add_site_form.tt');
}
sub details :Local {
    my ($self, $c) = @_;

    # Get the site id from the query parameters
    my $site_id = $c->request->query_parameters->{id};

    # If site_id is not defined, get it from the form parameters
    $site_id = $c->request->parameters->{site_id} unless defined $site_id;

    # Get a DBIx::Class::Schema object
    my $schema = $c->model('DBEncy');

    # Get the Site resultset
    my $site_rs = $schema->resultset('Site');

    # Get the site
    my $site = $site_rs->find($site_id);

    # Fetch rows from the SiteDomain table related to a specific site
    my @site_domains = $c->model('DBEncy::SiteDomain')->search({ site_id => $site_id });

    # Pass the site and domains to the template
    $c->stash->{site} = $site;
    $c->stash->{domains} = \@site_domains;

    # If domain is defined in the form parameters, insert a new row into the SiteDomain table
    if (my $domain = $c->request->parameters->{domain}) {
        $c->model('DBEncy::SiteDomain')->create({
            site_id => $site_id,
            domain => $domain,
        });
    }

    # Set the template to site/details.tt
    $c->stash(template => 'site/details.tt');
}
sub get_site_domain {
    my ($self, $domain) = @_;
    return $self->resultset('SiteDomain')->find({ domain => $domain });
}

sub get_site_details {
    my ($self, $site_id) = @_;
    return $self->resultset('Site')->find({ id => $site_id });
}


1;
