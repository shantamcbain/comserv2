package Comserv::Controller::Setup;
use Moose;
use namespace::autoclean;
use JSON;
use DBI;
use Try::Tiny;
use File::Path qw(make_path);
use Comserv::Util::Logging;
use Comserv::Util::CSRF;

BEGIN { extends 'Catalyst::Controller'; }

has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

# Check if setup is needed and bypass for setup actions
sub auto :Private {
    my ($self, $c) = @_;
    
    Comserv::Util::CSRF::ensure_token($c);
    
    # Skip setup check if we're already in setup or if it's a static asset
    return 1 if $c->action->name eq 'setup';
    return 1 if $c->action->name eq 'setup_form';
    return 1 if $c->action->name eq 'k8s_secrets';
    return 1 if $c->action->name eq 'health';
    return 1 if $c->request->path =~ m{^/static/};
    
    # Check RemoteDB configuration status (NEW: graceful error handling)
    my $remotedb = try { $c->model('RemoteDB') } catch { return undef };
    if ($remotedb && $remotedb->{configuration_status}) {
        if ($remotedb->{configuration_status} =~ /^(MISSING|ERROR|FALLBACK)$/) {
            my $error_msg = $remotedb->{configuration_error} || "Unknown configuration error";
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'auto',
                "Configuration status: " . $remotedb->{configuration_status} . " - $error_msg");

            # In dev mode, redirect to K8s setup wizard; in production, show appropriate response
            if ($c->config->{debug} || $ENV{COMSERV_DEV_MODE}) {
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto',
                    "Dev mode: redirecting to K8s secrets setup page (status: " . $remotedb->{configuration_status} . ")");
                $c->response->redirect($c->uri_for($self->action_for('k8s_secrets')));
                return 0;
            } else {
                # In production, FALLBACK is acceptable (allows db_config.json), but MISSING/ERROR require intervention
                if ($remotedb->{configuration_status} eq 'FALLBACK') {
                    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'auto',
                        "Production mode with FALLBACK config: allowing request but recommend K8s migration");
                    # Continue processing the request (return 1)
                } else {
                    $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'auto',
                        "Production mode: returning 503 - database configuration required");
                    $c->response->status(503);
                    $c->response->body('Service Unavailable: Database configuration required. Contact your administrator.');
                    return 0;
                }
            }
        }
    }
    
    # Check if K8s Secrets were NOT found but config was loaded (likely from db_config.json)
    if ($remotedb) {
        my $k8s_found = $remotedb->{k8s_secrets_found} ? 1 : 0;
        my $has_config = keys %{$remotedb->config} ? 1 : 0;
        
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'auto',
            "RemoteDB status: k8s_secrets_found=$k8s_found, has_config=$has_config, " .
            "config_status=" . ($remotedb->{configuration_status} || 'OK') . ", " .
            "connections=" . scalar(keys %{$remotedb->config}));
        
        if (!$k8s_found && $has_config) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'auto',
                "K8s Secrets NOT found but configuration loaded from db_config.json. " .
                "Consider migrating to K8s Secrets for production security.");
            
            $c->stash(
                k8s_migration_needed => 1,
                k8s_migration_message => 'Database configuration loaded from db_config.json. K8s Secrets not detected. Consider migrating to K8s Secrets for production security.',
                k8s_setup_url => $c->uri_for($self->action_for('k8s_secrets'))
            );
        } elsif ($k8s_found && $has_config) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto',
                "K8s Secrets FOUND - configuration loaded successfully from Kubernetes Secret mounts");
        }
    }
    
    # Check if config is pending (db_config.json doesn't exist or env vars not set)
    my $config_pending = $ENV{COMSERV_CONFIG_PENDING} || !-f $c->path_to('db_config.json');
    
    if ($config_pending && !defined $ENV{COMSERV_DB_HOST}) {
        $c->response->redirect($c->uri_for($self->action_for('setup')));
        return 0;
    }
    
    return 1;
}

# Main setup page
sub setup :Path('/setup') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'setup',
        "Setup page accessed - " . $c->req->method . " request");
    
    if ($c->req->method eq 'POST') {
        unless (Comserv::Util::CSRF::validate_token($c)) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'setup',
                "CSRF validation failed for setup POST");
            $c->stash(error_msg => 'Invalid form submission (CSRF). Please try again.');
            return;
        }
        my $params = $c->req->params;
        
        my $config = {
            db_type => $params->{db_type},
            host => $params->{host},
            port => $params->{port},
            database => $params->{database},
            username => $params->{username},
            password => $params->{password}
        };
        
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'setup',
            "Testing database connection to $config->{host}:$config->{port}/$config->{database}");
        
        # Test connection
        if ($self->test_connection($config)) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'setup',
                "✓ Database connection test PASSED");
            
            # Save configuration
            $self->save_config($c, $config);
            
            # Initialize database
            $self->initialize_database($c, $config);
            
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'setup',
                "Setup completed successfully - redirecting to home");
            
            $c->response->redirect($c->uri_for('/'));
            return;
        } else {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'setup',
                "✗ Database connection test FAILED to $config->{host}:$config->{port}/$config->{database}");
            $c->stash(error_msg => 'Failed to connect to database');
        }
    }
    
    $c->stash(template => 'setup/database.tt');
}

# K8s Secrets configuration setup (Phase 0 - Kubernetes readiness)
sub k8s_secrets :Path('/setup/k8s-secrets') :Args(0) {
    my ($self, $c) = @_;
    
    # Dev-only feature flag
    unless ($c->config->{debug} || $ENV{COMSERV_DEV_MODE}) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'k8s_secrets',
            "Access denied: K8s secrets configuration only available in development mode");
        $c->response->status(403);
        $c->response->body('K8s configuration tool is only available in development mode');
        return;
    }
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'k8s_secrets',
        "K8s secrets setup page accessed - development mode");
    
    my $remotedb = $c->model('RemoteDB');
    my $db_config_path = $c->path_to('db_config.json');
    my $db_config_content = '';
    my $db_config_exists = 0;
    my $databases_parsed = [];
    
    # Load db_config.json content if it exists
    if (-f $db_config_path && -r $db_config_path) {
        $db_config_exists = 1;
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'k8s_secrets',
            "Found db_config.json at: $db_config_path");
        
        local $/;
        eval {
            open my $fh, '<', $db_config_path or die "Cannot read $db_config_path: $!";
            $db_config_content = <$fh>;
            close $fh;
            
            my $config = decode_json($db_config_content);
            foreach my $conn_name (sort keys %$config) {
                next if $conn_name =~ /^_/;
                next unless ref $config->{$conn_name} eq 'HASH';
                push @$databases_parsed, {
                    name => $conn_name,
                    config => $config->{$conn_name}
                };
            }
            
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'k8s_secrets',
                "Parsed db_config.json: found " . scalar(@$databases_parsed) . " database connections");
        };
        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'k8s_secrets',
                "Failed to parse db_config.json: $@");
            $c->stash(error_msg => "Cannot read db_config.json: $@");
        }
    } else {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'k8s_secrets',
            "db_config.json not found at: $db_config_path");
    }
    
    # Handle POST request (create K8s secrets)
    if ($c->req->method eq 'POST') {
        unless (Comserv::Util::CSRF::validate_token($c)) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'k8s_secrets',
                "CSRF validation failed for k8s_secrets POST");
            $c->stash(error_msg => 'Invalid form submission (CSRF). Please try again.');
        } else {
            my $params = $c->req->params;
            my $action = $params->{action} || '';
            
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'k8s_secrets',
                "POST request received with action: $action");
            
            if ($action eq 'create_from_json') {
                eval {
                    my $config = decode_json($db_config_content);
                    $self->_create_k8s_secrets($c, $config);
                    
                    my $test_results = $self->_test_all_connections($c, $config);
                    $c->stash(
                        success_msg => 'K8s secrets created successfully from db_config.json',
                        test_results => $test_results
                    );
                    
                    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'k8s_secrets',
                        "K8s secrets created from db_config.json - testing connections...");
                };
                if ($@) {
                    $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'k8s_secrets',
                        "Failed to create K8s secrets from JSON: $@");
                    $c->stash(error_msg => "Failed to create K8s secrets: $@");
                }
            } elsif ($action eq 'create_from_form') {
                eval {
                    my $config = {
                        'production_server' => {
                            db_type => $params->{db_type} || 'mariadb',
                            host => $params->{host},
                            port => $params->{port} || 3306,
                            username => $params->{username},
                            password => $params->{password},
                            database => $params->{database},
                            description => 'Production Server Configuration',
                            priority => 1
                        }
                    };
                    
                    $self->_create_k8s_secrets($c, $config);
                    
                    my $test_results = $self->_test_all_connections($c, $config);
                    $c->stash(
                        success_msg => 'K8s secrets created successfully from form input',
                        test_results => $test_results
                    );
                    
                    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'k8s_secrets',
                        "K8s secrets created from form input (connection: production_server) - testing connection...");
                };
                if ($@) {
                    $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'k8s_secrets',
                        "Failed to create K8s secrets from form: $@");
                    $c->stash(error_msg => "Failed to create K8s secrets: $@");
                }
            } elsif ($action eq 'create_env_file') {
                eval {
                    $self->_create_env_file($c, $params);
                    $c->stash(success_msg => '.env file created successfully - remember to source it before running the app');
                    
                    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'k8s_secrets',
                        ".env file created at .env.local");
                };
                if ($@) {
                    $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'k8s_secrets',
                        "Failed to create .env file: $@");
                    $c->stash(error_msg => "Failed to create .env file: $@");
                }
            }
        }
    }
    
    $c->stash(
        db_config_exists => $db_config_exists,
        db_config_content => $db_config_content,
        databases_parsed => $databases_parsed,
        template => 'setup/k8s_secrets.tt'
    );
}

# Helper method to create K8s secrets files in both standard locations
sub _create_k8s_secrets {
    my ($self, $c, $config) = @_;
    
    # Try to create secrets in multiple locations (try user-writable first)
    my $home = $ENV{HOME} || '/tmp';
    my @secret_dirs = (
        "$home/.comserv/secrets/dbi",         # User home directory (no sudo needed)
        $c->path_to('secrets/dbi')->stringify, # Project directory
        '/opt/secrets/comserv/dbi',           # Custom K8s mount point (requires sudo)
        '/var/run/secrets/comserv/dbi'        # Standard K8s secret location (requires sudo)
    );
    
    my $created_count = 0;
    my $creation_details = [];
    
    # Try to create in both locations
    foreach my $secrets_dir (@secret_dirs) {
        my $can_create = 1;
        
        eval {
            make_path($secrets_dir) unless -d $secrets_dir;
        };
        
        if ($@) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, '_create_k8s_secrets',
                "Cannot create directory $secrets_dir: $@ - skipping this location");
            push @$creation_details, {
                location => $secrets_dir,
                status => 'FAILED',
                reason => "Cannot create directory: $@"
            };
            $can_create = 0;
        }
        
        next unless $can_create;
        
        # For each database connection, create a secret file
        foreach my $conn_name (keys %$config) {
            next if $conn_name =~ /^_/;  # Skip metadata
            next unless ref $config->{$conn_name} eq 'HASH';
            
            my $secret_file = "$secrets_dir/$conn_name.json";
            my $secret_data = { $conn_name => $config->{$conn_name} };
            
            eval {
                open my $fh, '>', $secret_file or die "Cannot write to $secret_file: $!";
                print $fh encode_json($secret_data);
                close $fh;
                
                chmod 0600, $secret_file;  # Restrict permissions
                
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_create_k8s_secrets',
                    "Created K8s secret file: $secret_file (permissions: 0600)");
                
                push @$creation_details, {
                    location => $secrets_dir,
                    connection => $conn_name,
                    status => 'SUCCESS',
                    file => $secret_file
                };
                
                $created_count++;
            };
            
            if ($@) {
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_create_k8s_secrets',
                    "Failed to create secret file $secret_file: $@");
                push @$creation_details, {
                    location => $secrets_dir,
                    connection => $conn_name,
                    status => 'FAILED',
                    reason => $@
                };
            }
        }
    }
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_create_k8s_secrets',
        "K8s secrets creation completed - created $created_count total files in " . 
        scalar(@secret_dirs) . " locations");
    
    $c->stash(creation_details => $creation_details);
    
    return $created_count > 0 ? 1 : 0;
}

# Helper method to create .env file for Docker
sub _create_env_file {
    my ($self, $c, $params) = @_;
    
    my $env_content = "# Generated by Comserv Setup Wizard\n";
    $env_content .= "# Generated: " . scalar(localtime) . "\n";
    $env_content .= "# NOTE: This file contains database credentials. Keep it secure and never commit to git.\n\n";
    
    my $host = $params->{host};
    my $port = $params->{port} || 3306;
    my $username = $params->{username};
    my $password = $params->{password};
    my $database = $params->{database};
    my $db_type = $params->{db_type} || 'mariadb';
    
    $env_content .= "COMSERV_DB_PRODUCTION_SERVER_HOST=$host\n";
    $env_content .= "COMSERV_DB_PRODUCTION_SERVER_PORT=$port\n";
    $env_content .= "COMSERV_DB_PRODUCTION_SERVER_USERNAME=$username\n";
    $env_content .= "COMSERV_DB_PRODUCTION_SERVER_PASSWORD=$password\n";
    $env_content .= "COMSERV_DB_PRODUCTION_SERVER_DATABASE=$database\n";
    $env_content .= "COMSERV_DB_PRODUCTION_SERVER_DB_TYPE=$db_type\n";
    
    my $env_file = $c->path_to('.env.local');
    
    eval {
        open my $fh, '>', $env_file or die "Cannot write to $env_file: $!";
        print $fh $env_content;
        close $fh;
        
        chmod 0600, $env_file;  # Restrict permissions
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_create_env_file',
            "Created .env file at: $env_file (permissions: 0600)");
    };
    
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_create_env_file',
            "Failed to create .env file: $@");
        die "Cannot create .env file: $@";
    }
    
    return 1;
}

# Test all database connections in config
sub _test_all_connections {
    my ($self, $c, $config) = @_;
    my $results = [];
    
    foreach my $conn_name (sort keys %$config) {
        next if $conn_name =~ /^_/;  # Skip metadata
        next unless ref $config->{$conn_name} eq 'HASH';
        
        my $conn = $config->{$conn_name};
        my $test_result = $self->test_connection($conn);
        
        push @$results, {
            connection => $conn_name,
            status => $test_result ? 'CONNECTED' : 'FAILED',
            host => $conn->{host},
            port => $conn->{port} || 3306,
            database => $conn->{database}
        };
        
        if ($test_result) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_test_all_connections',
                "✓ Connection test PASSED for '$conn_name' at $conn->{host}:$conn->{port}/$conn->{database}");
        } else {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, '_test_all_connections',
                "✗ Connection test FAILED for '$conn_name' at $conn->{host}:$conn->{port}/$conn->{database}");
        }
    }
    
    return $results;
}

# Test database connection
sub test_connection {
    my ($self, $config) = @_;
    
    try {
        my $db_type = $config->{db_type} || 'mariadb';
        my $host = $config->{host};
        my $port = $config->{port} || 3306;
        my $database = $config->{database};
        my $username = $config->{username};
        my $password = $config->{password};
        
        my $dsn = "DBI:$db_type:database=$database;host=$host;port=$port";
        my $dbh = DBI->connect($dsn, $username, $password, 
            { RaiseError => 1, AutoCommit => 1, Timeout => 5 });
        
        if ($dbh) {
            $dbh->disconnect();
            return 1;
        }
        return 0;
    } catch {
        return 0;
    };
}

# Save configuration to db_config.json in full structure format
sub save_config {
    my ($self, $c, $config) = @_;
    
    my $db_config_path = $c->path_to('db_config.json');
    
    # Create full db_config.json structure compatible with RemoteDB.pm
    my $full_config = {
        "_template_info" => {
            "description" => "Database Configuration for Comserv Application",
            "version" => "2.0",
            "created" => scalar(localtime),
            "usage" => "Auto-generated by Setup wizard"
        },
        "production_server" => {
            "db_type" => $config->{db_type} || "mariadb",
            "host" => $config->{host},
            "port" => $config->{port} || 3306,
            "username" => $config->{username},
            "password" => $config->{password},
            "database" => $config->{database},
            "description" => "Production Server Configuration (Primary)",
            "priority" => 1,
            "localhost_override" => 0
        }
    };
    
    # Write config file
    eval {
        open my $fh, '>', $db_config_path or die "Cannot write to $db_config_path: $!";
        print $fh encode_json($full_config);
        close $fh;
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'save_config',
            "Saved db_config.json at: $db_config_path (production_server: $config->{host}:$config->{port}/$config->{database})");
    };
    
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'save_config',
            "Failed to save db_config.json: $@");
        die "Cannot save configuration: $@";
    }
    
    # Update environment variables for this session
    $ENV{COMSERV_DB_HOST} = $config->{host};
    $ENV{COMSERV_DB_PORT} = $config->{port} || 3306;
    $ENV{COMSERV_DB_USER} = $config->{username};
    $ENV{COMSERV_DB_PASS} = $config->{password};
    $ENV{COMSERV_DB_NAME} = $config->{database};
    $ENV{COMSERV_CONFIG_LOADED} = 1;
    delete $ENV{COMSERV_CONFIG_PENDING};
    
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'save_config',
        "Environment variables updated for this session");
}

# Initialize database schema
sub initialize_database {
    my ($self, $c, $config) = @_;
    
    my $schema_manager = $c->model('DBSchemaManager');
    $schema_manager->initialize_schema($config);
}

__PACKAGE__->meta->make_immutable;
1;
