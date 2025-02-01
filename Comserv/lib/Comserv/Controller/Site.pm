
package Comserv::Controller::Site;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;
BEGIN { extends 'Catalyst::Controller'; }
# In your controller or script file
use Try::Tiny;
use Comserv::Model::Site;
has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);
sub index :Path :Args(0) {
    my ( $self, $c ) = @_;

    # Log entry into the index method
    $self->logging->log_with_details($c, __FILE__, __LINE__, 'index', 'Enter in index');

    # Get the current site name from the session
    my $current_site_name = $c->session->{SiteName};

    # Log the current site name
    $self->logging->log_with_details($c, __FILE__, __LINE__, 'index',"Got current site name $current_site_name");

    # Get a DBIx::Class::Schema object
    my $schema = $c->model('DBEncy');

    # Create a new Comserv::Model::Site object
    my $site_model = Comserv::Model::Site->new(schema => $schema);

    # Determine which sites to fetch based on the current site name
    my $sites;
    if (lc($current_site_name) eq 'csc') {
        # If the current site is 'csc', fetch all sites
        $sites = $site_model->get_all_sites();
    } else {
        # Otherwise, fetch only the current site
        my $site = $site_model->get_site_details_by_name($current_site_name);
        $sites = [$site] if $site;
    }

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

# Add the new method to handle adding a domain
sub add_domain :Local {
    my ($self, $c) = @_;

    # Get the site_id from the request parameters
    my $site_id = $c->request->parameters->{site_id};

    # Get the new_domain from the request parameters
    my $new_domain = $c->request->parameters->{new_domain};

    # Check if the new_domain is defined and not empty
    if (defined $new_domain && $new_domain ne '') {
        # Create a new record in the SiteDomain table
        my $site_domain = $c->model('DBEncy::SiteDomain')->create({
            site_id => $site_id,
            domain => $new_domain,
        });

        # Fetch the newly created site domain
        my $new_domain_record = $c->model('Site')->get_site_domain($new_domain);

        # Pass the new domain to the template
        $c->stash->{new_domain} = $new_domain_record;

        # Redirect the user back to the site details page
        # Pass the site ID to ensure the correct details page is loaded
        $c->res->redirect($c->uri_for($self->action_for('details'), { id => $site_id }));
    } else {
        # Handle the error case where the domain is not provided
        $c->flash->{error} = 'Domain cannot be empty';
        $c->res->redirect($c->uri_for($self->action_for('details'), { id => $site_id }));
    }
}

sub get_site_domain {
    my ($self, $domain) = @_;
    return $self->resultset('SiteDomain')->find({ domain => $domain });
}

sub get_site_details {
    my ($self, $site_id) = @_;
    return $self->resultset('Site')->find({ id => $site_id });
}

sub delete_domain :Local {
    my ($self, $c) = @_;
    my $domain_id = $c->request->parameters->{domain_id};
    $c->model('DBEncy::SiteDomain')->find($domain_id)->delete;
    $c->res->redirect($c->uri_for($self->action_for('details'), [$c->request->parameters->{site_id}]));
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



# Add the following subroutine to `Comserv/lib/Comserv/Controller/Site.pm`
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
