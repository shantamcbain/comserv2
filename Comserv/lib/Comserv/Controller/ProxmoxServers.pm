package Comserv::Controller::ProxmoxServers;
use Moose;
use namespace::autoclean;
use Comserv::Util::ProxmoxCredentials;
use Comserv::Util::Logging;
use JSON;
use Try::Tiny;

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

BEGIN { extends 'Catalyst::Controller'; }

__PACKAGE__->config(namespace => 'proxmox_servers');

=head1 NAME

Comserv::Controller::ProxmoxServers - Controller for managing Proxmox servers

=head1 DESCRIPTION

This controller provides actions to manage Proxmox server configurations.

=head1 METHODS

=cut

=head2 index

List all configured Proxmox servers

=cut

sub index :Path :Args(0) {
    my ($self, $c) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Starting Proxmox server management");

    # Get list of servers
    my $servers = Comserv::Util::ProxmoxCredentials::get_all_servers();
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'index', "Retrieved " . scalar(@$servers) . " Proxmox servers");

    # Add some debug messages to help diagnose issues
    my @debug_msgs = (
        "ProxmoxServers controller index action started",
        "Retrieved " . scalar(@$servers) . " Proxmox servers",
        "Credentials file path: " . Comserv::Util::ProxmoxCredentials::get_credentials_file_path(),
        "Credentials file exists: " . (-f Comserv::Util::ProxmoxCredentials::get_credentials_file_path() ? "YES" : "NO")
    );

    $c->stash(
        template => 'proxmox/servers.tt',
        servers => $servers,
        current_view => 'TT',
        debug_msg => \@debug_msgs,  # Initialize debug_msg array with useful information
    );
    $c->forward($c->view('TT'));

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Completed Proxmox server management");
}

=head2 add_server_form

Display the form to add a new Proxmox server

=cut

sub add_server_form :Path('add') :Args(0) {
    my ($self, $c) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_server_form', "Displaying add server form");

    $c->stash(
        template => 'proxmox/add_server.tt',
        form_data => {},
        current_view => 'TT',
    );
    $c->forward($c->view('TT'));

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_server_form', "Completed displaying add server form");
}

=head2 add_server

Process the form submission to add a new Proxmox server

=cut

sub add_server :Path('add_server') :Args(0) {
    my ($self, $c) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_server', "Processing add server form submission");

    # Get form parameters
    my $server_id = $c->req->params->{server_id} || 'default';
    my $credentials = {
        name => $c->req->params->{name} || $server_id,
        host => $c->req->params->{host} || '',
        api_url_base => $c->req->params->{api_url_base} || '',
        token_user => $c->req->params->{token_user} || '',
        token_value => $c->req->params->{token_value} || '',
        node => $c->req->params->{node} || 'pve',
        image_url_base => $c->req->params->{image_url_base} || '',
    };
    
    # Log the parameters
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'add_server',
        "Form parameters: name=" . ($credentials->{name} || 'undef') .
        ", host=" . ($credentials->{host} || 'undef') .
        ", token_user=" . ($credentials->{token_user} || 'undef'));

    # Validate required fields
    my @required_fields = qw(host token_user token_value);
    my @missing_fields = ();
    
    foreach my $field (@required_fields) {
        push @missing_fields, $field unless $credentials->{$field};
    }
    
    if (@missing_fields) {
        $c->stash(
            template => 'proxmox/add_server.tt',
            error_msg => 'Missing required fields: ' . join(', ', @missing_fields),
            form_data => $credentials,
            current_view => 'TT',
        );
        $c->forward($c->view('TT'));
        return;
    }
    
    # If api_url_base is not provided, generate it from the host
    unless ($credentials->{api_url_base}) {
        $credentials->{api_url_base} = "https://$credentials->{host}:8006/api2/json";
    }
    
    # Save the credentials
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'add_server', "Attempting to save credentials for server: $server_id");
    try {
        Comserv::Util::ProxmoxCredentials::save_credentials($server_id, $credentials);
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_server', "Credentials saved successfully for server: $server_id");
        $c->flash->{success_msg} = "Proxmox server '$server_id' has been added successfully.";
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'add_server', "Failed to save credentials: $_");
        $c->stash(
            template => 'proxmox/add_server.tt',
            error_msg => "Failed to save credentials: $_",
            form_data => $credentials,
            current_view => 'TT',
        );
        $c->forward($c->view('TT'));
        return;
    };

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_server', "Successfully added server: $server_id");

    # Redirect to the server list
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'add_server', "Redirecting to index");
    $c->detach('index');
}

=head2 edit_server_form

Display the form to edit a Proxmox server

=cut

sub edit_server_form :Path('edit') :Args(1) {
    my ($self, $c, $server_id) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_server_form', "Displaying edit server form for server: $server_id");

    # Get the server credentials
    my $credentials = Comserv::Util::ProxmoxCredentials::get_credentials($server_id);

    # If the server doesn't exist, redirect to the server list
    unless ($credentials->{host}) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'edit_server_form', "Proxmox server '$server_id' not found");
        $c->flash->{error_msg} = "Proxmox server '$server_id' not found.";
        $c->response->redirect($c->uri_for('/proxmox_servers'));
        return;
    }

    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'edit_server_form', "Prepared form data for server: $server_id");

    $c->stash(
        template => 'proxmox/edit_server.tt',
        server_id => $server_id,
        form_data => $credentials,
        current_view => 'TT',
    );
    $c->forward($c->view('TT'));

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_server_form', "Completed displaying edit server form for server: $server_id");
}

=head2 edit_server

Process the form submission to edit a Proxmox server

=cut

sub edit_server :Path('edit_server') :Args(0) {
    my ($self, $c) = @_;

    # Get form parameters
    my $server_id = $c->req->params->{server_id} || 'default';
    my $credentials = {
        name => $c->req->params->{name} || $server_id,
        host => $c->req->params->{host} || '',
        api_url_base => $c->req->params->{api_url_base} || '',
        token_user => $c->req->params->{token_user} || '',
        token_value => $c->req->params->{token_value} || '',
        node => $c->req->params->{node} || 'pve',
        image_url_base => $c->req->params->{image_url_base} || '',
    };

    # Validate required fields
    my @required_fields = qw(host token_user);
    my @missing_fields = ();
    
    foreach my $field (@required_fields) {
        push @missing_fields, $field unless $credentials->{$field};
    }
    
    if (@missing_fields) {
        $c->stash(
            template => 'proxmox/edit_server.tt',
            error_msg => 'Missing required fields: ' . join(', ', @missing_fields),
            server_id => $server_id,
            form_data => $credentials,
            current_view => 'TT',
        );
        $c->forward($c->view('TT'));
        return;
    }
    
    # If api_url_base is not provided, generate it from the host
    unless ($credentials->{api_url_base}) {
        $credentials->{api_url_base} = "https://$credentials->{host}:8006/api2/json";
    }
    
    # If token_value is empty, get the existing token
    unless ($credentials->{token_value}) {
        my $existing = Comserv::Util::ProxmoxCredentials::get_credentials($server_id);
        $credentials->{token_value} = $existing->{token_value};
    }
    
    # Save the credentials
    try {
        Comserv::Util::ProxmoxCredentials::save_credentials($server_id, $credentials);
        $c->flash->{success_msg} = "Proxmox server '$server_id' has been updated successfully.";
    } catch {
        $c->stash(
            template => 'proxmox/edit_server.tt',
            error_msg => "Failed to save credentials: $_",
            server_id => $server_id,
            form_data => $credentials,
            current_view => 'TT',
        );
        $c->forward($c->view('TT'));
        return;
    };
    
    # Redirect to the server list
    $c->response->redirect($c->uri_for('/proxmox_servers'));
}

=head2 delete_server

Delete a Proxmox server

=cut

sub delete_server :Path('delete') :Args(1) {
    my ($self, $c, $server_id) = @_;
    
    # Delete the server
    try {
        if (Comserv::Util::ProxmoxCredentials::delete_server($server_id)) {
            $c->flash->{success_msg} = "Proxmox server '$server_id' has been deleted successfully.";
        } else {
            $c->flash->{error_msg} = "Proxmox server '$server_id' not found.";
        }
    } catch {
        $c->flash->{error_msg} = "Failed to delete server: $_";
    };
    
    # Redirect to the server list
    $c->response->redirect($c->uri_for('/proxmox_servers'));
}

=head2 test_connection

Test the connection to a Proxmox server

=cut

sub test_connection :Path('test') :Args(1) {
    my ($self, $c, $server_id) = @_;

    # Log that we've entered the test_connection action with high visibility
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'test_connection',
        "*** ENTERED TEST_CONNECTION ACTION FOR SERVER: $server_id ***");
    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'test_connection',
        "*** TESTING CONNECTION FOR SERVER: $server_id ***");
    print STDERR "*** ENTERED TEST_CONNECTION ACTION FOR SERVER: $server_id ***\n";

    # Log the request path to verify the URL
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'test_connection',
        "Request path: " . $c->req->path);
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'test_connection',
        "Request method: " . $c->req->method);
    # Log a few important headers instead of trying to get all headers
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'test_connection',
        "Request headers: " .
        "User-Agent: " . ($c->req->header('User-Agent') || 'N/A') . ", " .
        "X-Requested-With: " . ($c->req->header('X-Requested-With') || 'N/A'));

    # Make sure debug_msg exists in the stash
    $c->stash->{debug_msg} = [] unless $c->stash->{debug_msg};

    # Use the application's debug message system
    push @{$c->stash->{debug_msg}}, "==== TEST_CONNECTION START ====";
    push @{$c->stash->{debug_msg}}, "Testing connection to Proxmox server: $server_id";

    # Use the application's logging system
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'test_connection', "==== TEST_CONNECTION START ====");
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'test_connection', "Testing connection to Proxmox server: $server_id");

    # Get the server credentials
    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'test_connection', "Getting credentials for server: $server_id");
    push @{$c->stash->{debug_msg}}, "Getting credentials for server: $server_id";

    # Check if the credentials file exists
    my $credentials_file = Comserv::Util::ProxmoxCredentials::get_credentials_file_path();
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'test_connection',
        "Credentials file path: $credentials_file, exists: " . (-f $credentials_file ? "YES" : "NO"));
    push @{$c->stash->{debug_msg}}, "Credentials file path: $credentials_file, exists: " . (-f $credentials_file ? "YES" : "NO");

    my $credentials = Comserv::Util::ProxmoxCredentials::get_credentials($server_id);
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'test_connection',
        "Credentials retrieved: " . ($credentials ? "YES" : "NO") .
        ", Host: " . ($credentials->{host} || "UNDEFINED") .
        ", Token User: " . ($credentials->{token_user} || "UNDEFINED"));

    push @{$c->stash->{debug_msg}}, "Credentials retrieved: " . ($credentials ? "YES" : "NO");

    # Log more details about the credentials with high visibility
    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'test_connection',
        "Credentials retrieved for server $server_id: " .
        "Host=" . ($credentials->{host} || "UNDEFINED") . ", " .
        "Token User=" . ($credentials->{token_user} || "UNDEFINED") . ", " .
        "Token Value=" . ($credentials->{token_value} ? "Present (length: " . length($credentials->{token_value}) . ")" : "MISSING"));

    if ($credentials) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'test_connection', "Host: " . ($credentials->{host} || "UNDEFINED"));
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'test_connection', "API Token User: " . ($credentials->{token_user} || "UNDEFINED"));
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'test_connection', "API Token Value: " . ($credentials->{token_value} ? "Present (length: " . length($credentials->{token_value}) . ")" : "MISSING"));

        push @{$c->stash->{debug_msg}}, "Host: " . ($credentials->{host} || "UNDEFINED");
        push @{$c->stash->{debug_msg}}, "API Token User: " . ($credentials->{token_user} || "UNDEFINED");
        push @{$c->stash->{debug_msg}}, "API Token Value: " . ($credentials->{token_value} ? "Present (length: " . length($credentials->{token_value}) . ")" : "MISSING");
        push @{$c->stash->{debug_msg}}, "API URL: " . ($credentials->{api_url_base} || "https://" . $credentials->{host} . ":8006/api2/json");
    }

    # If the server doesn't exist, return an error
    unless ($credentials && $credentials->{host}) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'test_connection', "Proxmox server not found: $server_id");
        push @{$c->stash->{debug_msg}}, "ERROR: Proxmox server not found: $server_id";

        $c->stash(
            json => {
                success => 0,
                error => "Proxmox server '$server_id' not found.",
                debug_msg => $c->stash->{debug_msg},
            }
        );
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'test_connection', "==== TEST_CONNECTION END (Server not found) ====");
        push @{$c->stash->{debug_msg}}, "==== TEST_CONNECTION END (Server not found) ====";

        $c->forward('View::JSON');
        return;
    }

    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'test_connection',
        "Attempting to connect to Proxmox server: $credentials->{host} using API token");
    push @{$c->stash->{debug_msg}}, "Attempting to connect to Proxmox server: $credentials->{host} using API token";

    # Test the connection
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'test_connection', "Loading Proxmox model");
    push @{$c->stash->{debug_msg}}, "Loading Proxmox model...";

    my $proxmox;
    eval {
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'test_connection', "Initializing Proxmox model with:");
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'test_connection', "  Host: " . $credentials->{host});
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'test_connection', "  API URL: " . $credentials->{api_url_base});
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'test_connection', "  Node: " . ($credentials->{node} || "default"));
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'test_connection', "  Token User: " . ($credentials->{token_user} || "UNDEFINED"));
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'test_connection', "  Token Value: " .
            ($credentials->{token_value} ? "Present (length: " . length($credentials->{token_value}) . ")" : "MISSING"));

        push @{$c->stash->{debug_msg}}, "Initializing Proxmox model...";
        push @{$c->stash->{debug_msg}}, "Host: " . $credentials->{host};
        push @{$c->stash->{debug_msg}}, "API URL: " . ($credentials->{api_url_base} || "https://" . $credentials->{host} . ":8006/api2/json");
        push @{$c->stash->{debug_msg}}, "Node: " . ($credentials->{node} || "pve");
        push @{$c->stash->{debug_msg}}, "Token User: " . ($credentials->{token_user} || "UNDEFINED");
        push @{$c->stash->{debug_msg}}, "Token Value: " .
            ($credentials->{token_value} ? "Present (length: " . length($credentials->{token_value}) . ")" : "MISSING");

        # Warning: The Proxmox model doesn't ACCEPT_CONTEXT, so we need to pass the context separately
        $proxmox = $c->model('Proxmox');

        # Manually set the properties since the model doesn't accept them in the constructor
        $proxmox->{proxmox_host} = $credentials->{host} if $credentials->{host};
        $proxmox->{api_url_base} = $credentials->{api_url_base} if $credentials->{api_url_base};
        $proxmox->{node} = $credentials->{node} || 'pve';
        $proxmox->{image_url_base} = $credentials->{image_url_base} if $credentials->{image_url_base};
        $proxmox->{c} = $c;  # Make sure the model has access to the context

        # Log the model configuration
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'test_connection',
            "Proxmox model configured with: " .
            "Host=" . $proxmox->{proxmox_host} . ", " .
            "API URL=" . $proxmox->{api_url_base} . ", " .
            "Node=" . $proxmox->{node});

        push @{$c->stash->{debug_msg}}, "Proxmox model configured with:";
        push @{$c->stash->{debug_msg}}, "  Host: " . $proxmox->{proxmox_host};
        push @{$c->stash->{debug_msg}}, "  API URL: " . $proxmox->{api_url_base};
        push @{$c->stash->{debug_msg}}, "  Node: " . $proxmox->{node};

        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'test_connection', "Proxmox model initialized successfully");
        push @{$c->stash->{debug_msg}}, "Proxmox model initialized successfully";
    };
    if ($@) {
        my $error_msg = "Error loading Proxmox model: $@";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'test_connection', $error_msg);
        push @{$c->stash->{debug_msg}}, "ERROR: $error_msg";

        $c->stash(
            json => {
                success => 0,
                error => "Internal error: Failed to load Proxmox model: $@",
                debug_msg => $c->stash->{debug_msg},
            }
        );
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'test_connection', "==== TEST_CONNECTION END (Model load error) ====");
        push @{$c->stash->{debug_msg}}, "==== TEST_CONNECTION END (Model load error) ====";

        $c->forward('View::JSON');
        return;
    }

    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'test_connection', "Proxmox model loaded successfully");
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'test_connection',
        "Proxmox model loaded successfully with host: $credentials->{host}, api_url: $credentials->{api_url_base}");

    push @{$c->stash->{debug_msg}}, "Proxmox model loaded successfully";
    push @{$c->stash->{debug_msg}}, "Host: $credentials->{host}, API URL: $credentials->{api_url_base}";
    my $auth_success = 0;
    my $error_message = '';
    my $start_time = time();

    # Try to authenticate with Proxmox with a timeout
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'test_connection',
        "Attempting to authenticate with API token: " . $credentials->{token_user});
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'test_connection',
        "Starting authentication with 10 second timeout");

    push @{$c->stash->{debug_msg}}, "Attempting to authenticate with API token: " . $credentials->{token_user};
    push @{$c->stash->{debug_msg}}, "Starting authentication with 10 second timeout";

    eval {
        # Set alarm for timeout (10 seconds)
        local $SIG{ALRM} = sub { die "Connection timed out after 10 seconds\n" };
        alarm(10);

        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'test_connection', "Calling authenticate_with_token method...");
        push @{$c->stash->{debug_msg}}, "Calling authenticate_with_token method...";

        # Use the token authentication method instead of username/password
        $auth_success = $proxmox->authenticate_with_token(
            $credentials->{token_user},
            $credentials->{token_value}
        );

        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'test_connection',
            "Authentication result: " . ($auth_success ? "SUCCESS" : "FAILED"));
        push @{$c->stash->{debug_msg}}, "Authentication result: " . ($auth_success ? "SUCCESS" : "FAILED");

        # Clear the alarm
        alarm(0);
    };

    my $end_time = time();
    my $elapsed = $end_time - $start_time;

    # Check for errors
    if ($@) {
        $error_message = $@;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'test_connection',
            "Connection error: $error_message");
        push @{$c->stash->{debug_msg}}, "ERROR: Connection error: $error_message";
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'test_connection',
        "Authentication completed in $elapsed seconds");
    push @{$c->stash->{debug_msg}}, "Authentication completed in $elapsed seconds";

    # Collect all log entries for display in the browser
    my @log_entries = (
        { level => 'info', message => "Started connection test for server: $server_id", timestamp => scalar(localtime($start_time)) },
        { level => 'info', message => "Using host: $credentials->{host}", timestamp => scalar(localtime($start_time)) },
        { level => 'info', message => "API URL: " . ($credentials->{api_url_base} || "https://$credentials->{host}:8006/api2/json"), timestamp => scalar(localtime($start_time)) },
        { level => 'info', message => "Token user: $credentials->{token_user}", timestamp => scalar(localtime($start_time)) },
        { level => 'info', message => "Authentication attempt started", timestamp => scalar(localtime($start_time)) }
    );

    # Add authentication result to logs
    if ($auth_success) {
        push @log_entries, { level => 'success', message => "Authentication successful!", timestamp => scalar(localtime($end_time)) };
    } else {
        push @log_entries, {
            level => 'error',
            message => "Authentication failed: " . ($error_message || "Unknown error"),
            timestamp => scalar(localtime($end_time))
        };
    }

    # Add completion entry
    push @log_entries, {
        level => 'info',
        message => "Authentication completed in $elapsed seconds",
        timestamp => scalar(localtime($end_time))
    };

    # Collect debug information
    my $debug_info = {
        server_id => $server_id,
        elapsed_time => $elapsed,
        host => $credentials->{host},
        api_url_base => $credentials->{api_url_base},
        token_user => $credentials->{token_user},
        node => $credentials->{node},
        auth_success => $auth_success ? 1 : 0,
        log_entries => \@log_entries,
    };

    # Add model debug info if available
    if ($proxmox && $proxmox->{debug_info}) {
        $debug_info->{proxmox_debug} = $proxmox->{debug_info};

        # Log the current state of debug messages
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'test_connection',
            "Debug messages in stash: " . ($c->stash->{debug_msg} ? scalar(@{$c->stash->{debug_msg}}) : "none"));

        # Log the debug_log from the model
        if ($proxmox->{debug_info}->{debug_log}) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'test_connection',
                "Debug log in model: " . scalar(@{$proxmox->{debug_info}->{debug_log}}) . " messages");

            # Log the first few messages from the model's debug log
            my $count = 0;
            foreach my $msg (@{$proxmox->{debug_info}->{debug_log}}) {
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'test_connection',
                    "Model debug[$count]: $msg");
                $count++;
                last if $count >= 5; # Only log the first 5 messages
            }
        }

        # If we have debug_log in the model but no debug_msg in the stash,
        # use the debug_log from the model
        if ($proxmox->{debug_info}->{debug_log} &&
            (!$c->stash->{debug_msg} || !@{$c->stash->{debug_msg}})) {
            $c->stash->{debug_msg} = $proxmox->{debug_info}->{debug_log};
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'test_connection',
                "Using model's debug_log for stash debug_msg");
        }
        # Even if we have debug_msg, append the model's debug_log
        elsif ($proxmox->{debug_info}->{debug_log}) {
            push @{$c->stash->{debug_msg}}, "--- Model Debug Log ---";
            push @{$c->stash->{debug_msg}}, @{$proxmox->{debug_info}->{debug_log}};
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'test_connection',
                "Appended model's debug_log to stash debug_msg");
        }
    }

    if ($auth_success) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'test_connection',
            "Successfully connected to Proxmox server '$server_id' in $elapsed seconds");
        push @{$c->stash->{debug_msg}}, "Successfully connected to Proxmox server '$server_id' in $elapsed seconds";

        # Log the final state of debug messages before sending response
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'test_connection',
            "Final debug messages count: " . ($c->stash->{debug_msg} ? scalar(@{$c->stash->{debug_msg}}) : "none"));

        # Add a timestamp to each debug message for clarity
        my $timestamp = scalar(localtime());
        my @timestamped_msgs = map { "[$timestamp] $_" } @{$c->stash->{debug_msg}};

        $c->stash(
            json => {
                success => 1,
                message => "Successfully connected to Proxmox server '$server_id'.",
                elapsed_time => $elapsed,
                debug_info => $debug_info,
                debug_msg => $c->stash->{debug_msg},
                debug_msg_count => scalar(@{$c->stash->{debug_msg}}),
            }
        );
    } else {
        # Get detailed error information if available
        my $error = $error_message || "Failed to authenticate. Please check the API token format and value.";
        my $possible_cause = "";

        # Check if we have more specific error information from the model
        if ($proxmox && $proxmox->{debug_info}) {
            if ($proxmox->{debug_info}->{error_type}) {
                $error = $proxmox->{debug_info}->{error_type};
            }
            if ($proxmox->{debug_info}->{possible_cause}) {
                $possible_cause = $proxmox->{debug_info}->{possible_cause};
            }
        }

        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'test_connection',
            "Failed to connect to Proxmox server '$server_id': $error");
        if ($possible_cause) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'test_connection',
                "Possible cause: $possible_cause");
        }

        # Add error details to debug info
        $debug_info->{error_message} = $error;
        $debug_info->{possible_cause} = $possible_cause if $possible_cause;

        # Create a detailed error message
        my $error_message = "Failed to connect to Proxmox server '$server_id': $error";
        if ($possible_cause) {
            $error_message .= "\n\nPossible cause: $possible_cause";
        }

        push @{$c->stash->{debug_msg}}, "ERROR: Failed to connect to Proxmox server '$server_id': $error";
        if ($possible_cause) {
            push @{$c->stash->{debug_msg}}, "Possible cause: $possible_cause";
        }

        # Log the final state of debug messages before sending error response
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'test_connection',
            "Final debug messages count (error case): " . ($c->stash->{debug_msg} ? scalar(@{$c->stash->{debug_msg}}) : "none"));

        # Add a timestamp to each debug message for clarity
        my $timestamp = scalar(localtime());
        my @timestamped_msgs = map { "[$timestamp] $_" } @{$c->stash->{debug_msg}};

        # Log the first few debug messages
        my $count = 0;
        foreach my $msg (@timestamped_msgs) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'test_connection',
                "Debug message[$count]: $msg");
            $count++;
            last if $count >= 5; # Only log the first 5 messages
        }

        $c->stash(
            json => {
                success => 0,
                error => $error_message,
                elapsed_time => $elapsed,
                debug_info => $debug_info,
                debug_msg => $c->stash->{debug_msg},
                debug_msg_count => scalar(@{$c->stash->{debug_msg}}),
            }
        );
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'test_connection', "==== TEST_CONNECTION END ====");
    push @{$c->stash->{debug_msg}}, "==== TEST_CONNECTION END ====";

    # Log the final JSON response and debug_msg contents
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'test_connection',
        "Final JSON response: " . encode_json($c->stash->{json}));

    # Log the debug_msg array contents
    if ($c->stash->{debug_msg} && @{$c->stash->{debug_msg}}) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'test_connection',
            "debug_msg array has " . scalar(@{$c->stash->{debug_msg}}) . " entries");
        my $count = 0;
        foreach my $msg (@{$c->stash->{debug_msg}}) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'test_connection',
                "debug_msg[$count]: $msg");
            $count++;
        }
    } else {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'test_connection',
            "debug_msg array is empty or undefined");
    }

    # Check if this is an AJAX request or a direct browser request
    my $is_ajax = $c->req->header('X-Requested-With') && $c->req->header('X-Requested-With') eq 'XMLHttpRequest';
    $is_ajax = 1 if $c->req->param('format') && $c->req->param('format') eq 'json';

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'test_connection',
        "Request type: " . ($is_ajax ? "AJAX/JSON" : "Direct/HTML"));

    if ($is_ajax) {
        # For AJAX requests, return JSON
        $c->response->content_type('application/json');
        $c->response->body(encode_json($c->stash->{json}));
    } else {
        # For direct browser requests, render an HTML page
        $c->stash(
            template => 'proxmox/test_result.tt',
            current_view => 'TT',
            title => "Connection Test Results for $server_id",
            result => $c->stash->{json},
            server_id => $server_id,
        );
        $c->forward('View::TT');
    }
}

__PACKAGE__->meta->make_immutable;

1;