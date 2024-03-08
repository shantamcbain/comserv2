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

    # Add the site to the database
    my $new_site = $c->model('Site')->add_site($site);

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
sub modify :Local {
    my ($self, $c) = @_;

    # Get the site id from the query parameters
    my $site_id = $c->request->query_parameters->{id};

    # Get the new site details from the request body
    my $new_site_details = $c->request->body_parameters;
  # Check for empty strings in integer fields and set them to 0
    for my $field (qw(affiliate pid app_logo_width app_logo_height)) {
        if (exists $new_site_details->{$field} && $new_site_details->{$field} eq '') {
            $new_site_details->{$field} = 0;
        }
    }

    # Get a DBIx::Class::Schema object
    my $schema = $c->model('DBEncy');

    # Get the Site resultset
    my $site_rs = $schema->resultset('Site');

    # Find the site
    my $site = $site_rs->find($site_id);

    # Check if the site exists
    if ($site) {
        # Update the site
        $site->update($new_site_details);

        # Redirect to the details page for the site
           $c->flash->{error} = 'You made the change.';
    $c->res->redirect($c->uri_for($self->action_for('index')));
    } else {
        # Redirect to the details page with an error message
        $c->flash->{error} = 'Site not found';
        $c->res->redirect($c->uri_for($self->action_for('details'), [$site_id]));
    }
}

sub delete :Local {
    my ($self, $c) = @_;

    # Get the site id from the query parameters
    my $site_id = $c->request->query_parameters->{id};

    # Get a DBIx::Class::Schema object
    my $schema = $c->model('DBEncy');

    # Get the Site resultset
    my $site_rs = $schema->resultset('Site');

    # Find the site
    my $site = $site_rs->find($site_id);

    # Check if the site exists
    if ($site) {
        # Delete the site
        $site->delete;

        # Redirect to the index page
        $c->res->redirect($c->uri_for($self->action_for('index')));
    } else {
        # Redirect to the index page with an error message
        $c->flash->{error} = 'Site not found';
        $c->res->redirect($c->uri_for($self->action_for('index')));
    }
}
sub add_domain :Local :Args(0) {
    my ($self, $c) = @_;

    # Get the form data
    my $site_id = $c->request->body_parameters->{site_id};
    my $new_domain = $c->request->body_parameters->{new_domain};
   # Print the values for debugging
    print "site_id: $site_id\n";
    print "new_domain: $new_domain\n";

    # Insert a new row into the SiteDomain table
    $c->model('DBEncy::SiteDomain')->create({
        site_id => $site_id,
        domain => $new_domain,
    });

    # Redirect back to the details page
    $c->res->redirect($c->uri_for($self->action_for('details'), [$site_id]));
}
sub edit_domain :Local :Args(1) {
    my ($self, $c, $domain_id) = @_;

    # Get a DBIx::Class::Schema object
    my $schema = $c->model('DBEncy');

    # Get the SiteDomain resultset
    my $domain_rs = $schema->resultset('SiteDomain');

    # Find the domain
    my $domain = $domain_rs->find($domain_id);

    # If the domain is not found, return an error message
    unless ($domain) {
        $c->res->body('Domain not found');
        return;
    }

    # If the form is submitted (POST request)
    if ($c->request->method eq 'POST') {
        # Get the new site_id and domain from the request parameters
        my $new_site_id = $c->request->parameters->{site_id};
        my $new_domain = $c->request->parameters->{domain};

        # Update the domain with the new site_id and domain
        $domain->update({
            site_id => $new_site_id,
            domain => $new_domain,
        });

        # Redirect back to the referring page
        $c->res->redirect($c->req->referer || $c->uri_for('/'));
    } else {
        # Get all the sites and sort them by name
        my @sites = sort { $a->name cmp $b->name } $schema->resultset('Site')->all;

        # Pass the domain and sites to the template
        $c->stash->{domain} = $domain;
        $c->stash->{sites} = \@sites;

        # Set the template to site/edit_domain.tt
        $c->stash(template => 'site/edit_domain.tt');
    }
}
sub list_domains :Local {
    my ($self, $c) = @_;

    # Get a DBIx::Class::Schema object
    my $schema = $c->model('DBEncy');

    # Get the SiteDomain resultset
    my $domain_rs = $schema->resultset('SiteDomain');

    # Get all domains
    my @domains = $domain_rs->all;

    # Pass the domains to the template
    $c->stash->{domains} = \@domains;

    # Set the template to site/list_domains.tt
    $c->stash(template => 'site/list_domains.tt');
}
__PACKAGE__->meta->make_immutable;

1;
