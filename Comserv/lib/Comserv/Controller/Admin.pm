package Comserv::Controller::Admin;
use Moose;
use namespace::autoclean;
use Data::Dumper;
use Fcntl qw(:DEFAULT :flock);  # Import O_WRONLY, O_APPEND, O_CREAT constants
use Comserv::Util::Logging;
use Cwd;
BEGIN { extends 'Catalyst::Controller'; }

# Returns an instance of the logging utility
sub logging {
    my ($self) = @_;
    return Comserv::Util::Logging->instance();
}

sub begin : Private {
    my ( $self, $c ) = @_;

    # Add detailed logging
    my $username = $c->user_exists ? $c->user->username : 'Guest';
    my $path = $c->req->path;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'begin', 
        "Admin controller begin method called for user: $username, Path: $path");

    # Log the path for debugging
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'begin', 
        "Request path: $path");

    # Special handling for network_devices route is no longer needed
    # as we now have NetworkDevicesRouter.pm to handle this route

    # Check if the user is logged in
    if (!$c->user_exists) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'begin', 
            "User is not logged in, redirecting to login page");
        # If the user isn't logged in, redirect to the login page with return_to parameter
        my $current_path = $c->req->path;
        $c->response->redirect($c->uri_for('/user/login', { return_to => "/$current_path" }));
        return;
    }
    
    # Fetch the roles from the session
    my $roles = $c->session->{roles};
    
    # Log the roles
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'begin', 
        "User roles: " . Dumper($roles));
    
    # Check if roles is defined and is an array reference
    if (defined $roles && ref $roles eq 'ARRAY') {
        # Check if the user has the 'admin' role
        if (grep { $_ eq 'admin' } @$roles) {
            # User is an admin, proceed with the request
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'begin', 
                "User $username has admin role, proceeding with request");
        } else {
            # User is not an admin, redirect to the login page with a message
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'begin', 
                "User $username does not have admin role, redirecting to login page");
            
            # Store the error message in flash
            $c->flash->{error_msg} = "You need administrator privileges to access this page. Please log in with an admin account.";
            
            # Redirect to the login page with return_to parameter
            my $current_path = $c->req->path;
            $c->response->redirect($c->uri_for('/user/login', { return_to => "/$current_path" }));
            return;
        }
    } else {
        # Roles is not defined or not an array, redirect to login page
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'begin', 
            "User $username has invalid roles format, redirecting to login page");
        
        # Store the error message in flash
        $c->flash->{error_msg} = "Your session has invalid role information. Please log in again.";
        
        # Redirect to the login page with return_to parameter
        my $current_path = $c->req->path;
        $c->response->redirect($c->uri_for('/user/login', { return_to => "/$current_path" }));
        return;
    }
}

# Main admin page
sub index :Path :Args(0) {
    my ( $self, $c ) = @_;

    # Log the application's configured template path
    $c->log->debug("Template path: " . $c->path_to('root'));

    # Set the TT template to use.
    $c->stash(template => 'admin/index.tt');

    # Forward to the view
    $c->forward($c->view('TT'));
}

# This method is no longer needed as we now have NetworkDevicesRouter.pm
# Keeping it here for backward compatibility
sub network_devices_forward :Path('/admin/network_devices_old') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'network_devices_forward', 
        "Forwarding to NetworkDevices controller");
    
    # Detach to the NetworkDevices controller
    $c->detach('/admin/network_devices/network_devices');
}

# This method has been moved to Path('/admin/git_pull')

# This method has been moved to Path('admin/edit_documentation')

sub add_schema :Path('/add_schema') :Args(0) {
    my ( $self, $c ) = @_;
    # Debug logging for add_schema action
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_schema', "Starting add_schema action");

    # Initialize output variable
    my $output = '';

    if ( $c->request->method eq 'POST' ) {
        my $migration = DBIx::Class::Migration->new(
            schema_class => 'Comserv::Model::Schema::Ency',
            target_dir   => $c->path_to('root', 'migrations')->stringify
        );

        my $schema_name        = $c->request->params->{schema_name} // '';
        my $schema_description = $c->request->params->{schema_description} // '';

        if ( $schema_name ne '' && $schema_description ne '' ) {
            eval {
                $migration->make_schema;
                $c->stash(message => 'Migration script created successfully.');
                $output = "Created migration script for schema: $schema_name";
            };
            if ($@) {
                $c->stash(error_msg => 'Failed to create migration script: ' . $@);
                $output = "Error: $@";
            }
        } else {
            $c->stash(error_msg => 'Schema name and description cannot be empty.');
            $output = "Error: Schema name and description cannot be empty.";
        }

        # Add the output to the stash so it can be displayed in the template
        $c->stash(output => $output);
    }

    $c->stash(template => 'admin/add_schema.tt');
    $c->forward($c->view('TT'));
}

sub schema_manager :Path('/admin/schema_manager') :Args(0) {
    my ($self, $c) = @_;

    # Log the beginning of the schema_manager action
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'schema_manager', "Starting schema_manager action");

    # Get the selected database (default to 'ENCY')
    my $selected_db = $c->req->param('database') || 'ENCY';
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'schema_manager', "Selected database: $selected_db");

    # Determine the model to use
    my $model = $selected_db eq 'FORAGER' ? 'DBForager' : 'DBEncy';

    # Attempt to fetch list of tables from the selected model
    my $tables;
    eval {
        # Corrected line to pass the selected database to list_tables
        $tables = $c->model('DBSchemaManager')->list_tables($c, $selected_db);
    };
    if ($@) {
        # Log the table retrieval error
        $self->logging->log_with_details(
            $c,
            'error',
            __FILE__,
            __LINE__,
            'schema_manager',
            "Failed to list tables for database '$selected_db': $@"
        );

        # Set error message in stash and render error template
        $c->stash(
            error_msg => "Failed to list tables for database '$selected_db': $@",
            template  => 'admin/SchemaManager.tt',
        );
        $c->forward($c->view('TT'));
        return;
    }

    # Log successful table retrieval
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'schema_manager', "Successfully retrieved tables for '$selected_db'");

    # Pass data to the stash for rendering the SchemaManager template
    $c->stash(
        database  => $selected_db,
        tables    => $tables,
        template  => 'admin/SchemaManager.tt',
    );

    $c->forward($c->view('TT'));
}

=head2 manage_users

Admin interface to manage users

=cut

sub manage_users :Path('/admin/users') :Args(0) {
    my ($self, $c) = @_;

    # Log the beginning of the manage_users action
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'manage_users', "Starting manage_users action");

    # Get all users from the database
    my @users = $c->model('DBEncy::User')->search({}, {
        order_by => { -asc => 'username' }
    });

    # Pass data to the stash for rendering the template
    $c->stash(
        users => \@users,
        template => 'admin/manage_users.tt',
    );

    $c->forward($c->view('TT'));
}

=head2 add_user

Admin interface to add a new user

=cut

sub add_user :Path('/admin/add_user') :Args(0) {
    my ($self, $c) = @_;

    # Log the beginning of the add_user action
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_user', "Starting add_user action");

    # If this is a form submission, process it
    if ($c->req->method eq 'POST') {
        # Retrieve the form data
        my $username = $c->req->params->{username};
        my $password = $c->req->params->{password};
        my $password_confirm = $c->req->params->{password_confirm};
        my $first_name = $c->req->params->{first_name};
        my $last_name = $c->req->params->{last_name};
        my $email = $c->req->params->{email};
        my $roles = $c->req->params->{roles} || 'user';
        my $active = $c->req->params->{active} ? 1 : 0;

        # Log the user creation attempt
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_user',
            "User creation attempt for username: $username with roles: $roles");

        # Ensure all required fields are filled
        unless ($username && $password && $password_confirm && $first_name && $last_name) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'add_user',
                "Missing required fields for user creation");

            $c->stash(
                error_msg => 'All fields are required to create a user',
                template => 'admin/add_user.tt',
            );
            $c->forward($c->view('TT'));
            return;
        }

        # Check if the passwords match
        if ($password ne $password_confirm) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'add_user',
                "Passwords do not match for user creation");

            $c->stash(
                error_msg => 'Passwords do not match',
                template => 'admin/add_user.tt',
            );
            $c->forward($c->view('TT'));
            return;
        }

        # Check if the username already exists
        my $existing_user = $c->model('DBEncy::User')->find({ username => $username });
        if ($existing_user) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'add_user',
                "Username already exists: $username");

            $c->stash(
                error_msg => 'Username already exists. Please choose another.',
                template => 'admin/add_user.tt',
            );
            $c->forward($c->view('TT'));
            return;
        }

        # Hash the password
        my $hashed_password = Comserv::Controller::User->hash_password($password);

        # Create the new user
        eval {
            $c->model('DBEncy::User')->create({
                username => $username,
                password => $hashed_password,
                first_name => $first_name,
                last_name => $last_name,
                email => $email,
                roles => $roles,
                active => $active,
                created_at => \'NOW()',
            });

            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_user',
                "User created successfully: $username with roles: $roles");

            # Set success message and redirect to user management
            $c->flash->{success_msg} = "User '$username' created successfully.";
            $c->response->redirect($c->uri_for('/admin/users'));
            return;
        };

        if ($@) {
            # Handle database errors
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'add_user',
                "Error creating user: $@");

            $c->stash(
                error_msg => "Error creating user: $@",
                template => 'admin/add_user.tt',
            );
            $c->forward($c->view('TT'));
            return;
        }
    }

    # Display the add user form
    $c->stash(
        template => 'admin/add_user.tt',
    );
    $c->forward($c->view('TT'));
}

=head2 delete_user

Admin interface to delete a user

=cut

sub delete_user :Path('/admin/delete_user') :Args(1) {
    my ($self, $c, $user_id) = @_;

    # Log the beginning of the delete_user action
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'delete_user', 
        "Starting delete_user action for user ID: $user_id");

    # Check if the user exists
    my $user = $c->model('DBEncy::User')->find($user_id);
    
    unless ($user) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'delete_user',
            "User not found with ID: $user_id");
            
        $c->flash->{error_msg} = "User not found.";
        $c->response->redirect($c->uri_for('/admin/users'));
        return;
    }
    
    # Store username for logging
    my $username = $user->username;
    
    # Delete the user
    eval {
        # Use the User model to delete the user
        my $result = $c->model('User')->delete_user($user_id);
        
        if ($result eq "1") { # Success
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'delete_user',
                "User deleted successfully: $username (ID: $user_id)");
                
            $c->flash->{success_msg} = "User '$username' deleted successfully.";
        } else {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'delete_user',
                "Error deleting user: $result");
                
            $c->flash->{error_msg} = "Error deleting user: $result";
        }
    };
    
    if ($@) {
        # Handle any exceptions
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'delete_user',
            "Exception when deleting user: $@");
            
        $c->flash->{error_msg} = "An error occurred while deleting the user: $@";
    }
    
    # Redirect back to the user management page
    $c->response->redirect($c->uri_for('/admin/users'));
}

=head2 network_devices

Admin interface to manage network devices

=cut

sub network_devices :Path('/admin/network_devices') :Args(0) {
    my ($self, $c) = @_;

    # Log the beginning of the network_devices action
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'network_devices', "Starting network_devices action");

    # Check if the user has admin role
    unless ($c->user_exists && $c->check_user_roles('admin')) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'network_devices', 'User does not have admin role');
        $c->response->redirect($c->uri_for('/'));
        return;
    }

    # Get the selected site filter (if any)
    my $site_filter = $c->req->param('site') || '';
    
    # Get all devices from the database
    my @devices = ();
    
    # Try to fetch devices from the database if the table exists
    eval {
        my $search_params = {};
        
        # Add site filter if specified
        if ($site_filter) {
            $search_params->{site_name} = $site_filter;
        }
        
        # Log the attempt to access the NetworkDevice table
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'network_devices', 
            "Attempting to access NetworkDevice table with filter: " . ($site_filter || 'None'));
        
        @devices = $c->model('DBEncy')->schema->resultset('NetworkDevice')->search(
            $search_params,
            { order_by => { -asc => 'device_name' } }
        );
        
        # Log success
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'network_devices', 
            "Successfully retrieved " . scalar(@devices) . " devices from the database");
    };
    
    # If there was an error (likely because the table doesn't exist yet)
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'network_devices', 
            "Error fetching devices: $@. Table may not exist yet.");
        
        # Add sample devices for demonstration if the table doesn't exist
        @devices = (
            { 
                id => 1, 
                device_name => 'Main Router', 
                ip_address => '192.168.1.1', 
                mac_address => '00:11:22:33:44:55',
                device_type => 'Router',
                location => 'Server Room',
                purpose => 'Main internet gateway',
                notes => 'Cisco router providing internet access and firewall',
                site_name => 'CSC'
            },
            { 
                id => 2, 
                device_name => 'Core Switch', 
                ip_address => '192.168.1.2', 
                mac_address => '00:11:22:33:44:56',
                device_type => 'Switch',
                location => 'Server Room',
                purpose => 'Core network switch',
                notes => 'Cisco Catalyst 9300 Series',
                site_name => 'CSC'
            },
            { 
                id => 3, 
                device_name => 'Office AP', 
                ip_address => '192.168.1.3', 
                mac_address => '00:11:22:33:44:57',
                device_type => 'Access Point',
                location => 'Main Office',
                purpose => 'Wireless access',
                notes => 'Cisco Meraki MR Series',
                site_name => 'CSC'
            },
            { 
                id => 4, 
                device_name => 'MCOOP Router', 
                ip_address => '10.0.0.1', 
                mac_address => '00:11:22:33:44:58',
                device_type => 'Router',
                location => 'MCOOP Office',
                purpose => 'Main router for MCOOP',
                notes => 'Ubiquiti EdgeRouter',
                site_name => 'MCOOP'
            },
            { 
                id => 5, 
                device_name => 'MCOOP Switch', 
                ip_address => '10.0.0.2', 
                mac_address => '00:11:22:33:44:59',
                device_type => 'Switch',
                location => 'MCOOP Office',
                purpose => 'Network switch for MCOOP',
                notes => 'Ubiquiti EdgeSwitch',
                site_name => 'MCOOP'
            }
        );
        
        # Filter by site if needed
        if ($site_filter) {
            @devices = grep { $_->{site_name} eq $site_filter } @devices;
        }
    }

    # Get list of sites for the filter dropdown
    my @sites = ();
    eval {
        @sites = $c->model('DBEncy::Site')->search(
            {},
            { order_by => { -asc => 'name' } }
        );
    };
    
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'network_devices', 
            "Error fetching sites: $@");
        
        # Add sample sites if we can't get them from the database
        @sites = (
            { id => 1, name => 'CSC' },
            { id => 2, name => 'MCOOP' },
            { id => 3, name => 'BMaster' }
        );
    }

    # Use the standard debug message system
    if ($c->session->{debug_mode}) {
        $c->stash->{debug_msg} = [] unless defined $c->stash->{debug_msg};
        push @{$c->stash->{debug_msg}}, "Admin controller network_devices view - Template: admin/network_devices.tt";
        push @{$c->stash->{debug_msg}}, "Device count: " . scalar(@devices);
        push @{$c->stash->{debug_msg}}, "Site filter: " . ($site_filter || 'None');
    }

    # Pass data to the template
    $c->stash(
        devices => \@devices,
        sites => \@sites,
        site_filter => $site_filter,
        template => 'admin/network_devices.tt'
    );
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'network_devices', 'Set template to admin/network_devices.tt');
    $c->forward($c->view('TT'));
}

=head2 add_network_device

Admin interface to add a new network device

=cut

sub add_network_device :Path('/admin/add_network_device') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_network_device', 'Enter add_network_device method');

    # Check if the user has admin role
    unless ($c->user_exists && $c->check_user_roles('admin')) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'add_network_device', 'User does not have admin role');
        $c->response->redirect($c->uri_for('/admin/network_devices'));
        return;
    }

    # Get list of sites for the dropdown
    my @sites = ();
    eval {
        @sites = $c->model('DBEncy::Site')->search(
            {},
            { order_by => { -asc => 'name' } }
        );
    };
    
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'add_network_device', 
            "Error fetching sites: $@");
        
        # Add sample sites if we can't get them from the database
        @sites = (
            { id => 1, name => 'CSC' },
            { id => 2, name => 'MCOOP' },
            { id => 3, name => 'BMaster' }
        );
    }

    # If this is a form submission, process it
    if ($c->req->method eq 'POST') {
        # Retrieve the form data
        my $device_name = $c->req->params->{device_name};
        my $ip_address = $c->req->params->{ip_address};
        my $mac_address = $c->req->params->{mac_address};
        my $device_type = $c->req->params->{device_type};
        my $location = $c->req->params->{location};
        my $purpose = $c->req->params->{purpose};
        my $notes = $c->req->params->{notes};
        my $site_name = $c->req->params->{site_name};

        # Log the device creation attempt
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_network_device',
            "Device creation attempt for device: $device_name with IP: $ip_address, Site: $site_name");

        # Ensure all required fields are filled
        unless ($device_name && $ip_address && $site_name) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'add_network_device',
                "Missing required fields for device creation");

            $c->stash(
                error_msg => 'Device name, IP address, and site are required',
                sites => \@sites,
                template => 'admin/add_network_device.tt',
            );
            $c->forward($c->view('TT'));
            return;
        }

        # Create the new device
        eval {
            $c->model('DBEncy')->schema->resultset('NetworkDevice')->create({
                device_name => $device_name,
                ip_address => $ip_address,
                mac_address => $mac_address,
                device_type => $device_type,
                location => $location,
                purpose => $purpose,
                notes => $notes,
                site_name => $site_name,
                created_at => \'NOW()',
            });

            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_network_device',
                "Device created successfully: $device_name with IP: $ip_address, Site: $site_name");

            # Set success message and redirect to device list
            $c->flash->{success_msg} = "Device '$device_name' created successfully.";
            $c->response->redirect($c->uri_for('/admin/network_devices', { site => $site_name }));
            return;
        };

        if ($@) {
            # Handle database errors
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'add_network_device',
                "Error creating device: $@");

            $c->stash(
                error_msg => "Error creating device: $@",
                sites => \@sites,
                template => 'admin/add_network_device.tt',
            );
            $c->forward($c->view('TT'));
            return;
        }
    }

    # Display the add device form
    $c->stash(
        sites => \@sites,
        template => 'admin/add_network_device.tt',
    );
    $c->forward($c->view('TT'));
}

=head2 edit_network_device

Admin interface to edit a network device

=cut

sub edit_network_device :Path('/admin/edit_network_device') :Args(1) {
    my ($self, $c, $device_id) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_network_device', "Enter edit_network_device method for device ID: $device_id");

    # Check if the user has admin role
    unless ($c->user_exists && $c->check_user_roles('admin')) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'edit_network_device', 'User does not have admin role');
        $c->response->redirect($c->uri_for('/admin/network_devices'));
        return;
    }

    # Get list of sites for the dropdown
    my @sites = ();
    eval {
        @sites = $c->model('DBEncy::Site')->search(
            {},
            { order_by => { -asc => 'name' } }
        );
    };
    
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'edit_network_device', 
            "Error fetching sites: $@");
        
        # Add sample sites if we can't get them from the database
        @sites = (
            { id => 1, name => 'CSC' },
            { id => 2, name => 'MCOOP' },
            { id => 3, name => 'BMaster' }
        );
    }

    # Try to find the device
    my $device;
    eval {
        $device = $c->model('DBEncy')->schema->resultset('NetworkDevice')->find($device_id);
    };

    # Handle errors or device not found
    if ($@ || !$device) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'edit_network_device',
            "Device not found with ID: $device_id or error: $@");
            
        $c->flash->{error_msg} = "Device not found.";
        $c->response->redirect($c->uri_for('/admin/network_devices'));
        return;
    }

    # If this is a form submission, process it
    if ($c->req->method eq 'POST') {
        # Retrieve the form data
        my $device_name = $c->req->params->{device_name};
        my $ip_address = $c->req->params->{ip_address};
        my $mac_address = $c->req->params->{mac_address};
        my $device_type = $c->req->params->{device_type};
        my $location = $c->req->params->{location};
        my $purpose = $c->req->params->{purpose};
        my $notes = $c->req->params->{notes};
        my $site_name = $c->req->params->{site_name};

        # Log the device update attempt
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_network_device',
            "Device update attempt for device: $device_name with IP: $ip_address, Site: $site_name");

        # Ensure all required fields are filled
        unless ($device_name && $ip_address && $site_name) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'edit_network_device',
                "Missing required fields for device update");

            $c->stash(
                error_msg => 'Device name, IP address, and site are required',
                device => $device,
                sites => \@sites,
                template => 'admin/edit_network_device.tt',
            );
            $c->forward($c->view('TT'));
            return;
        }

        # Update the device
        eval {
            $device->update({
                device_name => $device_name,
                ip_address => $ip_address,
                mac_address => $mac_address,
                device_type => $device_type,
                location => $location,
                purpose => $purpose,
                notes => $notes,
                site_name => $site_name,
                updated_at => \'NOW()',
            });

            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_network_device',
                "Device updated successfully: $device_name with IP: $ip_address, Site: $site_name");

            # Set success message and redirect to device list
            $c->flash->{success_msg} = "Device '$device_name' updated successfully.";
            $c->response->redirect($c->uri_for('/admin/network_devices', { site => $site_name }));
            return;
        };

        if ($@) {
            # Handle database errors
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'edit_network_device',
                "Error updating device: $@");

            $c->stash(
                error_msg => "Error updating device: $@",
                device => $device,
                sites => \@sites,
                template => 'admin/edit_network_device.tt',
            );
            $c->forward($c->view('TT'));
            return;
        }
    }

    # Display the edit device form
    $c->stash(
        device => $device,
        sites => \@sites,
        template => 'admin/edit_network_device.tt',
    );
    $c->forward($c->view('TT'));
}

=head2 delete_network_device

Admin interface to delete a network device

=cut

sub delete_network_device :Path('/admin/delete_network_device') :Args(1) {
    my ($self, $c, $device_id) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'delete_network_device', "Enter delete_network_device method for device ID: $device_id");

    # Check if the user has admin role
    unless ($c->user_exists && $c->check_user_roles('admin')) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'delete_network_device', 'User does not have admin role');
        $c->response->redirect($c->uri_for('/admin/network_devices'));
        return;
    }

    # Try to find the device
    my $device;
    eval {
        $device = $c->model('DBEncy')->schema->resultset('NetworkDevice')->find($device_id);
    };

    # Handle errors or device not found
    if ($@ || !$device) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'delete_network_device',
            "Device not found with ID: $device_id or error: $@");
            
        $c->flash->{error_msg} = "Device not found.";
        $c->response->redirect($c->uri_for('/admin/network_devices'));
        return;
    }

    # Store device name and site for logging and redirection
    my $device_name = $device->device_name;
    my $site_name = $device->site_name;
    
    # Delete the device
    eval {
        $device->delete;
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'delete_network_device',
            "Device deleted successfully: $device_name (ID: $device_id)");
            
        $c->flash->{success_msg} = "Device '$device_name' deleted successfully.";
    };
    
    if ($@) {
        # Handle any exceptions
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'delete_network_device',
            "Exception when deleting device: $@");
            
        $c->flash->{error_msg} = "An error occurred while deleting the device: $@";
    }
    
    # Redirect back to the device list page with the site filter if available
    $c->response->redirect($c->uri_for('/admin/network_devices', { site => $site_name }));
}

sub map_table_to_result :Path('/Admin/map_table_to_result') :Args(0) {
    my ($self, $c) = @_;

    my $database = $c->req->param('database');
    my $table    = $c->req->param('table');

    # Check if the result file exists
    my $result_file = "lib/Comserv/Model/Result/" . ucfirst($table) . ".pm";
    my $file_exists = -e $result_file;

    # Fetch table columns
    my $columns = $c->model('DBSchemaManager')->get_table_columns($database, $table);

    # Generate or update the result file based on the table schema
    if (!$file_exists || $c->req->param('update')) {
        $self->generate_result_file($table, $columns, $result_file);
    } else {
        # Here you could add logic to compare schema if both exist:
        # my $existing_schema = $self->read_schema_from_file($result_file);
        # my $current_schema = $columns;  # Assuming $columns represents current schema
        # if ($self->schemas_differ($existing_schema, $current_schema)) {
        #     # Log or display differences
        #     # Optionally offer to normalize (update file or suggest database change)
        # }
    }

    $c->flash->{success} = "Result file for table '$table' has been successfully updated!";
    $c->response->redirect('/Admin/schema_manager');
}

# Helper to generate or update a result file
sub generate_result_file {
    my ($self, $table, $columns, $file_path) = @_;

    my $content = <<"EOF";
package Comserv::Model::Result::${table};
use base qw/DBIx::Class::Core/;

__PACKAGE__->table('$table');

# Define columns
EOF

    foreach my $column (@$columns) {
        $content .= "__PACKAGE__->add_columns(q{$column->{name}});\n";
    }

    $content .= "\n1;\n";

    # Write the file
    open my $fh, '>', $file_path or die $!;
    print $fh $content;
    close $fh;
}

# Compare schema versions
sub compare_schema :Path('compare_schema') :Args(0) {
    my ($self, $c) = @_;
    # Debug logging for compare_schema action
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'compare_schema', "Starting compare_schema action");

    my $migration = DBIx::Class::Migration->new(
        schema_class => 'Comserv::Model::Schema::Ency',
        target_dir   => $c->path_to('root', 'migrations')->stringify
    );

    my $current_version = $migration->version;
    my $db_version;

    eval {
        $db_version = $migration->schema->resultset('dbix_class_schema_versions')->find({ version => { '!=' => '' } })->version;
    };

    $db_version ||= '0';  # Default if no migrations have been run
    my $changes = ( $current_version != $db_version )
        ? "Schema version mismatch detected. Check migration scripts for changes from $db_version to $current_version."
        : "No changes detected between schema and database.";

    $c->stash(
        current_version => $current_version,
        db_version      => $db_version,
        changes         => $changes,
        template        => 'admin/compare_schema.tt'
    );

    $c->forward($c->view('TT'));
}

# Migrate schema if changes are confirmed
sub migrate_schema :Path('migrate_schema') :Args(0) {
    my ($self, $c) = @_;
    # Debug logging for migrate_schema action
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'migrate_schema', "Starting migrate_schema action");

    if ( $c->request->method eq 'POST' ) {
        my $migration = DBIx::Class::Migration->new(
            schema_class => 'Comserv::Model::Schema::Ency',
            target_dir   => $c->path_to('root', 'migrations')->stringify
        );

        my $confirm = $c->request->params->{confirm};
        if ($confirm) {
            eval {
                $migration->install;
                $c->stash(message => 'Schema migration completed successfully.');
            };
            if ($@) {
                $c->stash(error_msg => "An error occurred during migration: $@");
            }
        } else {
            $c->res->redirect($c->uri_for($self->action_for('compare_schema')));
        }
    }

    $c->stash(
        message   => $c->stash->{message} || '',
        error_msg => $c->stash->{error_msg} || '',
        template  => 'admin/migrate_schema.tt'
    );

    $c->forward($c->view('TT'));
}

# Edit documentation action
sub edit_documentation :Path('/admin/edit_documentation') :Args(0) {
    my ( $self, $c ) = @_;
    # Debug logging for edit_documentation action
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_documentation', "Starting edit_documentation action");

    # Add debug message to stash
    $c->stash(
        debug_msg => "Edit documentation page loaded",
        template => 'admin/edit_documentation.tt'
    );

    $c->forward($c->view('TT'));
}

# Run a script from the script directory
sub run_script :Path('/admin/run_script') :Args(0) {
    my ($self, $c) = @_;

    # Debug logging for run_script action
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'run_script', "Starting run_script action");

    # Check if the user has the admin role
    unless ($c->user_exists && grep { $_ eq 'admin' } @{$c->session->{roles}}) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'run_script', "Unauthorized access attempt by user: " . ($c->session->{username} || 'Guest'));
        $c->flash->{error} = "You must be an admin to perform this action";
        $c->response->redirect($c->uri_for('/'));
        return;
    }

    # Get the script name from the request parameters
    my $script_name = $c->request->params->{script};

    # Validate the script name
    unless ($script_name && $script_name =~ /^[\w\-\.]+\.pl$/) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'run_script', "Invalid script name: " . ($script_name || 'undefined'));
        $c->flash->{error} = "Invalid script name";
        $c->response->redirect($c->uri_for('/admin'));
        return;
    }

    # Path to the script
    my $script_path = $c->path_to('script', $script_name);

    # Check if the script exists
    unless (-e $script_path) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'run_script', "Script not found: $script_path");
        $c->flash->{error} = "Script not found: $script_name";
        $c->response->redirect($c->uri_for('/admin'));
        return;
    }

    if ($c->request->method eq 'POST' && $c->request->params->{confirm}) {
        # Execute the script
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'run_script', "Executing script: $script_path");
        my $output = qx{perl $script_path 2>&1};
        my $exit_code = $? >> 8;

        if ($exit_code == 0) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'run_script', "Script executed successfully. Output: $output");
            $c->flash->{message} = "Script executed successfully. Output: $output";
        } else {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'run_script', "Error executing script: $output");
            $c->flash->{error} = "Error executing script: $output";
        }

        $c->response->redirect($c->uri_for('/admin'));
        return;
    }

    # Display confirmation page
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'run_script', "Displaying confirmation page for script: $script_name");
    $c->stash(
        script_name => $script_name,
        template => 'admin/run_script.tt',
    );
    $c->forward($c->view('TT'));
}

# Get table information
sub view_log :Path('/admin/view_log') :Args(0) {
    my ($self, $c) = @_;

    # Debug logging for view_log action
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view_log', "Starting view_log action");

    # Check if we need to rotate the log
    if ($c->request->params->{rotate} && $c->request->params->{rotate} eq '1') {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view_log', "Manual log rotation requested");

        # Get the actual log file path
        my $log_file;
        if (defined $Comserv::Util::Logging::LOG_FILE) {
            $log_file = $Comserv::Util::Logging::LOG_FILE;
        } else {
            $log_file = $c->path_to('logs', 'application.log');
        }

        # Check if the log file exists and is very large
        if (-e $log_file) {
            my $file_size = -s $log_file;
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view_log', "Log file size: $file_size bytes");

            # Create archive directory if it doesn't exist
            my ($volume, $directories, $filename) = File::Spec->splitpath($log_file);
            my $archive_dir = File::Spec->catdir($directories, 'archive');
            unless (-d $archive_dir) {
                eval { make_path($archive_dir) };
                if ($@) {
                    $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'view_log', "Failed to create archive directory: $@");
                    $c->flash->{error_msg} = "Failed to create archive directory: $@";
                    $c->response->redirect($c->uri_for('/admin/view_log'));
                    return;
                }
            }

            # Generate timestamped filename for the archive
            my $timestamp = strftime("%Y%m%d_%H%M%S", localtime);
            my $archived_log = File::Spec->catfile($archive_dir, "${filename}_${timestamp}");

            # Try to copy the log file to the archive
            eval {
                # Close the log file handle if it's open
                if (defined $Comserv::Util::Logging::LOG_FH) {
                    close $Comserv::Util::Logging::LOG_FH;
                }

                # Copy the log file to the archive
                File::Copy::copy($log_file, $archived_log);

                # Truncate the original log file
                open my $fh, '>', $log_file or die "Cannot open log file for truncation: $!";
                print $fh "Log file truncated at " . scalar(localtime) . "\n";
                close $fh;

                # Reopen the log file for appending
                if (defined $Comserv::Util::Logging::LOG_FILE) {
                    sysopen($Comserv::Util::Logging::LOG_FH, $Comserv::Util::Logging::LOG_FILE, O_WRONLY | O_APPEND | O_CREAT, 0644)
                        or die "Cannot reopen log file after rotation: $!";
                }

                $c->flash->{success_msg} = "Log rotated successfully. Archived to: $archived_log";
            };
            if ($@) {
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'view_log', "Error rotating log: $@");
                $c->flash->{error_msg} = "Error rotating log: $@";
            }
        } else {
            $c->flash->{error_msg} = "Log file not found: $log_file";
        }

        # Redirect to avoid resubmission on refresh
        $c->response->redirect($c->uri_for('/admin/view_log'));
        return;
    }

    # Get the actual log file path from the Logging module
    my $log_file;

    # First try to get it from the global variable in Logging.pm
    if (defined $Comserv::Util::Logging::LOG_FILE) {
        $log_file = $Comserv::Util::Logging::LOG_FILE;
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view_log', "Using log file from Logging module: $log_file");
    } else {
        # Fall back to the default path
        $log_file = $c->path_to('logs', 'application.log');
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view_log', "Using default log file path: $log_file");
    }

    # Check if the log file exists
    unless (-e $log_file) {
        $c->stash(
            error_msg => "Log file not found: $log_file",
            template  => 'admin/view_log.tt',
        );
        $c->forward($c->view('TT'));
        return;
    }

    # Get log file size
    my $log_size_kb = Comserv::Util::Logging->get_log_file_size($log_file);

    # Get list of archived logs
    my ($volume, $directories, $filename) = File::Spec->splitpath($log_file);
    my $archive_dir = File::Spec->catdir($directories, 'archive');
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view_log', "Archive directory: $archive_dir");
    my @archived_logs = ();

    if (-d $archive_dir) {
        opendir(my $dh, $archive_dir) or do {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'view_log', "Cannot open archive directory: $!");
        };

        if ($dh) {
            # Get the base filename without path
            my $base_filename = (File::Spec->splitpath($log_file))[2];
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view_log', "Base filename: $base_filename");

            @archived_logs = map {
                my $full_path = File::Spec->catfile($archive_dir, $_);
                {
                    name => $_,
                    size => sprintf("%.2f KB", (-s $full_path) / 1024),
                    date => scalar localtime((stat($full_path))[9]),
                    is_chunk => ($_ =~ /_chunk\d+$/) ? 1 : 0
                }
            } grep { /^${base_filename}_\d{8}_\d{6}(_chunk\d+)?$/ } readdir($dh);
            closedir($dh);

            # Group chunks together by timestamp
            my %log_groups;
            foreach my $log (@archived_logs) {
                my $timestamp;
                if ($log->{name} =~ /^${base_filename}_(\d{8}_\d{6})(?:_chunk\d+)?$/) {
                    $timestamp = $1;
                } else {
                    # Fallback for unexpected filenames
                    $timestamp = $log->{name};
                }

                push @{$log_groups{$timestamp}}, $log;
            }

            # Sort timestamps in descending order (newest first)
            my @sorted_timestamps = sort { $b cmp $a } keys %log_groups;

            # Flatten the groups back into a list, with chunks grouped together
            @archived_logs = ();
            foreach my $timestamp (@sorted_timestamps) {
                # Sort chunks within each timestamp group
                my @sorted_logs = sort {
                    # Extract chunk numbers for sorting
                    my ($a_chunk) = ($a->{name} =~ /_chunk(\d+)$/);
                    my ($b_chunk) = ($b->{name} =~ /_chunk(\d+)$/);

                    # Non-chunks come first, then sort by chunk number
                    if (!defined $a_chunk && defined $b_chunk) {
                        return -1;
                    } elsif (defined $a_chunk && !defined $b_chunk) {
                        return 1;
                    } elsif (defined $a_chunk && defined $b_chunk) {
                        return $a_chunk <=> $b_chunk;
                    } else {
                        return $a->{name} cmp $b->{name};
                    }
                } @{$log_groups{$timestamp}};

                push @archived_logs, @sorted_logs;
            }
        }
    }

    # Read the log file (limit to last 1000 lines for performance)
    my $log_content;
    my @last_lines;

    # Check if the file is too large to read into memory
    my $file_size = -s $log_file;
    if ($file_size > 10 * 1024 * 1024) { # If larger than 10MB
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view_log', "Log file is too large ($file_size bytes), reading only the last 1000 lines");

        # Use tail-like approach to get the last 1000 lines
        my @tail_lines;
        my $line_count = 0;
        my $buffer_size = 4096;
        my $pos = $file_size;

        open my $fh, '<', $log_file or die "Cannot open log file: $!";

        while ($line_count < 1000 && $pos > 0) {
            my $read_size = ($pos > $buffer_size) ? $buffer_size : $pos;
            $pos -= $read_size;

            seek($fh, $pos, 0);
            my $buffer;
            read($fh, $buffer, $read_size);

            my @buffer_lines = split(/\n/, $buffer);
            $line_count += scalar(@buffer_lines);

            unshift @tail_lines, @buffer_lines;
        }

        close $fh;

        # Take only the last 1000 lines
        if (@tail_lines > 1000) {
            @last_lines = @tail_lines[-1000 .. -1];
        } else {
            @last_lines = @tail_lines;
        }

        $log_content = join("\n", @last_lines);
    } else {
        # For smaller files, read the whole file
        open my $fh, '<', $log_file or die "Cannot open log file: $!";
        my @lines = <$fh>;
        close $fh;

        # Get the last 1000 lines (or all if fewer)
        my $start_index = @lines > 1000 ? @lines - 1000 : 0;
        @last_lines = @lines[$start_index .. $#lines];
        $log_content = join('', @last_lines);
    }

    # Pass the log content and metadata to the template
    $c->stash(
        log_content   => $log_content,
        log_size      => $log_size_kb,
        max_log_size  => sprintf("%.2f", 500), # 500 KB max size (hardcoded to match Logging.pm)
        archived_logs => \@archived_logs,
        template      => 'admin/view_log.tt',
    );

    $c->forward($c->view('TT'));
}

sub view_archived_log :Path('/admin/view_archived_log') :Args(1) {
    my ($self, $c, $log_name) = @_;

    # Validate log name to prevent directory traversal
    unless ($log_name =~ /^application\.log_\d{8}_\d{6}$/) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'view_archived_log', "Invalid log name: $log_name");
        $c->flash->{error_msg} = "Invalid log name";
        $c->response->redirect($c->uri_for('/admin/view_log'));
        return;
    }

    # Get the actual log file path from the Logging module
    my $main_log_file;

    if (defined $Comserv::Util::Logging::LOG_FILE) {
        $main_log_file = $Comserv::Util::Logging::LOG_FILE;
    } else {
        $main_log_file = $c->path_to('logs', 'application.log');
    }

    my ($volume, $directories, $filename) = File::Spec->splitpath($main_log_file);
    my $archive_dir = File::Spec->catdir($directories, 'archive');
    my $log_file = File::Spec->catfile($archive_dir, $log_name);

    # Check if the log file exists
    unless (-e $log_file && -f $log_file) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'view_archived_log', "Archived log not found: $log_file");
        $c->flash->{error_msg} = "Archived log not found";
        $c->response->redirect($c->uri_for('/admin/view_log'));
        return;
    }

    # Read the log file
    my $log_content;
    {
        local $/; # Enable slurp mode
        open my $fh, '<', $log_file or die "Cannot open log file: $!";
        $log_content = <$fh>;
        close $fh;
    }

    # Get log file size
    my $log_size_kb = sprintf("%.2f", (-s $log_file) / 1024);

    # Pass the log content to the template
    $c->stash(
        log_content => $log_content,
        log_name    => $log_name,
        log_size    => $log_size_kb,
        template    => 'admin/view_archived_log.tt',
    );

    $c->forward($c->view('TT'));
}

=head2 git_pull

Pull the latest changes from the Git repository

=cut

sub git_pull :Path('/admin/git_pull') :Args(0) {
    my ($self, $c) = @_;
    
    # Debug logging for git_pull action
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'git_pull', "Starting git_pull action");
    
    # Log user information for debugging
    my $username = $c->user_exists ? $c->user->username : 'Guest';
    my $roles = $c->session->{roles} || [];
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'git_pull', 
        "User: $username, Roles: " . Dumper($roles));
    
    # Initialize debug messages array
    # Make sure debug_msg is an array reference
    if (!defined $c->stash->{debug_msg}) {
        $c->stash->{debug_msg} = [];
    } elsif (!ref($c->stash->{debug_msg}) || ref($c->stash->{debug_msg}) ne 'ARRAY') {
        # If debug_msg exists but is not an array reference, convert it to an array
        my $original_msg = $c->stash->{debug_msg};
        $c->stash->{debug_msg} = [];
        push @{$c->stash->{debug_msg}}, $original_msg if $original_msg;
    }
    
    # Add debug messages to the stash
    push @{$c->stash->{debug_msg}}, "User: $username";
    push @{$c->stash->{debug_msg}}, "Roles: " . Dumper($roles);
    
    # Check if the user has the admin role in the session
    my $is_admin = 0;
    
    # Check if the user has admin role in the session
    if (defined $c->session->{roles} && ref($c->session->{roles}) eq 'ARRAY') {
        $is_admin = grep { $_ eq 'admin' } @{$c->session->{roles}};
    }
    
    # Log the admin check
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'git_pull', 
        "Admin check result: " . ($is_admin ? 'Yes' : 'No'));
    push @{$c->stash->{debug_msg}}, "Admin check result: " . ($is_admin ? 'Yes' : 'No');
    
    unless ($is_admin) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'git_pull', 
            "Unauthorized access attempt by user: " . ($c->session->{username} || 'Guest'));
        $c->stash->{error_msg} = "You must be an admin to perform this action. Please contact your administrator.";
        $c->stash->{template} = 'admin/git_pull.tt';
        $c->forward($c->view('TT'));
        return;
    }
    
    # Initialize output and error variables
    my $output = '';
    my $error = '';
    
    # If this is a POST request, perform the git pull
    if ($c->request->method eq 'POST' && $c->request->params->{confirm}) {
        # Get the application root directory
        my $app_root = $c->path_to('');
        
        # Log the directory where we're running git pull
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'git_pull', 
            "Running git pull in directory: $app_root");
        # Ensure debug_msg is an array reference before pushing
        $c->stash->{debug_msg} = [] unless ref($c->stash->{debug_msg}) eq 'ARRAY';
        push @{$c->stash->{debug_msg}}, "Running git pull in directory: $app_root";
        
        # Change to the application root directory
        my $current_dir = getcwd();
        chdir($app_root) or do {
            $error = "Failed to change to directory $app_root: $!";
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'git_pull', $error);
            $c->stash->{error_msg} = $error;
            # Ensure debug_msg is an array reference before pushing
            $c->stash->{debug_msg} = [] unless ref($c->stash->{debug_msg}) eq 'ARRAY';
            push @{$c->stash->{debug_msg}}, "Error: $error";
            $c->stash->{template} = 'admin/git_pull.tt';
            $c->forward($c->view('TT'));
            return;
        };
        
        # Run git status first to check the repository state
        my $git_status = qx{git status 2>&1};
        my $status_exit_code = $? >> 8;
        
        if ($status_exit_code != 0) {
            $error = "Error checking git status: $git_status";
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'git_pull', $error);
            chdir($current_dir);
            $c->stash->{error_msg} = $error;
            # Ensure debug_msg is an array reference before pushing
            $c->stash->{debug_msg} = [] unless ref($c->stash->{debug_msg}) eq 'ARRAY';
            push @{$c->stash->{debug_msg}}, "Error: $error";
            $c->stash->{template} = 'admin/git_pull.tt';
            $c->forward($c->view('TT'));
            return;
        }
        
        # Check if there are uncommitted changes
        my $has_changes = 0;
        my $has_theme_mappings_changes = 0;
        
        if ($git_status =~ /Changes not staged for commit|Changes to be committed|Untracked files/) {
            $has_changes = 1;
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'git_pull', 
                "Repository has uncommitted changes: $git_status");
            # Ensure debug_msg is an array reference before pushing
            $c->stash->{debug_msg} = [] unless ref($c->stash->{debug_msg}) eq 'ARRAY';
            push @{$c->stash->{debug_msg}}, "Warning: Repository has uncommitted changes";
            
            # Check specifically for theme_mappings.json changes
            if ($git_status =~ /theme_mappings\.json/) {
                $has_theme_mappings_changes = 1;
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'git_pull', 
                    "Detected changes to theme_mappings.json, will handle specially");
                push @{$c->stash->{debug_msg}}, "Detected changes to theme_mappings.json, will handle specially";
                
                # Backup theme_mappings.json before proceeding
                my $theme_mappings_path = "Comserv/root/static/config/theme_mappings.json";
                my $backup_path = "Comserv/root/static/config/theme_mappings.json.bak";
                
                # Create a backup
                my $cp_result = qx{cp $theme_mappings_path $backup_path 2>&1};
                my $cp_exit_code = $? >> 8;
                
                if ($cp_exit_code == 0) {
                    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'git_pull', 
                        "Successfully backed up theme_mappings.json");
                    push @{$c->stash->{debug_msg}}, "Successfully backed up theme_mappings.json";
                } else {
                    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'git_pull', 
                        "Failed to backup theme_mappings.json: $cp_result");
                    push @{$c->stash->{debug_msg}}, "Warning: Failed to backup theme_mappings.json: $cp_result";
                }
                
                # Stash only theme_mappings.json changes
                my $stash_result = qx{git stash push -m "Auto-stashed theme_mappings.json changes" -- $theme_mappings_path 2>&1};
                my $stash_exit_code = $? >> 8;
                
                if ($stash_exit_code == 0) {
                    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'git_pull', 
                        "Successfully stashed theme_mappings.json changes: $stash_result");
                    push @{$c->stash->{debug_msg}}, "Successfully stashed theme_mappings.json changes";
                } else {
                    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'git_pull', 
                        "Failed to stash theme_mappings.json changes: $stash_result");
                    push @{$c->stash->{debug_msg}}, "Warning: Failed to stash theme_mappings.json changes: $stash_result";
                }
            }
        }
        
        # Run git pull
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'git_pull', 
            "Executing git pull");
        $output = qx{git pull 2>&1};
        my $exit_code = $? >> 8;
        
        # Change back to the original directory
        chdir($current_dir);
        
        if ($exit_code == 0) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'git_pull', 
                "Git pull executed successfully. Output: $output");
                
            # Check if there were any updates
            if ($output =~ /Already up to date/) {
                $c->stash->{success_msg} = "Repository is already up to date.";
            } else {
                $c->stash->{success_msg} = "Git pull executed successfully. Updates were applied.";
            }
            
            # If we stashed theme_mappings.json changes, try to apply them back
            if ($has_theme_mappings_changes) {
                # Change back to the app root directory to apply stash
                chdir($app_root) or do {
                    $error = "Failed to change to directory $app_root to apply stash: $!";
                    $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'git_pull', $error);
                    push @{$c->stash->{debug_msg}}, "Error: $error";
                    $c->stash->{warning_msg} = "Git pull succeeded but could not apply stashed theme_mappings.json changes. " .
                        "Your changes are saved in the Git stash and can be applied manually.";
                    chdir($current_dir);
                    return;
                };
                
                # Apply the stashed changes
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'git_pull', 
                    "Attempting to apply stashed theme_mappings.json changes");
                push @{$c->stash->{debug_msg}}, "Attempting to apply stashed theme_mappings.json changes";
                
                # Try to apply the most recent stash
                my $stash_apply_result = qx{git stash apply 2>&1};
                my $stash_apply_exit_code = $? >> 8;
                
                if ($stash_apply_exit_code == 0) {
                    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'git_pull', 
                        "Successfully applied stashed theme_mappings.json changes");
                    push @{$c->stash->{debug_msg}}, "Successfully applied stashed theme_mappings.json changes";
                    $c->stash->{success_msg} .= " Your theme_mappings.json changes were preserved.";
                    
                    # Check for conflicts
                    my $status_after_apply = qx{git status 2>&1};
                    if ($status_after_apply =~ /both modified:.*theme_mappings\.json/) {
                        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'git_pull', 
                            "Conflict detected when applying theme_mappings.json changes");
                        push @{$c->stash->{debug_msg}}, "Conflict detected when applying theme_mappings.json changes";
                        $c->stash->{warning_msg} = "There was a conflict when applying your theme_mappings.json changes. " .
                            "A backup is available at Comserv/root/static/config/theme_mappings.json.bak";
                    }
                } else {
                    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'git_pull', 
                        "Failed to apply stashed theme_mappings.json changes: $stash_apply_result");
                    push @{$c->stash->{debug_msg}}, "Warning: Failed to apply stashed theme_mappings.json changes: $stash_apply_result";
                    $c->stash->{warning_msg} = "Git pull succeeded but could not apply stashed theme_mappings.json changes. " .
                        "Your changes are saved in the Git stash and as a backup file at Comserv/root/static/config/theme_mappings.json.bak";
                }
                
                # Change back to the original directory
                chdir($current_dir);
            }
            
            # Add a warning if there were other uncommitted changes
            if ($has_changes && !$has_theme_mappings_changes) {
                $c->stash->{warning_msg} = "Note: Your repository had uncommitted changes. " .
                    "You may need to resolve conflicts manually.";
            }
        } else {
            $error = "Error executing git pull: $output";
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'git_pull', $error);
            $c->stash->{error_msg} = $error;
            
            # If we stashed theme_mappings.json changes but the pull failed, let the user know
            if ($has_theme_mappings_changes) {
                $c->stash->{warning_msg} = "Your theme_mappings.json changes were stashed before the failed pull attempt. " .
                    "They are saved in the Git stash and as a backup file at Comserv/root/static/config/theme_mappings.json.bak";
            }
        }
        
        # Add the output to the stash
        $c->stash->{output} = $output;
        
        # Add debug messages to the stash
        # Ensure debug_msg is an array reference before pushing
        $c->stash->{debug_msg} = [] unless ref($c->stash->{debug_msg}) eq 'ARRAY';
        push @{$c->stash->{debug_msg}}, "Git pull command executed";
        push @{$c->stash->{debug_msg}}, "Output: $output" if $output;
        push @{$c->stash->{debug_msg}}, "Error: $error" if $error;
    } else {
        # This is a GET request or no confirmation, just show the confirmation page
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'git_pull', 
            "Displaying git pull confirmation page");
        # Ensure debug_msg is an array reference before pushing
        $c->stash->{debug_msg} = [] unless ref($c->stash->{debug_msg}) eq 'ARRAY';
        push @{$c->stash->{debug_msg}}, "Displaying git pull confirmation page";
    }
    
    # Set the template
    $c->stash->{template} = 'admin/git_pull.tt';
    
    # Forward to the view
    $c->forward($c->view('TT'));
}

=head2 restart_starman

Restart the Starman server

=cut

sub restart_starman :Path('/admin/restart_starman') :Args(0) {
    my ($self, $c) = @_;
    
    # Debug logging for restart_starman action
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'restart_starman', 
        "Starting restart_starman action from " . $c->req->address . 
        " with method " . $c->req->method . 
        " to server " . $c->req->env->{SERVER_NAME});
    
    # Log user information for debugging
    my $username = $c->session->{username} || 'Guest';
    my $roles = $c->session->{roles} || [];
    my $roles_str = ref($roles) eq 'ARRAY' ? join(', ', @$roles) : 'none';
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'restart_starman', 
        "User: $username, Roles: $roles_str");
    
    # Initialize debug messages array
    # Make sure debug_msg is an array reference
    if (!defined $c->stash->{debug_msg}) {
        $c->stash->{debug_msg} = [];
    } elsif (!ref($c->stash->{debug_msg}) || ref($c->stash->{debug_msg}) ne 'ARRAY') {
        # If debug_msg exists but is not an array reference, convert it to an array
        my $original_msg = $c->stash->{debug_msg};
        $c->stash->{debug_msg} = [];
        push @{$c->stash->{debug_msg}}, $original_msg if $original_msg;
    }
    
    # Add debug messages to the stash
    push @{$c->stash->{debug_msg}}, "User: $username";
    push @{$c->stash->{debug_msg}}, "Roles: " . Dumper($roles);
    
    # Check if the user has the admin role in the session
    my $is_admin = 0;
    
    # Check if the user has admin role in the session
    if (defined $c->session->{roles} && ref($c->session->{roles}) eq 'ARRAY') {
        $is_admin = grep { $_ eq 'admin' } @{$c->session->{roles}};
    }
    
    # Also check if user is logged in and has user_id
    my $user_exists = ($c->session->{username} && $c->session->{user_id}) ? 1 : 0;
    push @{$c->stash->{debug_msg}}, "User exists: " . ($user_exists ? 'Yes' : 'No');
    push @{$c->stash->{debug_msg}}, "Username: " . ($c->session->{username} || 'Not logged in');
    push @{$c->stash->{debug_msg}}, "Session roles: " . (join(', ', @{$c->session->{roles}}) || 'None');
    push @{$c->stash->{debug_msg}}, "Is admin: " . ($is_admin ? 'Yes' : 'No');
    
    # Log the admin check
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'restart_starman', 
        "Admin check result: " . ($is_admin ? 'Yes' : 'No'));
    push @{$c->stash->{debug_msg}}, "Admin check result: " . ($is_admin ? 'Yes' : 'No');
    
    # If user has 'admin' in roles array, they are an admin
    if (defined $c->session->{roles} && ref($c->session->{roles}) eq 'ARRAY') {
        foreach my $role (@{$c->session->{roles}}) {
            if (lc($role) eq 'admin') {
                $is_admin = 1;
                last;
            }
        }
    }
    
    # Also check if is_admin flag is set in session
    if ($c->session->{is_admin}) {
        $is_admin = 1;
    }
    
    # Log the final admin check after all checks
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'restart_starman', 
        "Final admin check result: " . ($is_admin ? 'Yes' : 'No'));
    push @{$c->stash->{debug_msg}}, "Final admin check result: " . ($is_admin ? 'Yes' : 'No');
    
    unless ($is_admin) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'restart_starman', 
            "Unauthorized access attempt by user: " . ($c->session->{username} || 'Guest'));
        $c->stash->{error_msg} = "You must be an admin to perform this action. Please contact your administrator.";
        $c->stash->{template} = 'admin/restart_starman.tt';
        $c->forward($c->view('TT'));
        return;
    }
    
    # Initialize output and error variables
    my $output = '';
    my $error = '';
    
    # If this is a POST request, perform the restart
    if ($c->request->method eq 'POST' && $c->request->params->{confirm}) {
        # Log the restart attempt
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'restart_starman', 
            "Attempting to restart Starman server");
        
        # Ensure debug_msg is an array reference before pushing
        $c->stash->{debug_msg} = [] unless ref($c->stash->{debug_msg}) eq 'ARRAY';
        push @{$c->stash->{debug_msg}}, "Attempting to restart Starman server";
        
        # Check if we have username and password from the form
        my $sudo_username = $c->request->params->{sudo_username};
        my $sudo_password = $c->request->params->{sudo_password};
        
        # Always show the credentials form on the first confirmation step
        # This ensures the form is displayed on both workstation and production
        if ((!$sudo_username || !$sudo_password || $c->request->params->{show_credentials_form}) && 
            $c->request->method eq 'POST' && $c->request->params->{confirm}) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'restart_starman', 
                "Showing credentials form for Starman restart");
            $c->stash->{show_password_form} = 1;
            $c->stash->{debug_msg} = [] unless ref($c->stash->{debug_msg}) eq 'ARRAY';
            push @{$c->stash->{debug_msg}}, "Displaying credentials form for Starman restart";
            push @{$c->stash->{debug_msg}}, "Username provided: " . ($sudo_username ? 'Yes' : 'No');
            push @{$c->stash->{debug_msg}}, "Password provided: " . ($sudo_password ? 'Yes' : 'No');
            $c->stash->{template} = 'admin/restart_starman.tt';
            $c->forward($c->view('TT'));
            return;
        }
        
        # If we have username and password from the form, use them
        my $restart_command;
        if ($sudo_username && $sudo_password) {
            # Escape single quotes in the username and password to prevent command injection
            $sudo_username =~ s/'/'\\''/g;
            $sudo_password =~ s/'/'\\''/g;
            
            # Use sudo -u to run the command as the specified user
            $restart_command = "echo '$sudo_password' | sudo -S -u $sudo_username systemctl restart starman 2>&1";
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'restart_starman', 
                "Using username and password from form");
            
            # Log the username being used (but not the password)
            push @{$c->stash->{debug_msg}}, "Using username: $sudo_username";
            
            # Clear the password from the request parameters for security
            delete $c->request->params->{sudo_password};
        }
        # Otherwise, try to use the environment variables
        elsif (defined $ENV{SUDO_USERNAME} && defined $ENV{SUDO_PASSWORD}) {
            $restart_command = "echo \$SUDO_PASSWORD | sudo -S -u \$SUDO_USERNAME systemctl restart starman 2>&1";
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'restart_starman', 
                "Using SUDO_USERNAME and SUDO_PASSWORD environment variables");
        }
        # If neither is available, show an error
        else {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'restart_starman', 
                "Missing username or password and environment variables are not set");
            $c->stash->{error_msg} = "Error: Please enter both your username and password to restart the Starman server.";
            $c->stash->{show_password_form} = 1;
            $c->stash->{debug_msg} = [] unless ref($c->stash->{debug_msg}) eq 'ARRAY';
            push @{$c->stash->{debug_msg}}, "Missing credentials, showing form";
            $c->stash->{template} = 'admin/restart_starman.tt';
            $c->forward($c->view('TT'));
            return;
        }
        
        # Execute the restart command
        $output = qx{$restart_command};
        my $exit_code = $? >> 8;
        
        if ($exit_code == 0) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'restart_starman', 
                "Starman server restarted successfully");
            $c->stash->{success_msg} = "Starman server restarted successfully.";
            
            # Check the status of the service
            my $status_command;
            if ($sudo_username && $sudo_password) {
                # Username and password are already escaped above
                $status_command = "echo '$sudo_password' | sudo -S -u $sudo_username systemctl status starman 2>&1";
            } else {
                $status_command = "echo \$SUDO_PASSWORD | sudo -S -u \$SUDO_USERNAME systemctl status starman 2>&1";
            }
            my $status_output = qx{$status_command};
            my $status_exit_code = $? >> 8;
            
            if ($status_exit_code == 0) {
                $output .= "\n\nService Status:\n" . $status_output;
                
                # Check if the service is active
                if ($status_output =~ /Active: active/) {
                    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'restart_starman', 
                        "Starman service is active");
                    $c->stash->{success_msg} .= " Service is active and running.";
                } else {
                    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'restart_starman', 
                        "Starman service may not be active after restart");
                    $c->stash->{warning_msg} = "Service restart command executed, but the service may not be active. Please check the output for details.";
                }
            } else {
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'restart_starman', 
                    "Could not get Starman service status after restart");
                $c->stash->{warning_msg} = "Service restart command executed, but could not verify service status.";
            }
        } else {
            $error = "Error restarting Starman server: $output";
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'restart_starman', 
                "Failed to restart Starman server. Exit code: " . ($? >> 8) . 
                ", Error: $output, Command used: [REDACTED]");
            
            # Add detailed error information to debug_msg
            push @{$c->stash->{debug_msg}}, "Exit code: " . ($? >> 8);
            push @{$c->stash->{debug_msg}}, "Raw output: $output";
            
            # Set user-friendly error message
            $c->stash->{error_msg} = "Failed to restart Starman server. Please check the network connection and try again.";
            
            # Add a suggestion to use network diagnostics
            $c->stash->{warning_msg} = "If the problem persists, try using the <a href=\"" . 
                $c->uri_for('/admin/network_diagnostics') . "\">Network Diagnostics</a> tool to troubleshoot connectivity issues.";
        }
        
        # Add the output to the stash
        $c->stash->{output} = $output;
        
        # Add debug messages to the stash
        # Ensure debug_msg is an array reference before pushing
        $c->stash->{debug_msg} = [] unless ref($c->stash->{debug_msg}) eq 'ARRAY';
        push @{$c->stash->{debug_msg}}, "Restart command executed";
        push @{$c->stash->{debug_msg}}, "Output: $output" if $output;
        push @{$c->stash->{debug_msg}}, "Error: $error" if $error;
    } else {
        # This is a GET request or no confirmation, just show the confirmation page
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'restart_starman', 
            "Displaying restart Starman confirmation page");
        
        # Log the request method and parameters for debugging
        my $req_method = $c->request->method;
        my $params = $c->request->params;
        my $params_str = join(', ', map { "$_ => " . ($params->{$_} || 'undef') } keys %$params);
        
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'restart_starman', 
            "Request method: $req_method, Parameters: $params_str");
        
        # Ensure debug_msg is an array reference before pushing
        $c->stash->{debug_msg} = [] unless ref($c->stash->{debug_msg}) eq 'ARRAY';
        push @{$c->stash->{debug_msg}}, "Displaying restart Starman confirmation page";
        push @{$c->stash->{debug_msg}}, "Request method: $req_method";
        push @{$c->stash->{debug_msg}}, "Request parameters: $params_str";
    }
    
    # Set the template
    $c->stash->{template} = 'admin/restart_starman.tt';
    
    # Forward to the view
    $c->forward($c->view('TT'));
}

=head2 network_devices

Admin interface to manage network devices

=cut

sub network_devices :Path('/admin/network_devices') :Args(0) {
    my ($self, $c) = @_;

    # Log the beginning of the network_devices action
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'network_devices', "Starting network_devices action");

    # Check if the user has admin role
    unless ($c->user_exists && $c->check_user_roles('admin')) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'network_devices', 'User does not have admin role');
        $c->response->redirect($c->uri_for('/'));
        return;
    }

    # Get the selected site filter (if any)
    my $site_filter = $c->req->param('site') || '';
    
    # Get all devices from the database
    my @devices = ();
    
    # Try to fetch devices from the database if the table exists
    eval {
        my $search_params = {};
        
        # Add site filter if specified
        if ($site_filter) {
            $search_params->{site_name} = $site_filter;
        }
        
        # Log the attempt to access the NetworkDevice table
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'network_devices', 
            "Attempting to access NetworkDevice table with filter: " . ($site_filter || 'None'));
        
        @devices = $c->model('DBEncy')->schema->resultset('NetworkDevice')->search(
            $search_params,
            { order_by => { -asc => 'device_name' } }
        );
        
        # Log success
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'network_devices', 
            "Successfully retrieved " . scalar(@devices) . " devices from the database");
    };
    
    # If there was an error (likely because the table doesn't exist yet)
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'network_devices', 
            "Error fetching devices: $@. Table may not exist yet.");
        
        # Add sample devices for demonstration if the table doesn't exist
        @devices = (
            { 
                id => 1, 
                device_name => 'Main Router', 
                ip_address => '192.168.1.1', 
                mac_address => '00:11:22:33:44:55',
                device_type => 'Router',
                location => 'Server Room',
                purpose => 'Main internet gateway',
                notes => 'Cisco router providing internet access and firewall',
                site_name => 'CSC'
            },
            { 
                id => 2, 
                device_name => 'Core Switch', 
                ip_address => '192.168.1.2', 
                mac_address => '00:11:22:33:44:56',
                device_type => 'Switch',
                location => 'Server Room',
                purpose => 'Core network switch',
                notes => 'Cisco Catalyst 9300 Series',
                site_name => 'CSC'
            },
            { 
                id => 3, 
                device_name => 'Office AP', 
                ip_address => '192.168.1.3', 
                mac_address => '00:11:22:33:44:57',
                device_type => 'Access Point',
                location => 'Main Office',
                purpose => 'Wireless access',
                notes => 'Cisco Meraki MR Series',
                site_name => 'CSC'
            },
            { 
                id => 4, 
                device_name => 'MCOOP Router', 
                ip_address => '10.0.0.1', 
                mac_address => '00:11:22:33:44:58',
                device_type => 'Router',
                location => 'MCOOP Office',
                purpose => 'Main router for MCOOP',
                notes => 'Ubiquiti EdgeRouter',
                site_name => 'MCOOP'
            },
            { 
                id => 5, 
                device_name => 'MCOOP Switch', 
                ip_address => '10.0.0.2', 
                mac_address => '00:11:22:33:44:59',
                device_type => 'Switch',
                location => 'MCOOP Office',
                purpose => 'Network switch for MCOOP',
                notes => 'Ubiquiti EdgeSwitch',
                site_name => 'MCOOP'
            }
        );
        
        # Filter by site if needed
        if ($site_filter) {
            @devices = grep { $_->{site_name} eq $site_filter } @devices;
        }
    }

    # Get list of sites for the filter dropdown
    my @sites = ();
    eval {
        @sites = $c->model('DBEncy::Site')->search(
            {},
            { order_by => { -asc => 'name' } }
        );
    };
    
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'network_devices', 
            "Error fetching sites: $@");
        
        # Add sample sites if we can't get them from the database
        @sites = (
            { id => 1, name => 'CSC' },
            { id => 2, name => 'MCOOP' },
            { id => 3, name => 'BMaster' }
        );
    }

    # Use the standard debug message system
    if ($c->session->{debug_mode}) {
        $c->stash->{debug_msg} = [] unless defined $c->stash->{debug_msg};
        push @{$c->stash->{debug_msg}}, "Admin controller network_devices view - Template: admin/network_devices.tt";
        push @{$c->stash->{debug_msg}}, "Device count: " . scalar(@devices);
        push @{$c->stash->{debug_msg}}, "Site filter: " . ($site_filter || 'None');
    }

    # Pass data to the template
    $c->stash(
        devices => \@devices,
        sites => \@sites,
        site_filter => $site_filter,
        template => 'admin/network_devices.tt'
    );
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'network_devices', 'Set template to admin/network_devices.tt');
    $c->forward($c->view('TT'));
}

=head2 add_network_device

Admin interface to add a new network device

=cut

sub add_network_device :Path('/admin/add_network_device') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_network_device', 'Enter add_network_device method');

    # Check if the user has admin role
    unless ($c->user_exists && $c->check_user_roles('admin')) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'add_network_device', 'User does not have admin role');
        $c->response->redirect($c->uri_for('/admin/network_devices'));
        return;
    }

    # Get list of sites for the dropdown
    my @sites = ();
    eval {
        @sites = $c->model('DBEncy::Site')->search(
            {},
            { order_by => { -asc => 'name' } }
        );
    };
    
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'add_network_device', 
            "Error fetching sites: $@");
        
        # Add sample sites if we can't get them from the database
        @sites = (
            { id => 1, name => 'CSC' },
            { id => 2, name => 'MCOOP' },
            { id => 3, name => 'BMaster' }
        );
    }

    # If this is a form submission, process it
    if ($c->req->method eq 'POST') {
        # Retrieve the form data
        my $device_name = $c->req->params->{device_name};
        my $ip_address = $c->req->params->{ip_address};
        my $mac_address = $c->req->params->{mac_address};
        my $device_type = $c->req->params->{device_type};
        my $location = $c->req->params->{location};
        my $purpose = $c->req->params->{purpose};
        my $notes = $c->req->params->{notes};
        my $site_name = $c->req->params->{site_name};

        # Log the device creation attempt
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_network_device',
            "Device creation attempt for device: $device_name with IP: $ip_address, Site: $site_name");

        # Ensure all required fields are filled
        unless ($device_name && $ip_address && $site_name) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'add_network_device',
                "Missing required fields for device creation");

            $c->stash(
                error_msg => 'Device name, IP address, and site are required',
                sites => \@sites,
                template => 'admin/add_network_device.tt',
            );
            $c->forward($c->view('TT'));
            return;
        }

        # Create the new device
        eval {
            $c->model('DBEncy')->schema->resultset('NetworkDevice')->create({
                device_name => $device_name,
                ip_address => $ip_address,
                mac_address => $mac_address,
                device_type => $device_type,
                location => $location,
                purpose => $purpose,
                notes => $notes,
                site_name => $site_name,
                created_at => \'NOW()',
            });

            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_network_device',
                "Device created successfully: $device_name with IP: $ip_address, Site: $site_name");

            # Set success message and redirect to device list
            $c->flash->{success_msg} = "Device '$device_name' created successfully.";
            $c->response->redirect($c->uri_for('/admin/network_devices', { site => $site_name }));
            return;
        };

        if ($@) {
            # Handle database errors
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'add_network_device',
                "Error creating device: $@");

            $c->stash(
                error_msg => "Error creating device: $@",
                sites => \@sites,
                template => 'admin/add_network_device.tt',
            );
            $c->forward($c->view('TT'));
            return;
        }
    }

    # Display the add device form
    $c->stash(
        sites => \@sites,
        template => 'admin/add_network_device.tt',
    );
    $c->forward($c->view('TT'));
}

=head2 edit_network_device

Admin interface to edit a network device

=cut

sub edit_network_device :Path('/admin/edit_network_device') :Args(1) {
    my ($self, $c, $device_id) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_network_device', "Enter edit_network_device method for device ID: $device_id");

    # Check if the user has admin role
    unless ($c->user_exists && $c->check_user_roles('admin')) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'edit_network_device', 'User does not have admin role');
        $c->response->redirect($c->uri_for('/admin/network_devices'));
        return;
    }

    # Get list of sites for the dropdown
    my @sites = ();
    eval {
        @sites = $c->model('DBEncy::Site')->search(
            {},
            { order_by => { -asc => 'name' } }
        );
    };
    
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'edit_network_device', 
            "Error fetching sites: $@");
        
        # Add sample sites if we can't get them from the database
        @sites = (
            { id => 1, name => 'CSC' },
            { id => 2, name => 'MCOOP' },
            { id => 3, name => 'BMaster' }
        );
    }

    # Try to find the device
    my $device;
    eval {
        $device = $c->model('DBEncy')->resultset('NetworkDevice')->find($device_id);
    };

    # Handle errors or device not found
    if ($@ || !$device) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'edit_network_device',
            "Device not found with ID: $device_id or error: $@");
            
        $c->flash->{error_msg} = "Device not found.";
        $c->response->redirect($c->uri_for('/admin/network_devices'));
        return;
    }

    # If this is a form submission, process it
    if ($c->req->method eq 'POST') {
        # Retrieve the form data
        my $device_name = $c->req->params->{device_name};
        my $ip_address = $c->req->params->{ip_address};
        my $mac_address = $c->req->params->{mac_address};
        my $device_type = $c->req->params->{device_type};
        my $location = $c->req->params->{location};
        my $purpose = $c->req->params->{purpose};
        my $notes = $c->req->params->{notes};
        my $site_name = $c->req->params->{site_name};

        # Log the device update attempt
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_network_device',
            "Device update attempt for device: $device_name with IP: $ip_address, Site: $site_name");

        # Ensure all required fields are filled
        unless ($device_name && $ip_address && $site_name) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'edit_network_device',
                "Missing required fields for device update");

            $c->stash(
                error_msg => 'Device name, IP address, and site are required',
                device => $device,
                sites => \@sites,
                template => 'admin/edit_network_device.tt',
            );
            $c->forward($c->view('TT'));
            return;
        }

        # Update the device
        eval {
            $device->update({
                device_name => $device_name,
                ip_address => $ip_address,
                mac_address => $mac_address,
                device_type => $device_type,
                location => $location,
                purpose => $purpose,
                notes => $notes,
                site_name => $site_name,
                updated_at => \'NOW()',
            });

            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_network_device',
                "Device updated successfully: $device_name with IP: $ip_address, Site: $site_name");

            # Set success message and redirect to device list
            $c->flash->{success_msg} = "Device '$device_name' updated successfully.";
            $c->response->redirect($c->uri_for('/admin/network_devices', { site => $site_name }));
            return;
        };

        if ($@) {
            # Handle database errors
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'edit_network_device',
                "Error updating device: $@");

            $c->stash(
                error_msg => "Error updating device: $@",
                device => $device,
                sites => \@sites,
                template => 'admin/edit_network_device.tt',
            );
            $c->forward($c->view('TT'));
            return;
        }
    }

    # Display the edit device form
    $c->stash(
        device => $device,
        sites => \@sites,
        template => 'admin/edit_network_device.tt',
    );
    $c->forward($c->view('TT'));
}

=head2 delete_network_device

Admin interface to delete a network device

=cut

sub delete_network_device :Path('/admin/delete_network_device') :Args(1) {
    my ($self, $c, $device_id) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'delete_network_device', "Enter delete_network_device method for device ID: $device_id");

    # Check if the user has admin role
    unless ($c->user_exists && $c->check_user_roles('admin')) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'delete_network_device', 'User does not have admin role');
        $c->response->redirect($c->uri_for('/admin/network_devices'));
        return;
    }

    # Try to find the device
    my $device;
    eval {
        $device = $c->model('DBEncy')->resultset('NetworkDevice')->find($device_id);
    };

    # Handle errors or device not found
    if ($@ || !$device) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'delete_network_device',
            "Device not found with ID: $device_id or error: $@");
            
        $c->flash->{error_msg} = "Device not found.";
        $c->response->redirect($c->uri_for('/admin/network_devices'));
        return;
    }

    # Store device name and site for logging and redirection
    my $device_name = $device->device_name;
    my $site_name = $device->site_name;
    
    # Delete the device
    eval {
        $device->delete;
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'delete_network_device',
            "Device deleted successfully: $device_name (ID: $device_id)");
            
        $c->flash->{success_msg} = "Device '$device_name' deleted successfully.";
    };
    
    if ($@) {
        # Handle any exceptions
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'delete_network_device',
            "Exception when deleting device: $@");
            
        $c->flash->{error_msg} = "An error occurred while deleting the device: $@";
    }
    
    # Redirect back to the device list page with the site filter if available
    $c->response->redirect($c->uri_for('/admin/network_devices', { site => $site_name }));
}

=head2 networkmap_redirect

Handles requests to /admin/networkmap and redirects to the proper capitalized URL.
This is a fallback to ensure users can access the NetworkMap regardless of URL case.

=cut

sub networkmap_redirect :Path('networkmap') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'networkmap_redirect', 
        "Redirecting from /admin/networkmap to /admin/NetworkMap");
    
    # Redirect to the uppercase version
    $c->response->redirect($c->uri_for('/admin/NetworkMap'));
}

__PACKAGE__->meta->make_immutable;
1;
