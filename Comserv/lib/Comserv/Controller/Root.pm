package Comserv::Controller::Root;
use Moose;
use namespace::autoclean;
use Template;
use Data::Dumper;
use DateTime;
use JSON;
use URI;
use Comserv::Util::Logging;
use Comserv::Util::SystemInfo;

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

# Add user_exists method
sub user_exists {
    my ($self, $c) = @_;
    return ($c->session->{username} && $c->session->{user_id}) ? 1 : 0;
}

# Add check_user_roles method
sub check_user_roles {
    my ($self, $c, $role) = @_;
    
    # First check if the user exists
    return 0 unless $self->user_exists($c);
    
    # Get roles from session
    my $roles = $c->session->{roles};
    
    # Log the role check for debugging
    my $roles_debug = 'none';
    if (defined $roles) {
        if (ref($roles) eq 'ARRAY') {
            $roles_debug = join(', ', @$roles);
        } else {
            $roles_debug = $roles;
        }
    }
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'check_user_roles',
        "Checking if user has role: $role, User roles: $roles_debug");
    
    # Add detailed debugging for session data
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'check_user_roles',
        "Session data: username=" . ($c->session->{username} || 'undefined') . 
        ", user_id=" . ($c->session->{user_id} || 'undefined') .
        ", roles=" . (defined $roles ? (ref($roles) ? ref($roles) : $roles) : 'undefined'));
    
    # Check if the user has the admin role in the session
    if ($role eq 'admin') {
        # For admin role, check if user is in the admin group or has admin privileges
        if ($c->session->{is_admin}) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'check_user_roles',
                "User has is_admin flag set in session");
            return 1;
        }
        
        # Check roles array
        if (ref($roles) eq 'ARRAY') {
            foreach my $user_role (@$roles) {
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'check_user_roles',
                    "Checking array role: '$user_role' against 'admin'");
                if (lc($user_role) eq 'admin') {
                    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'check_user_roles',
                        "Found admin role in array");
                    return 1;
                }
            }
        }
        # Check roles string
        elsif (defined $roles && !ref($roles)) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'check_user_roles',
                "Checking string role: '$roles' for 'admin'");
            if ($roles =~ /\badmin\b/i) {
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'check_user_roles',
                    "Found admin in roles string");
                return 1;
            }
        }
        
        # Check user_groups
        my $user_groups = $c->session->{user_groups};
        if (ref($user_groups) eq 'ARRAY') {
            foreach my $group (@$user_groups) {
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'check_user_roles',
                    "Checking user group: '$group' against 'admin'");
                if (lc($group) eq 'admin') {
                    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'check_user_roles',
                        "Found admin in user_groups array");
                    return 1;
                }
            }
        }
        elsif (defined $user_groups && !ref($user_groups)) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'check_user_roles',
                "Checking user_groups string: '$user_groups' for 'admin'");
            if ($user_groups =~ /\badmin\b/i) {
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'check_user_roles',
                    "Found admin in user_groups string");
                return 1;
            }
        }
        
        # If we get here, user doesn't have admin role
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'check_user_roles',
            "User does not have admin role");
    }
    
    # For other roles, check if the role is in the user's roles
    if (ref($roles) eq 'ARRAY') {
        foreach my $user_role (@$roles) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'check_user_roles',
                "Checking array role: '$user_role' against '$role'");
            if (lc($user_role) eq lc($role)) {
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'check_user_roles',
                    "Found matching role in array");
                return 1;
            }
        }
    }
    elsif (defined $roles && !ref($roles)) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'check_user_roles',
            "Checking string role: '$roles' for '$role'");
        if ($roles =~ /\b$role\b/i) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'check_user_roles',
                "Found matching role in string");
            return 1;
        }
    }
    
    # Role not found
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'check_user_roles',
        "Role '$role' not found for user");
    return 0;
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

    # Log if there's a view parameter, but don't handle specific views here
    if ($c->req->param('view')) {
        my $view = $c->req->param('view');
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "View parameter detected: $view");
    }

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

            # Use a standard redirect to the controller's path
            # This is a more reliable approach that works for all controllers
            $c->response->redirect("/$ControllerName");
            $c->detach();
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
    my $all_themes = $c->model('ThemeConfig')->get_all_themes($c);
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'set_theme',
        "Available themes: " . join(", ", sort keys %$all_themes));

    # Get the theme for this site from our theme config
    my $theme_name = $c->model('ThemeConfig')->get_site_theme($c, $site_name);

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
    
    # Temporarily add back the uri_no_port function to prevent template errors
    # This will be removed once all templates are updated
    $c->stash->{uri_no_port} = sub {
        my $path = shift;
        my $uri = $c->uri_for($path, @_);
        return $uri;
    };
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "Starting auto action with temporary uri_no_port helper");

    # Track application start
    $c->stash->{forwarder} = $c->req->path; # Store current path as potential redirect target
    $self->track_application_start($c);

    # Log the request path
    my $path = $c->req->path;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "Request path: '$path'");

    # Generate theme CSS files if they don't exist
    # We only need to do this once per application start
    if (!$self->_theme_css_generated) {
        $c->model('ThemeConfig')->generate_all_theme_css($c);
        $self->_theme_css_generated(1);
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "Generated all theme CSS files");
    }

    # Get server information
    my $system_info = Comserv::Util::SystemInfo::get_system_info();
    $c->stash->{server_hostname} = $system_info->{hostname};
    $c->stash->{server_ip} = $system_info->{ip};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', 
        "Server info - Hostname: $system_info->{hostname}, IP: $system_info->{ip}");

    # Perform general setup tasks
    $self->setup_debug_mode($c);
    
    # Test database connections if in debug mode
    if ($c->session->{debug_mode}) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "Testing database connections in debug mode");
        
        # Add database connection status to debug messages
        my $debug_msg = $c->stash->{debug_msg} ||= [];
        push @$debug_msg, "Database connection check initiated. See logs for details.";
        
        # Test connections using the test_connection methods we added
        eval {
            if ($c->model('DBEncy')->test_connection($c)) {
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "DBEncy connection successful");
            }
        };
        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'auto', "DBEncy connection error: $@");
        }
        
        eval {
            if ($c->model('DBForager')->test_connection($c)) {
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "DBForager connection successful");
            }
        };
        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'auto', "DBForager connection error: $@");
        }
    }
    
    $self->setup_site($c);
    $self->set_theme($c);
    
    # Try to populate navigation data if the controller is available
    # This is done in a way that doesn't require explicit loading of the Navigation controller
    eval {
        # Check if the Navigation controller exists by trying to load it
        require Comserv::Controller::Navigation;
        
        # If we get here, the controller exists, so try to use it
        my $navigation = $c->controller('Navigation');
        if ($navigation) {
            $navigation->populate_navigation_data($c);
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "Navigation data populated");
        }
    };
    # Don't log errors here - if the controller isn't available, that's fine
    
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

    # First try to use the Mail model which gets SMTP config from the database
    try {
        # Use the Mail model to send the email
        my $result = $c->model('Mail')->send_email(
            $c,
            $params->{to},
            $params->{subject},
            $params->{body},
            $params->{site_id}
        );
        
        if ($result) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'send_email',
                "Email sent successfully to: " . $params->{to} . " using Mail model");
            return 1;
        } else {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'send_email',
                "Mail model returned false. Trying fallback method.");
        }
    } catch {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'send_email',
            "Mail model failed: $_. Trying fallback method.");
            
        # Try to use a fallback SMTP configuration with Net::SMTP
        try {
            require Net::SMTP;
            require MIME::Lite;
            require Authen::SASL;
            require IO::Socket::SSL;
            
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'send_email',
                "Falling back to hardcoded email config using Net::SMTP");
            
            # Get fallback SMTP configuration from app config
            my $smtp_host = $c->config->{FallbackSMTP}->{host} || '192.168.1.129';  # Use IP directly instead of hostname
            my $smtp_port = $c->config->{FallbackSMTP}->{port} || 587;
            my $smtp_user = $c->config->{FallbackSMTP}->{username} || 'noreply@computersystemconsulting.ca';
            my $smtp_pass = $c->config->{FallbackSMTP}->{password} || '';
            my $smtp_ssl  = $c->config->{FallbackSMTP}->{ssl} || 'starttls';
            my $from_addr = $params->{from} || 'noreply@computersystemconsulting.ca';
            
            # Replace mail1.ht.home with IP if it's still in the config
            if ($smtp_host eq 'mail1.ht.home') {
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'send_email',
                    "Replacing mail1.ht.home with 192.168.1.129 in fallback SMTP");
                $smtp_host = '192.168.1.129';
            }
            
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'send_email',
                "Using fallback SMTP with Net::SMTP: $smtp_host:$smtp_port");
            
            # Create a MIME::Lite message
            my $msg = MIME::Lite->new(
                From    => $from_addr,
                To      => $params->{to},
                Subject => $params->{subject},
                Type    => 'text/plain',
                Data    => $params->{body}
            );
            
            # Connect to the SMTP server with debug enabled and SSL support
            my $smtp = Net::SMTP->new(
                $smtp_host,
                Port => $smtp_port,
                Debug => 1,
                Timeout => 30,
                SSL_verify_mode => 0,  # Disable certificate verification for now
                SSL_version => 'TLSv1_2:!SSLv2:!SSLv3'  # Use secure TLS versions only
            );
            
            unless ($smtp) {
                die "Could not connect to SMTP server $smtp_host:$smtp_port: $!";
            }
            
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'send_email',
                "Connected to SMTP server $smtp_host:$smtp_port");
            
            # Start TLS if needed with improved error handling
            if ($smtp_ssl eq 'starttls') {
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'send_email',
                    "Starting TLS negotiation");
                
                # Use IO::Socket::SSL for better TLS support
                my $tls_result = $smtp->starttls(
                    SSL_verify_mode => 0,  # Disable certificate verification
                    SSL_version => 'TLSv1_2:!SSLv2:!SSLv3',  # Use secure TLS versions
                    SSL_cipher_list => 'HIGH:!aNULL:!eNULL:!EXPORT:!DES:!RC4:!MD5:!PSK:!SRP:!CAMELLIA'
                );
                
                unless ($tls_result) {
                    my $error_msg = $smtp->message() || "Unknown TLS error";
                    $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'send_email',
                        "STARTTLS failed: $error_msg");
                    die "STARTTLS failed: $error_msg";
                }
                
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'send_email',
                    "TLS negotiation successful");
            }
            
            # Authenticate if credentials are provided
            if ($smtp_user && $smtp_pass) {
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'send_email',
                    "Authenticating as $smtp_user");
                $smtp->auth($smtp_user, $smtp_pass) or die "Authentication failed: " . $smtp->message();
            }
            
            # Send the email
            $smtp->mail($from_addr) or die "FROM failed: " . $smtp->message();
            $smtp->to($params->{to}) or die "TO failed: " . $smtp->message();
            $smtp->data() or die "DATA failed: " . $smtp->message();
            $smtp->datasend($msg->as_string()) or die "DATASEND failed: " . $smtp->message();
            $smtp->dataend() or die "DATAEND failed: " . $smtp->message();
            $smtp->quit() or die "QUIT failed: " . $smtp->message();
            
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'send_email',
                "Email sent successfully to: " . $params->{to} . " using Net::SMTP fallback method");
            
            # Store success message in stash
            $c->stash->{status_msg} = "Email sent successfully via Net::SMTP fallback method";
            return 1;
        } catch {
            # Both methods failed
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'send_email',
                "All email sending methods failed. Fallback error: $_");
                
            # Add to debug messages
            $c->stash->{debug_msg} = "Email sending failed: $_";
            return 0;
        }
    }
    
    return 1;
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

        # Development bypass for localhost
        if ($domain eq 'localhost' && ($ENV{CATALYST_DEBUG} || $ENV{CATALYST_ENV} eq 'development')) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'setup_site', "Development mode: bypassing domain check for localhost");
            $SiteName = 'CSC';  # Default site for development
            $c->stash->{SiteName} = $SiteName;
            $c->session->{SiteName} = $SiteName;
            $c->stash->{ControllerName} = 'CSC';
            $c->session->{ControllerName} = 'CSC';
            return;  # Skip the rest of the domain lookup
        }

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

                # Try to send email but don't let it block the application if it fails
                eval {
                    if ($self->send_email($c, $email_params)) {
                        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'setup_site',
                            "Sent admin notification email about domain error: $error_type for $domain");
                    } else {
                        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'setup_site',
                            "Failed to send admin email notification about domain error: $error_type for $domain");
                        
                        # Add to debug messages
                        push @{$c->stash->{debug_msg}}, "Failed to send admin notification email. Check SMTP configuration.";
                    }
                };
                
                # Log any errors from the email sending attempt but continue processing
                if ($@) {
                    $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'setup_site',
                        "Exception while sending admin email notification: $@");
                    
                    # Add to debug messages
                    push @{$c->stash->{debug_msg}}, "Email error: $@";
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
            $c->stash->{debug_msg} = [] unless ref $c->stash->{debug_msg} eq 'ARRAY';
            push @{$c->stash->{debug_msg}}, "Domain Error ($error_type): $technical_details";

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

                eval {
                    if ($self->send_email($c, $email_params)) {
                        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'setup_site',
                            "Sent admin notification email about domain error for $domain");
                    } else {
                        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'setup_site',
                            "Failed to send admin email notification about domain error for $domain");
                    }
                };
                if ($@) {
                    $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'setup_site',
                        "Email notification failed with error: $@");
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
            $c->stash->{debug_msg} = [] unless ref $c->stash->{debug_msg} eq 'ARRAY';
            push @{$c->stash->{debug_msg}}, "Domain '$domain' not found in sitedomain table. Please add it using the Site Administration interface.";

            # Set flash error message to ensure it's displayed
            $c->flash->{error_msg} = "Domain Error: This domain ($domain) is not properly configured in the system.";

            # Check if this is an API endpoint that should continue processing
            my $path = $c->req->path;
            if ($path =~ m{^Documentation/search$} || 
                $path =~ m{^Documentation/debug_search$} ||
                $path =~ m{/api/} ||
                $path =~ m{\.json$}) {
                # Allow API endpoints to continue processing
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'setup_site',
                    "Allowing API endpoint $path to continue despite domain configuration issue");
            } else {
                # Forward to the error template and stop processing for regular pages
                $c->forward($c->view('TT'));
                $c->detach(); # Ensure we stop processing here and show the error page
            }
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
    
    # Using Catalyst's built-in proxy configuration for URLs without port
    # This is configured in Comserv.pm with using_frontend_proxy and ignore_frontend_proxy_port
    
    # Log the configuration for debugging
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'site_setup', "Using Catalyst's built-in proxy configuration for URLs without port");
    
    # Test the configuration by generating a sample URL
    my $test_url = $c->uri_for('/test');
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'site_setup', "Test URL: $test_url");
    
    # Add to debug_msg for visibility in templates
    # Ensure debug_msg is always an array
    $c->stash->{debug_msg} = [] unless ref $c->stash->{debug_msg} eq 'ARRAY';
    push @{$c->stash->{debug_msg}}, "Using Catalyst's built-in proxy configuration. Test URL: $test_url";

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
        
        # Ensure debug_msg is always an array
        $c->stash->{debug_msg} = [] unless ref $c->stash->{debug_msg} eq 'ARRAY';
        push @{$c->stash->{debug_msg}}, "Using default site settings because no site was found for '$SiteName'";

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

    # Get theme from ThemeConfig
    my $theme_name = $c->model('ThemeConfig')->get_site_theme($c, $SiteName);

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


# This default method has been merged with the one at line 889

# Documentation routes are now handled directly by the Documentation controller
# See Comserv::Controller::Documentation

sub proxmox_servers :Path('proxmox_servers') :Args(0) {
    my ( $self, $c ) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'proxmox_servers', "Forwarding to ProxmoxServers controller");
    $c->forward('Comserv::Controller::ProxmoxServers', 'index');
}

sub proxmox :Path('proxmox') :Args(0) {
    my ( $self, $c ) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'proxmox', "Forwarding to Proxmox controller");
    $c->forward('Comserv::Controller::Proxmox', 'index');
}

# Handle both lowercase and uppercase versions of the route
sub proxymanager :Path('proxymanager') :Args(0) {
    my ( $self, $c ) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'proxymanager', "Forwarding to ProxyManager controller (lowercase)");
    $c->forward('Comserv::Controller::ProxyManager', 'index');
}

# Handle uppercase version of the route
sub ProxyManager :Path('ProxyManager') :Args(0) {
    my ( $self, $c ) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'ProxyManager', "Forwarding to ProxyManager controller (uppercase)");
    $c->forward('Comserv::Controller::ProxyManager', 'index');
}

# Handle lowercase version of the route
sub hosting :Path('hosting') :Args(0) {
    my ( $self, $c ) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'hosting', "Forwarding to Hosting controller (lowercase)");
    $c->forward('Comserv::Controller::Hosting', 'index');
}

# Handle uppercase version of the route
sub Hosting :Path('Hosting') :Args(0) {
    my ( $self, $c ) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'Hosting', "Forwarding to Hosting controller (uppercase)");
    $c->forward('Comserv::Controller::Hosting', 'index');
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


# Route for the "Back" functionality
sub back :Path('/back') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'back',
        "Back navigation requested");
    
    # Check if we have a return URL in session
    my $return_url = $c->session->{return_url} || $c->req->referer || '/';
    
    # Avoid infinite loops - don't redirect back to /back
    if ($return_url =~ m{/back$}) {
        $return_url = '/';
    }
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'back',
        "Redirecting back to: $return_url");
    
    $c->response->redirect($return_url);
}

# Route for the "Hosted" functionality
sub hosted :Path('/hosted') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'hosted',
        "Hosted accounts page requested");
    
    # Store current URL as return URL for back navigation
    $c->session->{return_url} = $c->req->uri->as_string;
    
    # Get site name and domain for context
    my $site_name = $c->stash->{SiteName} || $c->session->{SiteName} || 'Comserv';
    my $site_domain = '';
    
    # Get the actual domain from the database
    eval {
        if ($c->model('Site')) {
            my $domain = $c->req->uri->host;
            my $site_domain_obj = $c->model('Site')->get_site_domain($c, $domain);
            if ($site_domain_obj) {
                my $site = $c->model('Site')->get_site_details($c, $site_domain_obj->site_id);
                if ($site && $site->domain) {
                    $site_domain = $site->domain;
                }
            }
        }
    };
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'hosted',
            "Could not fetch site domain: $@");
    }
    
    # Fallback to current domain if not found in database
    $site_domain = $site_domain || $c->req->uri->host;
    
    # Get hosted accounts from the database (if available)
    my $hosted_accounts = [];
    eval {
        # Try to get hosted accounts from database
        if ($c->model('DB') && $c->model('DB')->resultset('HostedAccount')) {
            $hosted_accounts = [$c->model('DB')->resultset('HostedAccount')->search(
                { site_name => $site_name },
                { order_by => 'account_name' }
            )->all];
        }
    };
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'hosted',
            "Could not fetch hosted accounts from database: $@");
    }
    
    $c->stash(
        template => 'hosted/index.tt',
        site_name => $site_name,
        site_domain => $site_domain,
        hosted_accounts => $hosted_accounts,
        page_title => "Hosted Accounts - $site_domain"
    );
}

# Route for the "Member" functionality  
sub membership :Path('/membership') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'membership',
        "Membership page requested");
    
    # Store current URL as return URL for back navigation
    $c->session->{return_url} = $c->req->uri->as_string;
    
    # Get site name and domain for context
    my $site_name = $c->stash->{SiteName} || $c->session->{SiteName} || 'Comserv';
    my $site_domain = '';
    
    # Get the actual domain from the database
    eval {
        if ($c->model('Site')) {
            my $domain = $c->req->uri->host;
            my $site_domain_obj = $c->model('Site')->get_site_domain($c, $domain);
            if ($site_domain_obj) {
                my $site = $c->model('Site')->get_site_details($c, $site_domain_obj->site_id);
                if ($site && $site->domain) {
                    $site_domain = $site->domain;
                }
            }
        }
    };
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'membership',
            "Could not fetch site domain: $@");
    }
    
    # Fallback to current domain if not found in database
    $site_domain = $site_domain || $c->req->uri->host;
    
    # Check if user is already a member
    my $is_member = 0;
    my $user_membership = {};
    
    if ($c->session->{user_id}) {
        eval {
            # Try to get user membership info from database
            if ($c->model('DB') && $c->model('DB')->resultset('Membership')) {
                my $membership = $c->model('DB')->resultset('Membership')->find({
                    user_id => $c->session->{user_id},
                    site_name => $site_name
                });
                if ($membership) {
                    $is_member = 1;
                    $user_membership = {
                        type => $membership->membership_type,
                        status => $membership->status,
                        expires => $membership->expires_date
                    };
                }
            }
        };
        if ($@) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'membership',
                "Could not fetch membership info: $@");
        }
    }
    
    $c->stash(
        template => 'membership/index.tt',
        site_name => $site_name,
        site_domain => $site_domain,
        is_member => $is_member,
        user_membership => $user_membership,
        page_title => "Membership - $site_domain"
    );
}

# Route for membership application
sub applymembership :Path('/applymembership') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'applymembership',
        "Membership application requested");
    
    # Store current URL as return URL for back navigation
    $c->session->{return_url} = $c->req->uri->as_string;
    
    # Get site name and domain for context
    my $site_name = $c->stash->{SiteName} || $c->session->{SiteName} || 'Comserv';
    my $site_domain = '';
    
    # Get the actual domain from the database
    eval {
        if ($c->model('Site')) {
            my $domain = $c->req->uri->host;
            my $site_domain_obj = $c->model('Site')->get_site_domain($c, $domain);
            if ($site_domain_obj) {
                my $site = $c->model('Site')->get_site_details($c, $site_domain_obj->site_id);
                if ($site && $site->domain) {
                    $site_domain = $site->domain;
                }
            }
        }
    };
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'applymembership',
            "Could not fetch site domain: $@");
    }
    
    # Fallback to current domain if not found in database
    $site_domain = $site_domain || $c->req->uri->host;
    
    if ($c->req->method eq 'POST') {
        # Process membership application
        my $params = $c->req->params;
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'applymembership',
            "Processing membership application for: " . ($params->{email} || 'unknown'));
        
        # Basic validation
        my @errors;
        push @errors, "Name is required" unless $params->{name};
        push @errors, "Email is required" unless $params->{email};
        push @errors, "Membership type is required" unless $params->{membership_type};
        
        if (@errors) {
            $c->stash(
                template => 'membership/apply.tt',
                site_name => $site_name,
                site_domain => $site_domain,
                errors => \@errors,
                form_data => $params,
                page_title => "Apply for Membership - $site_domain"
            );
            return;
        }
        
        # Try to save the application
        eval {
            if ($c->model('DB') && $c->model('DB')->resultset('MembershipApplication')) {
                $c->model('DB')->resultset('MembershipApplication')->create({
                    name => $params->{name},
                    email => $params->{email},
                    phone => $params->{phone} || '',
                    membership_type => $params->{membership_type},
                    site_name => $site_name,
                    application_date => DateTime->now,
                    status => 'pending'
                });
                
                $c->stash(
                    template => 'membership/application_success.tt',
                    site_name => $site_name,
                    site_domain => $site_domain,
                    applicant_name => $params->{name},
                    page_title => "Application Submitted - $site_domain"
                );
                return;
            }
        };
        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'applymembership',
                "Failed to save membership application: $@");
            push @errors, "Failed to submit application. Please try again.";
        }
        
        $c->stash(
            template => 'membership/apply.tt',
            site_name => $site_name,
            site_domain => $site_domain,
            errors => \@errors,
            form_data => $params,
            page_title => "Apply for Membership - $site_domain"
        );
    } else {
        # Show application form
        $c->stash(
            template => 'membership/apply.tt',
            site_name => $site_name,
            site_domain => $site_domain,
            page_title => "Apply for Membership - $site_domain"
        );
    }
}

sub end : ActionClass('RenderView') {}

# Default action for handling 404 errors
sub default :Path {
    my ($self, $c) = @_;
    
    # Get the requested path
    my $requested_path = $c->req->path;
    my $path = join('/', @{$c->req->args});
    
    # Log the 404 error
    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'default', 
        "Page not found: /$requested_path");
    
    # Set response status to 404
    $c->response->status(404);
    
    # Set up the error page
    $c->stash(
        template => 'error.tt',
        error_title => 'Page Not Found',
        error_msg => "The page you requested could not be found: /$requested_path. <br><a href=\"/mcoop\" style=\"color: #006633; font-weight: bold;\">Return to Landing Page</a>",
        requested_path => $path,
        debug_msg => "Page not found: /$path",
        technical_details => "Using Catalyst's built-in proxy configuration. Test URL: " . 
                         $c->uri_for('/test')
    );
    
    # Initialize debug_msg array if it doesn't exist
    $c->stash->{debug_msg} = [] unless ref($c->stash->{debug_msg}) eq 'ARRAY';
    
    # Add the debug message to the array
    push @{$c->stash->{debug_msg}}, "Page not found: /$path";
}

__PACKAGE__->meta->make_immutable;

1;
