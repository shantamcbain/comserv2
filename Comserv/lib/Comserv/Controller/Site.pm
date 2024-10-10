package Comserv::Controller::Site;
use Moose;
use namespace::autoclean;

BEGIN { extends 'Catalyst::Controller'; }
# In your controller or script file
use Try::Tiny;
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
# Subroutine to setup site details from session
sub site_setup {
    my ($self, $c) = @_;
    my $SiteName = $c->session->{SiteName};

    unless (defined $SiteName) {
        push @{$c->stash->{error_msg}}, "SiteName is not defined in the session";
        return;
    }

    # Fetch site details by name
    my $site = $c->model('Site')->get_site_details_by_name($SiteName);

    unless ($site) {
        push @{$c->stash->{error_msg}}, "No site found for SiteName: $SiteName";
        return;
    }

    # Stash site details
    $c->stash(
        ScriptDisplayName => $site->site_display_name || 'none',
        css_view_name     => $site->css_view_name || '/static/css/default.css',
        mail_to_admin     => $site->mail_to_admin || 'none',
        mail_replyto      => $site->mail_replyto || 'helpdesk.computersystemconsulting.ca',
        template          => 'site/setup.tt',
    );
}

# Subroutine to handle domain editing


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
    my ($self, $c, $domain) = @_;
    return $c->model('DBEncy::SiteDomain')->find({ domain => $domain });
}


sub get_site_details {
    my ($self, $c, $site_id) = @_;
    return $c->model('DBEncy::SiteDomain')->find({ id => $site_id });
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
sub edit_domain :Local :Args(1) {
    my ($self, $c, $id) = @_;

    # Get the schema
    my $schema = $c->model('DBEncy');

    # Fetch site details directly from the Site resultset
    my $site = $schema->resultset('Site')->find($id);

    if ($site) {
        # Fetch domains for this site
        my @site_domains = $schema->resultset('SiteDomain')->search({ site_id => $id });

        # Pass the site and domains to the template
        $c->stash->{site} = $site;
        $c->stash->{domains} = \@site_domains;

        # If there's a POST request to modify a domain
        if ($c->request->method eq 'POST') {
            my $domain_id = $c->request->parameters->{domain_id};
            my $new_domain = $c->request->parameters->{new_domain};

            # Update domain logic here
            my $domain = $schema->resultset('SiteDomain')->find($domain_id);
            if ($domain) {
                $domain->update({ domain => $new_domain });
                $c->flash->{message} = 'Domain updated successfully';
            } else {
                $c->flash->{error} = 'Domain not found';
            }
            $c->res->redirect($c->uri_for($self->action_for('details'), [$id]));
            return;
        }

        # Set the template to edit_domain.tt instead of site/index.tt
        $c->stash(template => 'site/edit_domain.tt');
    } else {
        $c->flash->{error} = 'Site not found';
        $c->res->redirect($c->uri_for($self->action_for('index')));
    }
}

sub edit_domain_post :Local {
    my ($self, $c) = @_;

    # Get the site_id and domain from the form parameters
    my $site_id = $c->request->parameters->{site_id};
    my $new_domain = $c->request->parameters->{domain};

    # Validate inputs
    my @errors;
    push @errors, 'Site ID is required.' unless $site_id;
    push @errors, 'Domain is required.' unless $new_domain;

    if (@errors) {
        # Pass the errors to the template and redisplay the form
        $c->stash->{error_msgs} = \@errors;
        $c->forward('edit_domain', [$site_id]);
        return;
    }

    # Update the domain in the SiteDomain table
    my $site_domain = $c->model('DBEncy::SiteDomain')->find({ site_id => $site_id });
    if ($site_domain) {
        try {
            $site_domain->update({ domain => $new_domain });
            $c->flash->{success_msg} = 'Domain updated successfully';
            $c->res->redirect($c->uri_for('/site/details', { id => $site_id }));
        } catch {
            push @errors, "Failed to update domain: $_";
            $c->stash->{error_msgs} = \@errors;
            $c->forward('edit_domain', [$site_id]);
        };
    } else {
        $c->flash->{error} = 'Domain not found';
        $c->res->redirect($c->uri_for('/site'));
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
