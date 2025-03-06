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
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', 'Enter in index');

    # Get the current site name from the session
    my $current_site_name = $c->session->{SiteName};

    # Log the current site name
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',"Got current site name $current_site_name");

    # Get a DBIx::Class::Schema object
    my $schema = $c->model('DBEncy');

    # Create a new Comserv::Model::Site object
    my $site_model = Comserv::Model::Site->new(schema => $schema);

    # Determine which sites to fetch based on the current site name
    my $sites;
    if (lc($current_site_name) eq 'csc') {
        # If the current site is 'csc', fetch all sites
        $sites = $site_model->get_all_sites($c);
    } else {
        # Otherwise, fetch only the current site
        my $site = $site_model->get_site_details_by_name($c, $current_site_name);
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

    # Create a new Comserv::Model::Site object
    my $site_model = Comserv::Model::Site->new(schema => $schema);

    # Get the site using the Site model to handle theme column issues
    my $site = $site_model->get_site_details($c, $site_id);

    # Fetch rows from the SiteDomain table related to a specific site
    my @site_domains;
    eval {
        @site_domains = $c->model('DBEncy::SiteDomain')->search({ site_id => $site_id });
    };
    if ($@) {
        $c->log->error("Error fetching site domains: $@");
        @site_domains = ();
    }

    # Pass the site and domains to the template
    $c->stash->{site} = $site;
    $c->stash->{domains} = \@site_domains;

    # If domain is defined in the form parameters, insert a new row into the SiteDomain table
    if (my $domain = $c->request->parameters->{domain}) {
        eval {
            $c->model('DBEncy::SiteDomain')->create({
                site_id => $site_id,
                domain => $domain,
            });
        };
        if ($@) {
            $c->log->error("Error creating site domain: $@");
            $c->flash->{error_msg} = "Error adding domain: $@";
        }
    }

    # Add a message about the theme column if needed
    if (!$site || !$site->can('theme') || !defined $site->theme) {
        $c->flash->{error_msg} = "The theme feature requires a database update. Please run the add_theme_column.pl script.";
        # Add a default theme property
        $site->{theme} = 'default' if $site;
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
        my $new_domain_record = $c->model('Site')->get_site_domain($c, $new_domain);

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
    my $site_id = $c->request->parameters->{site_id};

    eval {
        my $domain = $c->model('DBEncy::SiteDomain')->find($domain_id);
        if ($domain) {
            $domain->delete;
            $c->flash->{success_msg} = "Domain deleted successfully.";
        } else {
            $c->flash->{error_msg} = "Domain not found.";
        }
    };
    if ($@) {
        $c->log->error("Error deleting domain: $@");
        $c->flash->{error_msg} = "Error deleting domain: $@";
    }

    $c->res->redirect($c->uri_for($self->action_for('details'), { id => $site_id }));
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

    # Create a new Comserv::Model::Site object
    my $site_model = Comserv::Model::Site->new(schema => $schema);

    # Handle the theme column issue
    my $site;
    eval {
        # Get the Site resultset
        my $site_rs = $schema->resultset('Site');

        # Find the site
        $site = $site_rs->find($site_id);

        # Check if the site exists
        if ($site) {
            # If theme is in the new_site_details but the column doesn't exist, remove it
            if (exists $new_site_details->{theme}) {
                # Try to update with theme
                eval {
                    $site->update($new_site_details);
                };

                # If there's an error about the theme column
                if ($@ && $@ =~ /Unknown column 'me\.theme'/) {
                    # Log the error
                    $c->log->error("Theme column doesn't exist in sites table. Please run the add_theme_column.pl script.");

                    # Remove theme from the details
                    my $filtered_details = {%$new_site_details};
                    delete $filtered_details->{theme};

                    # Update without theme
                    $site->update($filtered_details);

                    # Add a message to the flash
                    $c->flash->{error_msg} = "The theme feature requires a database update. Please run the add_theme_column.pl script.";
                }
            } else {
                # Update without theme
                $site->update($new_site_details);
            }

            # Redirect to the details page for the site
            $c->flash->{success_msg} = 'Site updated successfully.';
            $c->res->redirect($c->uri_for($self->action_for('index')));
        } else {
            # Redirect to the details page with an error message
            $c->flash->{error_msg} = 'Site not found';
            $c->res->redirect($c->uri_for($self->action_for('details'), { id => $site_id }));
        }
    };

    # If there's an error
    if ($@) {
        # If there's an error about the theme column
        if ($@ =~ /Unknown column 'me\.theme'/) {
            # Log the error
            $c->log->error("Theme column doesn't exist in sites table. Please run the add_theme_column.pl script.");

            # Get site without theme column
            my $site_rs = $schema->resultset('Site');
            $site = $site_rs->find(
                { id => $site_id },
                { columns => [qw(id name description affiliate pid auth_table home_view app_logo app_logo_alt
                                app_logo_width app_logo_height css_view_name mail_from mail_to mail_to_discussion
                                mail_to_admin mail_to_user mail_to_client mail_replyto site_display_name
                                document_root_url link_target http_header_params image_root_url
                                global_datafiles_directory templates_cache_directory app_datafiles_directory
                                datasource_type cal_table http_header_description http_header_keywords)] }
            );

            # If site exists, update it without theme
            if ($site) {
                # Remove theme from the details
                my $filtered_details = {%$new_site_details};
                delete $filtered_details->{theme};

                # Update without theme
                $site->update($filtered_details);

                # Add a default theme property
                $site->{theme} = 'default';

                # Add a message to the flash
                $c->flash->{error_msg} = "The theme feature requires a database update. Please run the add_theme_column.pl script.";
                $c->flash->{success_msg} = 'Site updated successfully (without theme).';
                $c->res->redirect($c->uri_for($self->action_for('index')));
            } else {
                # Redirect to the details page with an error message
                $c->flash->{error_msg} = 'Site not found';
                $c->res->redirect($c->uri_for($self->action_for('details'), { id => $site_id }));
            }
        } else {
            # For other errors, log and redirect with error message
            $c->log->error("Error updating site: $@");
            $c->flash->{error_msg} = "Error updating site: $@";
            $c->res->redirect($c->uri_for($self->action_for('details'), { id => $site_id }));
        }
    }
}
sub fetch_available_sites :Private {
    my ($self, $c) = @_;

    # Get the current site name from the session
    my $current_site_name = $c->session->{SiteName};

    # Get a DBIx::Class::Schema object
    my $schema = $c->model('DBEncy');

    # Create a new Comserv::Model::Site object
    my $site_model = Comserv::Model::Site->new(schema => $schema);

    # Determine which sites to fetch based on the current site name
    my $sites;
    if (lc($current_site_name) eq 'csc') {
        # If the current site is 'csc', fetch all sites
        $sites = $site_model->get_all_sites($c);
    } else {
        # Otherwise, fetch only the current site
        my $site = $site_model->get_site_details_by_name($c, $current_site_name);
        $sites = [$site] if $site;
    }

    return $sites;
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
