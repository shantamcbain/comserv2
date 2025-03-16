package Comserv::Controller::Root;
use Moose;
use namespace::autoclean;
use Template;
use Data::Dumper;
use DateTime;
use JSON;
use Comserv::Util::Logging;
use Comserv::Util::ThemeManager;

# Configure static file serving
__PACKAGE__->config(
    'Plugin::Static::Simple' => {
        dirs => ['static'],
        include_path => [qw( root )],
    });

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

has 'theme_manager' => (
    is => 'ro',
    default => sub { Comserv::Util::ThemeManager->new }
);

# Add user_exists method
sub user_exists {
    my ($self, $c) = @_;
    return ($c->session->{username} && $c->session->{user_id}) ? 1 : 0;
}

# Flag to track if application start has been recorded
has '_application_start_tracked' => (
    is => 'rw',
    isa => 'Bool',
    default => 0
);

# Flag to track if theme CSS files have been generated
has '_theme_css_generated' => (
    is => 'rw',
    isa => 'Bool',
    default => 0
);

BEGIN { extends 'Catalyst::Controller' }

__PACKAGE__->config(namespace => '');

sub index :Path('/') :Args(0) {
    my ($self, $c) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Starting index action. User exists: " . ($self->user_exists($c) ? 'Yes' : 'No'));
    $c->stash->{forwarder} = '/'; # Set a default forward path

    # Get ControllerName from the session
    my $ControllerName = $c->session->{ControllerName} || undef; # Default to undef if not set
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Fetched ControllerName from session: " . ($ControllerName // 'undefined'));

    if ($ControllerName && $ControllerName ne 'Root') {
        # Check if the controller exists before attempting to detach
        my $controller_exists = 0;
        eval {
            # Try to get the controller object
            my $controller = $c->controller($ControllerName);
            $controller_exists = 1 if $controller;
        };

        if ($controller_exists) {
            # Forward to the controller's index action
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Forwarding to $ControllerName controller's index action");
            $c->detach($ControllerName, 'index');
        } else {
            # Log the error and fall back to Root's index template
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'index',
                "Controller '$ControllerName' not found or not loaded. Falling back to Root's index template.");

            # Set a flash message for debugging
            $c->flash->{error_msg} = "Controller '$ControllerName' not found. Please try again or contact the administrator.";

            # Default to Root's index template
            $c->stash(template => 'index.tt');
            $c->forward($c->view('TT'));
        }
    } else {
        # Default to Root's index template
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Defaulting to Root's index template");
        $c->stash(template => 'index.tt');
        $c->forward($c->view('TT'));
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Completed index action");
    return 1; # Allow the request to proceed
}


sub set_theme {
    my ($self, $c) = @_;

    # Get the site name
    my $site_name = $c->stash->{SiteName} || $c->session->{SiteName} || 'default';

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'set_theme', "Setting theme for site: $site_name");

    # Get all available themes
    my $all_themes = $self->theme_manager->get_all_themes($c);
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'set_theme',
        "Available themes: " . join(", ", sort keys %$all_themes));

    # Get the theme for this site from our theme manager
    my $theme_name = $self->theme_manager->get_site_theme($c, $site_name);

    # Make sure the theme exists
    if (!exists $all_themes->{$theme_name}) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'set_theme',
            "Theme '$theme_name' not found in available themes, defaulting to 'default'");
        $theme_name = 'default';
    }

    # Add the theme name to the stash
    $c->stash->{theme_name} = $theme_name;

    # Add all available themes to the stash
    $c->stash->{available_themes} = [sort keys %$all_themes];

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'set_theme',
        "Set theme for site $site_name to $theme_name");
}

sub fetch_and_set {
    my ($self, $c, $param) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'fetch_and_set', "Starting fetch_and_set action");

    my $value = $c->req->query_parameters->{$param};

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'fetch_and_set', "Checking query parameter '$param'");

    if (defined $value) {
        $c->stash->{SiteName} = $value;
        $c->session->{SiteName} = $value;
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'fetch_and_set', "Query parameter '$param' found: $value");
    } elsif (defined $c->session->{SiteName}) {
        $c->stash->{SiteName} = $c->session->{SiteName};
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'fetch_and_set', "SiteName found in session: " . $c->session->{SiteName});
    } else {
        my $domain = $c->req->uri->host;
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'fetch_and_set', "Extracted domain: $domain");

        my $site_domain = $c->model('Site')->get_site_domain($c, $domain);
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'fetch_and_set', "Site domain retrieved: " . Dumper($site_domain));

        if ($site_domain) {
            my $site_id = $site_domain->site_id;
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'fetch_and_set', "Site ID: $site_id");

            my $site = $c->model('Site')->get_site_details($c, $site_id);
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'fetch_and_set', "Site details retrieved: " . Dumper($site));

            if ($site) {
                $value = $site->name;
                $c->stash->{SiteName} = $value;
                $c->session->{SiteName} = $value;
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'fetch_and_set', "SiteName set to: $value");

                # Set ControllerName based on the site's home_view
                my $home_view = $site->home_view || 'Root';  # Ensure this is domain-specific

                # Verify the controller exists before setting it
                my $controller_exists = 0;
                eval {
                    my $controller = $c->controller($home_view);
                    $controller_exists = 1 if $controller;
                };

                if ($controller_exists) {
                    $c->stash->{ControllerName} = $home_view;
                    $c->session->{ControllerName} = $home_view;
                    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'fetch_and_set', "ControllerName set to: $home_view");
                } else {
                    # If controller doesn't exist, fall back to Root
                    $self->logging->log_with_details($c, 'warning', __FILE__, __LINE__, 'fetch_and_set',
                        "Controller '$home_view' not found or not loaded. Falling back to 'Root'.");
                    $c->stash->{ControllerName} = 'Root';
                    $c->session->{ControllerName} = 'Root';
                }
            }
        } else {
            $c->session->{SiteName} = 'none';
            $c->stash->{SiteName} = 'none';
            $c->session->{ControllerName} = 'Root';
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'fetch_and_set', "No site domain found, defaulting SiteName and ControllerName to 'none' and 'Root'");
        }
    }

    return $value;
}

sub track_application_start {
    my ($self, $c) = @_;

    # Only track once per application start
    return if $self->_application_start_tracked;
    $self->_application_start_tracked(1);

    # Get the current date
    my $current_date = DateTime->now->ymd; # Format: YYYY-MM-DD

    # Path to the JSON file
    my $json_file = $c->path_to('root', 'Documentation', 'completed_items.json');

    # Check if the file exists
    if (-e $json_file) {
        # Read the JSON file
        open my $fh, '<:encoding(UTF-8)', $json_file or do {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'track_application_start', "Cannot open $json_file for reading: $!");
            return;
        };
        my $json_content = do { local $/; <$fh> };
        close $fh;

        # Parse the JSON content
        my $data;
        eval {
            $data = decode_json($json_content);
        };
        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'track_application_start', "Error parsing JSON: $@");
            return;
        }

        # Check if we already have any application start entry
        my $entry_exists = 0;
        my $latest_start_date = '';

        foreach my $item (@{$data->{completed_items}}) {
            if ($item->{item} =~ /^Application started/) {
                # Keep track of the latest application start date
                if ($item->{date_created} gt $latest_start_date) {
                    $latest_start_date = $item->{date_created};
                }

                # If we already have an entry for today, mark it as existing
                if ($item->{date_created} eq $current_date) {
                    $entry_exists = 1;
                }
            }
        }

        # If we have a previous application start entry but not for today,
        # update that entry instead of creating a new one
        if (!$entry_exists && $latest_start_date ne '') {
            for my $i (0 .. $#{$data->{completed_items}}) {
                my $item = $data->{completed_items}[$i];
                if ($item->{item} =~ /^Application started/ && $item->{date_created} eq $latest_start_date) {
                    # Update the existing entry with today's date
                    $data->{completed_items}[$i]->{item} = "Application started on $current_date";
                    $data->{completed_items}[$i]->{date_created} = $current_date;
                    $data->{completed_items}[$i]->{date_completed} = $current_date;
                    $entry_exists = 1; # Mark as existing so we don't create a new one

                    # Write the updated data back to the file
                    open my $fh, '>:encoding(UTF-8)', $json_file or do {
                        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'track_application_start', "Cannot open $json_file for writing: $!");
                        return;
                    };

                    eval {
                        print $fh encode_json($data);
                    };
                    if ($@) {
                        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'track_application_start', "Error encoding JSON: $@");
                        close $fh;
                        return;
                    }

                    close $fh;
                    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'track_application_start', "Updated application start entry to $current_date");
                    last;
                }
            }
        }

        # If no entry exists for today, add one
        if (!$entry_exists) {
            # Create a new entry
            my $new_entry = {
                item => "Application started on $current_date",
                status => "completed",
                date_created => $current_date,
                date_completed => $current_date,
                commit => "system" # Indicate this is a system-generated entry
            };

            # Add the new entry to the data
            push @{$data->{completed_items}}, $new_entry;

            # Write the updated data back to the file
            open my $fh, '>:encoding(UTF-8)', $json_file or do {
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'track_application_start', "Cannot open $json_file for writing: $!");
                return;
            };

            eval {
                print $fh encode_json($data);
            };
            if ($@) {
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'track_application_start', "Error encoding JSON: $@");
                close $fh;
                return;
            }

            close $fh;
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'track_application_start', "Added application start entry for $current_date");
        } else {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'track_application_start', "Application start entry for $current_date already exists");
        }
    } else {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'track_application_start', "JSON file $json_file does not exist");
    }
}

sub auto :Private {
    my ($self, $c) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "Starting auto action");

    # Track application start
    $c->stash->{forwarder} = $c->req->path; # Store current path as potential redirect target
    $self->track_application_start($c);

    # Log the request path
    my $path = $c->req->path;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "Request path: '$path'");

    # Generate theme CSS files if they don't exist
    # We only need to do this once per application start
    if (!$self->_theme_css_generated) {
        $self->theme_manager->generate_all_theme_css($c);
        $self->_theme_css_generated(1);
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "Generated all theme CSS files");
    }

    # Perform general setup tasks
    $self->setup_debug_mode($c);
    $self->setup_site($c);
    $self->set_theme($c);
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "Completed general setup tasks");

    # Call the index action only for the root path
    if ($path eq '/' || $path eq '') {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "Calling index action for root path");

        # Check if we have a ControllerName in the session that might cause issues
        my $ControllerName = $c->session->{ControllerName} || '';
        if ($ControllerName && $ControllerName ne 'Root') {
            # Verify the controller exists before proceeding
            my $controller_exists = 0;
            eval {
                my $controller = $c->controller($ControllerName);
                $controller_exists = 1 if $controller;
            };

            if (!$controller_exists) {
                $self->logging->log_with_details($c, 'warning', __FILE__, __LINE__, 'auto',
                    "Controller '$ControllerName' not found or not loaded. Setting ControllerName to 'Root'.");
                $c->session->{ControllerName} = 'Root';
                $c->stash->{ControllerName} = 'Root';
            }
        }

        $self->index($c);
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "Completed auto action");
    return 1; # Allow the request to proceed
}

sub setup_debug_mode {
    my ($self, $c) = @_;

    if (defined $c->req->params->{debug}) {
        $c->session->{debug_mode} = $c->session->{debug_mode} ? 0 : 1;
    }
    $c->stash->{debug_mode} = $c->session->{debug_mode};
}

sub send_email {
    my ($self, $c, $params) = @_;

    # Log the email attempt
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'send_email',
        "Attempting to send email to: " . $params->{to} . " with subject: " . $params->{subject});

    # Use Email::Simple and Email::Sender::Simple for basic email functionality
    eval {
        require Email::Simple;
        require Email::Sender::Simple;
        Email::Sender::Simple->import(qw(sendmail));

        my $email = Email::Simple->create(
            header => [
                To      => $params->{to},
                From    => $params->{from} || 'noreply@computersystemconsulting.ca',
                Subject => $params->{subject},
            ],
            body => $params->{body},
        );

        sendmail($email);
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'send_email',
            "Email sent successfully to: " . $params->{to});
        return 1;
    };

    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'send_email',
            "Failed to send email: $@");
        return 0;
    }
}

sub setup_site {
    my ($self, $c) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'setup_site', "Starting setup_site action");

    # Initialize debug_errors array if it doesn't exist
    $c->stash->{debug_errors} //= [];

    my $SiteName = $c->session->{SiteName};

    # Get the current domain
    my $domain = $c->req->uri->host;
    $domain =~ s/:.*//;  # Remove port if present
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'setup_site', "Extracted domain: $domain");

    # Store domain in session for debugging
    $c->session->{Domain} = $domain;

    if (!defined $SiteName || $SiteName eq 'none' || $SiteName eq 'root') {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'setup_site', "SiteName is either undefined, 'none', or 'root'. Proceeding with domain extraction and site domain retrieval");

        # Get the domain from the sitedomain table
        my $site_domain = $c->model('Site')->get_site_domain($c, $domain);

        if ($site_domain) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'setup_site', "Found site domain for $domain");

            my $site_id = $site_domain->site_id;
            my $site = $c->model('Site')->get_site_details($c, $site_id);

            if ($site) {
                $SiteName = $site->name;
                $c->stash->{SiteName} = $SiteName;
                $c->session->{SiteName} = $SiteName;

                # Set ControllerName based on the site's home_view
                my $home_view = $site->home_view || $site->name || 'Root';  # Use home_view if available

                # Verify the controller exists before setting it
                my $controller_exists = 0;
                eval {
                    my $controller = $c->controller($home_view);
                    $controller_exists = 1 if $controller;
                };

                if ($controller_exists) {
                    $c->stash->{ControllerName} = $home_view;
                    $c->session->{ControllerName} = $home_view;
                    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'setup_site', "ControllerName set to: $home_view");
                } else {
                    # If controller doesn't exist, fall back to Root
                    $self->logging->log_with_details($c, 'warning', __FILE__, __LINE__, 'setup_site',
                        "Controller '$home_view' not found or not loaded. Falling back to 'Root'.");
                    $c->stash->{ControllerName} = 'Root';
                    $c->session->{ControllerName} = 'Root';
                }
            }
        } elsif ($c->stash->{domain_error}) {
            # We have a specific domain error from the get_site_domain method
            my $domain_error = $c->stash->{domain_error};
            my $error_type = $domain_error->{type};
            my $error_msg = $domain_error->{message};
            my $technical_details = $domain_error->{technical_details};
            my $action_required = $domain_error->{action_required} || "Please contact the system administrator.";

            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'setup_site',
                "DOMAIN ERROR ($error_type): $error_msg - $technical_details");

            # Set default site for error handling
            $SiteName = 'CSC'; # Default to CSC
            $c->stash->{SiteName} = $SiteName;
            $c->session->{SiteName} = $SiteName;

            # Force Root controller to show error page
            $c->stash->{ControllerName} = 'Root';
            $c->session->{ControllerName} = 'Root';

            # Set up site basics to get admin email
            $self->site_setup($c, $SiteName);

            # Set flash error message to ensure it's displayed
            $c->flash->{error_msg} = "Domain Error: $error_msg";

            # Send email notification to admin
            if (my $mail_to_admin = $c->stash->{mail_to_admin}) {
                my $email_params = {
                    to      => $mail_to_admin,
                    from    => $mail_to_admin,
                    subject => "URGENT: Comserv Domain Configuration Required",
                    body    => "Domain Error: $error_msg\n\n" .
                               "Domain: $domain\n" .
                               "Error Type: $error_type\n\n" .
                               "ACTION REQUIRED: $action_required\n\n" .
                               "Technical Details: $technical_details\n\n" .
                               "Time: " . scalar(localtime) . "\n" .
                               "IP Address: " . ($c->req->address || 'unknown') . "\n" .
                               "User Agent: " . ($c->req->user_agent || 'unknown') . "\n\n" .
                               "This is a configuration error that needs to be fixed for proper site operation."
                };

                if ($self->send_email($c, $email_params)) {
                    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'setup_site',
                        "Sent admin notification email about domain error: $error_type for $domain");
                } else {
                    $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'setup_site',
                        "Failed to send admin email notification about domain error: $error_type for $domain");
                }
            }

            # Display error page with clear message about the domain configuration issue
            $c->stash->{template} = 'error.tt';
            $c->stash->{error_title} = "Domain Configuration Error";
            $c->stash->{error_msg} = $error_msg;
            $c->stash->{admin_msg} = "The administrator has been notified of this issue.";
            $c->stash->{technical_details} = $technical_details;
            $c->stash->{action_required} = $action_required;

            # Add debug message that will be displayed to admins
            $c->stash->{debug_msg} = "Domain Error ($error_type): $technical_details";

            # Forward to the error template and stop processing
            $c->forward($c->view('TT'));
            $c->detach(); # Ensure we stop processing here and show the error page
        } else {
            # Generic error case (should not happen with our improved error handling)
            my $error_msg = "DOMAIN ERROR: '$domain' not found in sitedomain table";
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'setup_site', $error_msg);

            # Add to debug_errors if not already there
            unless (grep { $_ eq $error_msg } @{$c->stash->{debug_errors}}) {
                push @{$c->stash->{debug_errors}}, $error_msg;
            }

            # Set default site for error handling
            $SiteName = 'CSC'; # Default to CSC
            $c->stash->{SiteName} = $SiteName;
            $c->session->{SiteName} = $SiteName;

            # Force Root controller to show error page
            $c->stash->{ControllerName} = 'Root';
            $c->session->{ControllerName} = 'Root';

            # Set up site basics to get admin email
            $self->site_setup($c, $SiteName);

            # Send email notification to admin
            if (my $mail_to_admin = $c->stash->{mail_to_admin}) {
                my $email_params = {
                    to      => $mail_to_admin,
                    from    => $mail_to_admin,
                    subject => "URGENT: Comserv Domain Configuration Required",
                    body    => "Domain Error: Domain not found in sitedomain table\n\n" .
                               "Domain: $domain\n" .
                               "Error Type: domain_missing\n\n" .
                               "ACTION REQUIRED: Please add this domain to the sitedomain table and associate it with the appropriate site.\n\n" .
                               "Technical Details: The domain '$domain' needs to be added to the sitedomain table.\n\n" .
                               "Time: " . scalar(localtime) . "\n" .
                               "IP Address: " . ($c->req->address || 'unknown') . "\n" .
                               "User Agent: " . ($c->req->user_agent || 'unknown') . "\n\n" .
                               "This is a configuration error that needs to be fixed for proper site operation."
                };

                if ($self->send_email($c, $email_params)) {
                    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'setup_site',
                        "Sent admin notification email about domain error for $domain");
                } else {
                    $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'setup_site',
                        "Failed to send admin email notification about domain error for $domain");
                }
            }

            # Display error page with clear message about the domain configuration issue
            $c->stash->{template} = 'error.tt';
            $c->stash->{error_title} = "Domain Configuration Error";
            $c->stash->{error_msg} = "This domain ($domain) is not properly configured in the system.";
            $c->stash->{admin_msg} = "The administrator has been notified of this issue.";
            $c->stash->{technical_details} = "The domain '$domain' needs to be added to the sitedomain table.";
            $c->stash->{action_required} = "Please add this domain to the sitedomain table and associate it with the appropriate site.";

            # Add debug message that will be displayed to admins
            $c->stash->{debug_msg} = "Domain '$domain' not found in sitedomain table. Please add it using the Site Administration interface.";

            # Set flash error message to ensure it's displayed
            $c->flash->{error_msg} = "Domain Error: This domain ($domain) is not properly configured in the system.";

            # Forward to the error template and stop processing
            $c->forward($c->view('TT'));
            $c->detach(); # Ensure we stop processing here and show the error page
        }
    }

    $self->site_setup($c, $c->session->{SiteName});
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'setup_site', 'Completed site setup');
}

sub site_setup {
    my ($self, $c, $SiteName) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'site_setup', "SiteName: $SiteName");

    # Get the current domain for HostName
    my $domain = $c->req->uri->host;
    $domain =~ s/:.*//;  # Remove port if present

    # Set a default HostName based on the current domain
    my $protocol = $c->req->secure ? 'https' : 'http';
    my $default_hostname = "$protocol://$domain";
    $c->stash->{HostName} = $default_hostname;
    $c->session->{Domain} = $domain;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'site_setup', "Set default HostName: $default_hostname");

    my $site = $c->model('Site')->get_site_details_by_name($c, $SiteName);
    unless (defined $site) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'site_setup', "No site found for SiteName: $SiteName");

        # Set default values for critical variables
        $c->stash->{ScriptDisplayName} = 'Site';
        $c->stash->{css_view_name} = '/static/css/default.css';
        $c->stash->{mail_to_admin} = 'admin@computersystemconsulting.ca';
        $c->stash->{mail_replyto} = 'helpdesk.computersystemconsulting.ca';

        # Add debug information
        push @{$c->stash->{debug_errors}}, "ERROR: No site found for SiteName: $SiteName";
        $c->stash->{debug_msg} = "Using default site settings because no site was found for '$SiteName'";

        return;
    }

    my $css_view_name = $site->css_view_name || '/static/css/default.css';
    my $site_display_name = $site->site_display_name || $SiteName;
    my $mail_to_admin = $site->mail_to_admin || 'admin@computersystemconsulting.ca';
    my $mail_replyto = $site->mail_replyto || 'helpdesk.computersystemconsulting.ca';
    my $site_name = $site->name || $SiteName;

    # If site has a document_root_url, use it for HostName
    if ($site->document_root_url && $site->document_root_url ne '') {
        $c->stash->{HostName} = $site->document_root_url;
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'site_setup',
            "Set HostName from document_root_url: " . $site->document_root_url);
    }

    # Get theme from ThemeManager
    my $theme_name = $self->theme_manager->get_site_theme($c, $SiteName);

    # Set theme in stash for Header.tt to use
    $c->stash->{theme_name} = $theme_name;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'site_setup',
        "Set theme_name in stash: $theme_name");

    $c->stash->{ScriptDisplayName} = $site_display_name;
    $c->stash->{css_view_name} = $css_view_name;
    $c->stash->{mail_to_admin} = $mail_to_admin;
    $c->stash->{mail_replyto} = $mail_replyto;
    $c->stash->{SiteName} = $site_name;
    $c->session->{SiteName} = $site_name;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'site_setup',
        "Completed site_setup action with HostName: " . $c->stash->{HostName});
}

sub debug :Path('/debug') {
    my ($self, $c) = @_;
    my $site_name = $c->stash->{SiteName};
    $c->stash(template => 'debug.tt');
    $c->forward($c->view('TT'));
   $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'site_setup', "Completed site_setup action");
}

sub accounts :Path('/accounts') :Args(0) {
    my ($self, $c) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'accounts', "Accessing accounts page");

    $c->stash(template => 'accounts.tt');
    $c->forward($c->view('TT'));
}

# Special route for hosting


sub default :Path {
    my ( $self, $c ) = @_;

    # Log the 404 error with detailed information
    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'default',
        "404 Not Found: " . $c->req->uri->path);
    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'default',
        "Request method: " . $c->req->method);
    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'default',
        "Controller: " . __PACKAGE__);

    # Log the available controllers and their namespaces
    my @controllers = sort keys %{$c->dispatcher->_controller_by_path};
    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'default',
        "Available controllers: " . join(", ", @controllers));

    # Log the available actions for this path
    my $path = $c->req->uri->path;
    my $actions = $c->dispatcher->get_actions_for_path($path);
    if ($actions && @$actions) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'default',
            "Actions for path $path: " . join(", ", map { $_->reverse } @$actions));
    } else {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'default',
            "No actions found for path $path");
    }

    # Set up the 404 page
    $c->stash(
        template => 'error.tt',
        error_title => '404 - Page Not Found',
        error_msg => 'The page you requested could not be found.',
        requested_path => $c->req->uri->path,
        status_code => 404
    );

    # Set the HTTP status code
    $c->response->status(404);

    # Render the error template
    $c->forward($c->view('TT'));
}

sub documentation :Path('documentation') :Args(0) {
    my ( $self, $c ) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'documentation', "Redirecting to Documentation controller");
    $c->response->redirect($c->uri_for('/Documentation'));
}

sub Documentation :Path('Documentation') :Args {
    my ( $self, $c, @args ) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'Documentation', "Forwarding to Documentation controller with args: " . join(', ', @args));

    if (@args) {
        $c->detach('/documentation/view', [@args]);
    } else {
        $c->detach('/documentation/index');
    }
}

sub reset_session :Global {
    my ( $self, $c ) = @_;

    # Log the session reset request
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'reset_session',
        "Session reset requested. Session ID: " . $c->sessionid);

    # Store the current SiteName for debugging
    my $old_site_name = $c->session->{SiteName} || 'none';

    # Clear the entire session
    $c->delete_session("User requested session reset");

    # Create a new session
    $c->session->{reset_time} = time();
    $c->session->{debug_mode} = 1; # Enable debug mode by default after reset

    # Log the new session
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'reset_session',
        "New session created. Session ID: " . $c->sessionid . ", Old SiteName: " . $old_site_name);

    # Redirect to home page
    $c->response->redirect($c->uri_for('/'));
}


sub end : ActionClass('RenderView') {}

__PACKAGE__->meta->make_immutable;

1;
