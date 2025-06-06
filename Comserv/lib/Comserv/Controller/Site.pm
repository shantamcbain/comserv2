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

    # Check if the user is an admin
    my $is_admin = 0;
    if ($c->session->{roles}) {
        foreach my $role (@{$c->session->{roles}}) {
            if ($role eq 'admin') {
                $is_admin = 1;
                last;
            }
        }
    }

    # Log the user's admin status
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
        "User is " . ($is_admin ? "an admin" : "not an admin"));

    # Get a DBIx::Class::Schema object
    my $schema = $c->model('DBEncy');

    # Create a simple array of site data for the template
    my @site_data = ();

    # Only show sites if the user is an admin
    if ($is_admin) {
        # Determine which sites to show based on the current site
        if (lc($current_site_name) eq 'csc') {
            # If the current site is CSC, show all sites
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
                "User is an admin on CSC site, showing all sites");

            # Directly query the database for all sites
            my $site_rs = $schema->resultset('Site');
            my @sites = $site_rs->all;

            # Log the number of sites found
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
                "Found " . scalar(@sites) . " sites in the database");

            # Convert the DBIx::Class objects to simple hashes
            foreach my $site (@sites) {
                push @site_data, {
                    id => $site->id,
                    name => $site->name
                };
            }
        } else {
            # If the current site is not CSC, show only the current site
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
                "User is an admin on non-CSC site, showing only the current site");

            # Get the current site
            my $site = $schema->resultset('Site')->find({ name => $current_site_name });

            # Add the site to the array if it exists
            if ($site) {
                push @site_data, {
                    id => $site->id,
                    name => $site->name
                };
            }
        }
    } else {
        # If the user is not an admin, don't show any sites
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
            "User is not an admin, not showing any sites");
    }

    # Pass the sites to the template
    $c->stash->{sites} = \@site_data;

    # Pass the admin status to the template
    $c->stash->{is_admin} = $is_admin;
    $c->stash->{is_csc} = (lc($current_site_name) eq 'csc') ? 1 : 0;

    # Add helpful context messages for users
    my $help_message = "You are currently in the HelpDesk support view of the main site.";
    my $account_message = "To access additional features, please create an account. Once created, you will have access to the public view of the site.";

    # Add specific message for Monashee Coop
    if (lc($current_site_name) eq 'mcoop') {
        $help_message = "Welcome to the Monashee Coop HelpDesk support portal. This is the administrative view of monasheecoop.ca.";
        $account_message = "To access the public features of the Monashee Coop site, please create an account. After registration, you will be able to view the public content.";

        # Add a link to the main website
        $c->stash->{main_website} = "https://monasheecoop.ca";
    }

    # Add messages to stash
    $c->stash->{help_message} = $help_message;
    $c->stash->{account_message} = $account_message;
    
    # Ensure debug_msg is always an array
    $c->stash->{debug_msg} = [] unless ref $c->stash->{debug_msg} eq 'ARRAY';
    push @{$c->stash->{debug_msg}}, "Site controller index view for $current_site_name";

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

    # Get Cloudflare domains to check if each domain is in Cloudflare
    my $cloudflare_domains = {};
    eval {
        # Create a CloudflareAPI controller instance
        my $cloudflare_controller = $c->controller('CloudflareAPI');
        if ($cloudflare_controller) {
            # Get the Cloudflare domains
            $cloudflare_domains = $cloudflare_controller->_get_cloudflare_domains($c);
        }
    };
    if ($@) {
        $c->log->error("Error getting Cloudflare domains: $@");
    }
    
    # Add is_on_cloudflare flag to each domain
    foreach my $domain (@site_domains) {
        my $domain_name = $domain->domain;
        
        # Skip local domains and development domains
        if ($domain_name =~ /\.local$/ || $domain_name =~ /\.test$/ || $domain_name =~ /\.dev$/ || 
            $domain_name =~ /^localhost/ || $domain_name =~ /^127\.0\.0\.1/) {
            $domain->{is_on_cloudflare} = 0;
            next;
        }
        
        my $is_on_cloudflare = exists $cloudflare_domains->{$domain_name} ? 1 : 0;
        
        # If not directly found, check if it's a subdomain of a Cloudflare zone
        if (!$is_on_cloudflare) {
            foreach my $cf_domain (keys %$cloudflare_domains) {
                if ($domain_name =~ /\.\Q$cf_domain\E$/) {
                    $is_on_cloudflare = 1;
                    last;
                }
            }
        }
        
        # Add the flag to the domain object
        $domain->{is_on_cloudflare} = $is_on_cloudflare;
        
        # Log the domain status
        $c->log->debug("Domain $domain_name is " . ($is_on_cloudflare ? "on" : "not on") . " Cloudflare");
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
    
    # Redirect back to site details
    $c->res->redirect($c->uri_for($self->action_for('details'), { id => $site_id }));
}

# Add a new method to delete a site
sub delete :Path('delete') :Args(0) {
    my ($self, $c) = @_;
    
    # Log entry into the delete method
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'delete', 'Entered site delete method');
    
    # Initialize debug arrays
    $c->stash->{debug_errors} = [] unless ref $c->stash->{debug_errors} eq 'ARRAY';
    $c->stash->{debug_msg} = [] unless ref $c->stash->{debug_msg} eq 'ARRAY';
    
    # Get the site ID from the request parameters
    my $site_id = $c->request->param('id');
    
    # If no site ID is provided, check for site name
    my $site_name = $c->request->param('name');
    
    # Log the parameters
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'delete', 
        "Delete request with ID: " . ($site_id || 'none') . ", Name: " . ($site_name || 'none'));
    
    # If neither ID nor name is provided, show an error
    if (!$site_id && !$site_name) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'delete', 
            "No site ID or name provided for deletion");
        
        push @{$c->stash->{debug_errors}}, "No site ID or name provided for deletion";
        
        $c->stash(
            template => 'site/error.tt',
            title => 'Site Deletion Error',
            error_message => 'No site ID or name provided for deletion',
        );
        return;
    }
    
    # If we have a name but no ID, look up the site by name
    if (!$site_id && $site_name) {
        my $site = $c->model('Site')->get_site_details_by_name($c, $site_name);
        if ($site) {
            $site_id = $site->id;
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'delete', 
                "Found site ID $site_id for name $site_name");
        } else {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'delete', 
                "Site with name '$site_name' not found");
            
            push @{$c->stash->{debug_errors}}, "Site with name '$site_name' not found";
            
            $c->stash(
                template => 'site/error.tt',
                title => 'Site Deletion Error',
                error_message => "Site with name '$site_name' not found",
            );
            return;
        }
    }
    
    # Now we should have a site ID
    if ($site_id) {
        # Get the site details before deletion for logging
        my $site = $c->model('Site')->get_site_details($c, $site_id);
        
        if (!$site) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'delete', 
                "Site with ID $site_id not found");
            
            push @{$c->stash->{debug_errors}}, "Site with ID $site_id not found";
            
            $c->stash(
                template => 'site/error.tt',
                title => 'Site Deletion Error',
                error_message => "Site with ID $site_id not found",
            );
            return;
        }
        
        # Store site details for confirmation
        my $site_name = $site->name;
        my $site_display_name = $site->site_display_name || $site_name;
        
        # Check if this is a confirmation request
        my $confirmed = $c->request->param('confirm');
        
        if ($confirmed) {
            # Attempt to delete the site
            eval {
                # First, delete all domains associated with this site
                my @domains = $c->model('DBEncy::SiteDomain')->search({ site_id => $site_id });
                foreach my $domain (@domains) {
                    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'delete', 
                        "Deleting domain " . $domain->domain . " for site $site_name");
                    $domain->delete;
                }
                
                # Now delete the site itself
                $c->model('Site')->delete_site($c, $site_id);
                
                # Also delete the site's controller file if it exists
                my $controller_path = "/home/shanta/PycharmProjects/comserv/Comserv/lib/Comserv/Controller/$site_name.pm";
                if (-f $controller_path) {
                    unlink($controller_path) or $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'delete', 
                        "Failed to delete controller file: $!");
                }
                
                # Delete the site's template directory if it exists
                my $template_dir = "/home/shanta/PycharmProjects/comserv/Comserv/root/$site_name";
                if (-d $template_dir) {
                    system("rm -rf $template_dir") == 0 or $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'delete', 
                        "Failed to delete template directory: $!");
                }
                
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'delete', 
                    "Successfully deleted site $site_name (ID: $site_id)");
                
                push @{$c->stash->{debug_msg}}, "Successfully deleted site $site_name";
            };
            
            if ($@) {
                # Handle deletion errors
                my $error = $@;
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'delete', 
                    "Error deleting site: $error");
                
                push @{$c->stash->{debug_errors}}, "Error deleting site: $error";
                
                $c->stash(
                    template => 'site/error.tt',
                    title => 'Site Deletion Error',
                    error_message => "Error deleting site: $error",
                );
                return;
            }
            
            # Redirect to the site list with a success message
            $c->flash->{success_msg} = "Site '$site_display_name' has been successfully deleted.";
            $c->res->redirect($c->uri_for($self->action_for('index')));
            return;
        } else {
            # Show confirmation page
            $c->stash(
                template => 'site/delete_confirm.tt',
                title => 'Confirm Site Deletion',
                site => $site,
                form_action => $c->uri_for($self->action_for('delete')),
            );
            return;
        }
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
