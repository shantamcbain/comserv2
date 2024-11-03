package Comserv::Controller::Site;
use Moose;
use namespace::autoclean;
use Try::Tiny;

BEGIN { extends 'Catalyst::Controller'; }

sub index :Path :Args(0) {
    my ( $self, $c ) = @_;

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

sub add_domain :Local {
    my ($self, $c) = @_;

    # Fetch the list of sites
    my $schema = $c->model('DBEncy');
    my @sites = $schema->resultset('Site')->all;

    # Pass the list of sites to the template
    $c->stash->{sites} = \@sites;  # Changed to \@sites to avoid unintended interpolation

    # Set the template to site/add_domain.tt
    $c->stash(template => 'site/add_domain.tt');
}

sub add_domain_post :Local {
    my ($self, $c) = @_;

    # Get the site_id and domain from the form parameters
    my $site_id = $c->request->parameters->{site_id};
    my $domain = $c->request->parameters->{domain};

    # Store the received parameters in the stash
    $c->stash->{received_params} = { site_id => $site_id, domain => $domain };

    # Initialize an array to accumulate errors
    my @errors;

    # Validate input
    push @errors, 'Site ID is required.' unless $site_id;
    push @errors, 'Domain is required.' unless $domain;

    if (@errors) {
        $c->stash->{error_msgs} = \@errors;
        $c->forward('add_domain');
        return;
    }

    # Insert the new domain into the SiteDomain table
    try {
        $c->model('DBEncy::SiteDomain')->create({
            site_id => $site_id,
            domain => $domain,
        });
        $c->flash->{success_msg} = 'Domain added successfully';
        $c->res->redirect($c->uri_for('/site/details', { id => $site_id }));
    } catch {
        push @errors, "Failed to add domain: $_";
        $c->stash->{error_msgs} = \@errors;
        $c->stash(template => 'site/add_domain.tt');
        $c->forward('add_domain');
    };
}

1;
