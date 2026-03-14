# perl

package Comserv;
use Moose;
use namespace::autoclean;
use Config::JSON;
use FindBin '$Bin';
use Comserv::Util::Logging;
use Comserv::Util::ConfigDatabaseInit;

# Initialize the logging system
BEGIN {
    Comserv::Util::Logging->init();
}

use Catalyst::Runtime 5.80;
use Catalyst qw/
    ConfigLoader
    Static::Simple
    Session
    Session::State::Cookie
    Session::Store::File
    Authentication
/;

extends 'Catalyst';

our $VERSION = '0.01';

# REMOVED: Custom log setup that was causing segfaults
# The problematic code tried to access $self->dispatchers->[0] which doesn't exist
# during early request handling. Using Plugin::Log::Dispatch config instead.
# This was the root cause of the "Empty reply from server" / segmentation fault issues.

__PACKAGE__->config(
    name => 'Comserv',
    disable_component_resolution_regex_fallback => 1,
    enable_catalyst_header => $ENV{CATALYST_HEADER} // 1,
    encoding => 'UTF-8',
    debug => $ENV{CATALYST_DEBUG} // 0,
    default_view => 'TT',
    'Plugin::Log::Dispatch' => {
        dispatchers => [
            {
                class => 'Log::Dispatch::File',
                min_level => 'debug',
                filename => 'logs/application.log',
                mode => 'append',
                newline => 1,
            },
        ],
    },
    'Plugin::Authentication' => {
        default_realm => 'default',
        realms        => {
            default => {
                credential => {
                    class          => 'Password',
                    password_field => 'password',
                    password_type  => 'hashed',
                },
                store => {
                    class         => 'DBIx::Class',
                    user_model    => 'Schema::Ency',
                    user_class    => 'User',
                },
            },
            members => {
                credential => {
                    class          => 'Password',
                    password_field => 'password',
                    password_type  => 'hashed',
                },
                store => {
                    class         => 'DBIx::Class',
                    user_model    => 'Schema::Ency',
                    user_class    => 'User',
                },
            },
        },
    },
    'Plugin::Session' => {
        expires => 86400,
        cookie_name => 'comserv_session',
        cookie_secure => 0,
        cookie_httponly => 1,
        cookie_expires => '+1d',
    },
    'Plugin::Session::Store::File' => {
        storage => $ENV{COMSERV_SESSION_DIR} || '/tmp/comserv/session',
    },
    'Model::ThemeConfig' => {
        # Theme configuration model
    },
    'Model::Proxmox' => {
        # Proxmox VE API configuration
        proxmox_host => '172.30.236.89',
        api_url_base => 'https://172.30.236.89:8006/api2/json',
        node => 'pve',  # Default Proxmox node name
        image_url_base => 'http://172.30.167.222/kvm-images',  # URL for VM templates
        username => 'root',  # Proxmox username
        password => 'password',  # Proxmox password - CHANGE THIS TO YOUR ACTUAL PASSWORD
        realm => 'pam',  # Proxmox authentication realm
    },
    'Model::NPM' => {
        # NPM configuration is loaded dynamically from environment-specific config files
        # See Comserv::Controller::NPM for implementation details
    },
);

sub psgi_app {
    my $self = shift;

    my $app = $self->SUPER::psgi_app(@_);
    my $request_count = 0;

    return sub {
        my $env = shift;

        $self->config->{enable_catalyst_header} = $ENV{CATALYST_HEADER} // 1;
        $self->config->{debug} = $ENV{CATALYST_DEBUG} // 0;

        # Periodic memory monitoring (every 100 requests)
        $request_count++;
        if ($request_count % 100 == 0) {
            eval {
                if (-f "/proc/self/status") {
                    open my $fh, '<', "/proc/self/status";
                    while (<$fh>) {
                        if (/^VmRSS:\s+(\d+)\s+kB/) {
                            my $rss_kb = $1;
                            # If RSS > 512MB, log an ERROR to notify admins
                            if ($rss_kb > 512 * 1024) {
                                my $rss_mb = sprintf("%.2f", $rss_kb / 1024);
                                Comserv::Util::Logging->instance->log_with_details(
                                    undef, 'ERROR', __FILE__, __LINE__, 'psgi_app_monitor',
                                    "CRITICAL MEMORY ALERT: Worker process $$ using $rss_mb MB RSS. " .
                                    "Requests handled: $request_count. Starman will soon recycle this worker."
                                );
                            }
                            last;
                        }
                    }
                    close $fh;
                }
            };
        }

        return $app->($env);
    };
}

# Auto-fix for missing modules - attempt to load modules with fallbacks
# This ensures the application works even if modules are missing

# First, try to load email modules
my $email_modules_loaded = 0;
# Temporarily disabled email modules to fix startup issues
# eval {
#     require Comserv::View::Email;
#     require Comserv::View::Email::Template;
# };
# if ($@) {
warn "Warning: Email modules disabled for testing\n";
warn "Email functionality may not work correctly.\n";
# $email_modules_loaded = 0;

# Try to auto-install the modules if we're in development mode
# if ($ENV{CATALYST_DEBUG}) {
#     warn "Attempting to auto-install email modules...\n";
#     eval {
#         require App::cpanminus;
#         my $local_lib = __PACKAGE__->path_to('local');
#         system("cpanm --local-lib=$local_lib --notest Catalyst::View::Email Catalyst::View::Email::Template");
#         
#         # Try loading again after installation
#         require Comserv::View::Email;
#         require Comserv::View::Email::Template;
#         $email_modules_loaded = 1;
#     };
#     if ($@) {
#         warn "Auto-installation failed: $@\n";
#         warn "Email functionality will be limited.\n";
#     }
# }
# }

# Session store is now properly configured in the plugin list above

# LAYER 3: Global Application Error Handler
# Catches exceptions that escape individual controller error handling
around 'finalize_error' => sub {
    my ($orig, $c) = @_;

    # Log all unhandled errors with context
    eval {
        if ($c && $c->error && @{$c->error}) {
            my $error = $c->error->[0];
            my $error_msg = ref $error ? $error->message : "$error";
            my $logger = Comserv::Util::Logging->instance;
            my $session_id = $c->sessionid // 'no-session';
            my $user_id = $c->session->{user_id} // 'no-user';
            my $path = $c->req->path;
            
            $logger->log_with_details($c, 'error', __FILE__, __LINE__, 'global_error_handler',
                "[GLOBAL ERROR] Unhandled exception: $error_msg (Session: $session_id, User: $user_id, Path: $path)");
        }
    };

    # If error.tt hasn't been rendered yet, render it now
    eval {
        if ($c && !$c->response->body) {
            $c->response->status(500) unless $c->response->status;

            $c->stash->{error_title} ||= 'Application Error';
            $c->stash->{error_msg}   ||= 'An unexpected error occurred.';
            $c->stash->{technical_details} ||= join(', ', @{$c->error // []});
            $c->stash->{template} = 'error.tt';

            eval {
                my $view = $c->view('TT');
                $view->process($c);
            };

            if ($@) {
                $c->response->content_type('text/plain; charset=utf-8');
                $c->response->body("Internal Server Error\n\nAn error occurred and we were unable to render the error page.\nPlease contact the system administrator.");
            }
        }
    };

    # Call the original finalize_error to complete response processing
    $c->$orig();
};

__PACKAGE__->_initialize_database_config();
__PACKAGE__->setup();
__PACKAGE__->_initialize_ai_chat_schema();

# DISABLED: ConfigDatabaseInit was causing segmentation faults during schema queries
# The config-db initialization is not required for current functionality
# as the application uses db_config.json for database connections instead.
# Comserv::Util::ConfigDatabaseInit->initialize();

1;

=head1 INTERNAL METHODS

=head2 _initialize_database_config

Initializes database configuration from db_config.json at application startup.
This ensures environment variables are populated before models are loaded.

If db_config.json exists, it reads the primary production connection and exports
to environment variables (COMSERV_DB_HOST, COMSERV_DB_PORT, COMSERV_DB_USER, COMSERV_DB_PASS).

If db_config.json doesn't exist, it creates a template and sets a flag so the
application can show setup instructions on first request.

This is called automatically during application startup (before setup()).

=cut

sub _initialize_database_config {
    my $class = shift;
    
    use JSON;
    use File::Spec;
    use FindBin '$Bin';
    
    # Skip if env vars already set (allows manual override)
    return if $ENV{COMSERV_DB_HOST} && $ENV{COMSERV_DB_USER};
    
    # Find db_config.json in application root
    my @search_paths = (
        File::Spec->catfile($Bin, '..', 'db_config.json'),
        File::Spec->catfile($Bin, '..', '..', 'db_config.json'),
        'db_config.json',
        '/opt/comserv/db_config.json',
        $ENV{COMSERV_DB_CONFIG} ? $ENV{COMSERV_DB_CONFIG} : (),
    );
    
    my $config_file;
    foreach my $path (@search_paths) {
        if (-f $path) {
            $config_file = $path;
            last;
        }
    }
    
    if ($config_file && -r $config_file) {
        # File exists - load primary production connection
        eval {
            open my $fh, '<', $config_file or die "Cannot open $config_file: $!";
            my $json_text = do { local $/; <$fh> };
            close $fh;
            
            my $config = decode_json($json_text);
            
            # Use production_server as default (priority 1)
            if ($config->{production_server}) {
                my $prod = $config->{production_server};
                $ENV{COMSERV_DB_HOST} ||= $prod->{host};
                $ENV{COMSERV_DB_PORT} ||= $prod->{port} || 3306;
                $ENV{COMSERV_DB_USER} ||= $prod->{username};
                $ENV{COMSERV_DB_PASS} ||= $prod->{password};
                $ENV{COMSERV_DB_NAME} ||= $prod->{database};
            }
            
            # Mark that config was loaded successfully
            $ENV{COMSERV_CONFIG_LOADED} = 1;
        };
        
        if ($@) {
            warn "Warning: Error reading db_config.json: $@\n";
            warn "Application will attempt to use environment variables or fallback to SQLite\n";
        }
    } else {
        # File doesn't exist - application will show setup wizard on first request
        warn "Info: db_config.json not found.\n";
        warn "The application will redirect to /setup page on first request to configure database connection.\n";
        warn "Alternatively, set environment variables: COMSERV_DB_HOST, COMSERV_DB_USER, COMSERV_DB_PASS, etc.\n";
        $ENV{COMSERV_CONFIG_PENDING} = 1;
    }
    
    return 1;
}

sub _initialize_ai_chat_schema {
    my $class = shift;
    
    eval {
        use Comserv::Util::Logging;
        my $log = Comserv::Util::Logging->instance;
        
        $log->log_with_details(undef, 'info', __FILE__, __LINE__, '_initialize_ai_chat_schema',
            'Checking AI Chat schema tables...');
        
        my @ai_chat_tables = (
            'documentation_metadata_index',
            'code_search_index',
            'web_search_results',
            'ai_model_config',
            'documentation_role_access'
        );
        
        foreach my $table (@ai_chat_tables) {
            eval {
                my $schema = $class->model('DBEncy');
                if ($schema && $schema->storage && $schema->storage->dbh) {
                    my $dbh = $schema->storage->dbh;
                    my $sth = $dbh->prepare("SHOW TABLES LIKE ?");
                    $sth->execute($table);
                    my $exists = $sth->fetchrow_arrayref();
                    
                    if (!$exists) {
                        $log->log_with_details(undef, 'warn', __FILE__, __LINE__, '_initialize_ai_chat_schema',
                            "Table '$table' not found in ENCY database. Will be created on first admin request.");
                    }
                }
            };
            if ($@) {
                $log->log_with_details(undef, 'warn', __FILE__, __LINE__, '_initialize_ai_chat_schema',
                    "Could not check table '$table': $@");
            }
        }
        
        $log->log_with_details(undef, 'info', __FILE__, __LINE__, '_initialize_ai_chat_schema',
            'AI Chat schema check complete.');
    };
    
    if ($@) {
        warn "Warning during AI Chat schema initialization: $@\n";
    }
    
    return 1;
}