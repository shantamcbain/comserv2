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
        expires        => 86400,
        dbic_class     => 'DBEncy::Session',
        expires_column => 'expires',
        id_column      => 'id',
        data_column    => 'session_data',
        cookie_name => do {
            my $port = $ENV{COMSERV_PORT} || $ENV{CATALYST_PORT} || do {
                my $p = '3001';
                for my $i (0 .. $#ARGV) {
                    if ($ARGV[$i] =~ /^-p(\d+)$/)         { $p = $1; last }
                    elsif ($ARGV[$i] eq '-p' && $ARGV[$i+1] && $ARGV[$i+1] =~ /^\d+$/) { $p = $ARGV[$i+1]; last }
                    elsif ($ARGV[$i] =~ /^--port=(\d+)$/)  { $p = $1; last }
                    elsif ($ARGV[$i] eq '--port' && $ARGV[$i+1] && $ARGV[$i+1] =~ /^\d+$/) { $p = $ARGV[$i+1]; last }
                }
                $p;
            };
            $ENV{COMSERV_SESSION_COOKIE} || "comserv_session_$port";
        },
        cookie_secure => 0,
        cookie_httponly => 1,
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
    my $request_count  = 0;
    my $last_alert_mb  = 0;   # track last alerted RSS level (in MB)
    my $alert_threshold_mb  = 1024;  # first alert at 1 GB
    my $alert_step_mb       = 256;   # re-alert every additional 256 MB
    # Only production1 Docker host (SYSTEM_IDENTIFIER in docker-compose.server.yml)
    my $memory_monitor_enabled = ($ENV{SYSTEM_IDENTIFIER} // '') eq 'production1';

    return sub {
        my $env = shift;

        $self->config->{enable_catalyst_header} = $ENV{CATALYST_HEADER} // 1;
        $self->config->{debug} = $ENV{CATALYST_DEBUG} // 0;

        # Periodic memory monitoring (every 500 requests) — production1 only
        $request_count++;
        if ($memory_monitor_enabled && $request_count % 500 == 0) {
            eval {
                if (-f "/proc/self/status") {
                    open my $fh, '<', "/proc/self/status";
                    while (<$fh>) {
                        if (/^VmRSS:\s+(\d+)\s+kB/) {
                            my $rss_mb = $1 / 1024;
                            # Only alert when we cross a new threshold band
                            my $next_alert = $last_alert_mb
                                ? $last_alert_mb + $alert_step_mb
                                : $alert_threshold_mb;
                            if ($rss_mb >= $next_alert) {
                                $last_alert_mb = int($rss_mb / $alert_step_mb) * $alert_step_mb;
                                Comserv::Util::Logging->instance->log_with_details(
                                    undef, 'ERROR', __FILE__, __LINE__, 'psgi_app_monitor',
                                    sprintf("MEMORY ALERT: Worker %d using %.0f MB RSS (requests: %d).",
                                        $$, $rss_mb, $request_count)
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

# Session store is now properly configured in the plugin list above

# LAYER 3: Global Application Error Handler
# Catches exceptions that escape individual controller error handling
around 'finalize_error' => sub {
    my ($orig, $c) = @_;

    # Handle invalid session ID attacks (e.g. HTML entities injected into cookie)
    # Treat as a security event — clear error, delete bad cookie, redirect to home
    if ($c && $c->error && @{$c->error}) {
        my $err0 = "${\($c->error->[0] // '')}";
        if ($err0 =~ /invalid session ID/i) {
            eval {
                my $logger = Comserv::Util::Logging->instance;
                my %req = Comserv::Util::Logging::extract_request_info($c);
                $logger->log_with_details($c, 'warn', __FILE__, __LINE__, 'finalize_error',
                    "[SECURITY] Invalid session ID rejected from IP:" . ($req{ip_address}//'?')
                    . " UA:" . substr($req{user_agent}//'', 0, 80));
            };
            $c->clear_errors;
            eval {
                my $cookie_name = $c->config->{'Plugin::Session'}{cookie_name}
                    || 'comserv_session_' . ($ENV{COMSERV_PORT} || 4001);
                $c->res->cookies->{$cookie_name} = {
                    value => '', expires => time() - 86400, path => '/'
                };
            };
            $c->res->status(302);
            $c->res->redirect($c->uri_for('/'));
            $c->$orig();
            return;
        }
    }

    # Log all unhandled errors with context
    eval {
        if ($c && $c->error && @{$c->error}) {
            my $error = $c->error->[0];
            my $error_msg = ref $error ? $error->message : "$error";
            my $logger = Comserv::Util::Logging->instance;
            my $session_id = $c->sessionid // 'no-session';
            my $user_id = $c->session->{user_id} // 'no-user';
            my $path = $c->req->path;

            my %req = Comserv::Util::Logging::extract_request_info($c);
            my $ip       = $req{ip_address}    // '-';
            my $req_type = $req{request_type}  // '-';
            my $method   = $req{request_method}// '-';
            my $ua       = substr($req{user_agent} // '-', 0, 120);
            my $referer  = $req{referer}        // '-';

            $logger->log_with_details($c, 'error', __FILE__, __LINE__, 'global_error_handler',
                "[GLOBAL ERROR] Unhandled exception: $error_msg"
                . " (Session: $session_id, User: $user_id, Path: $path,"
                . " IP: $ip, Type: $req_type, Method: $method, Referer: $referer, UA: $ua)");

            $logger->log_access($c, 500);
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
__PACKAGE__->_initialize_session_schema();

# LAYER 2.5: Sanitize session ID from cookie — strip any non-hex characters
# that could be injected (e.g. HTML entities like &#39; from attackers).
# Must be applied AFTER setup() so the session plugin has mixed in get_session_id.
__PACKAGE__->meta->add_around_method_modifier('get_session_id', sub {
    my ($orig, $c, @args) = @_;
    my $id = eval { $c->$orig(@args) };
    return undef if $@ || !defined $id;
    $id =~ s/[^0-9a-fA-F]//g;
    return length($id) >= 20 ? lc($id) : undef;
});

# DISABLED: ConfigDatabaseInit was causing segmentation faults during schema queries
# The config-db initialization is not required for current functionality
# as the application uses db_config.json for database connections instead.
# Comserv::Util::ConfigDatabaseInit->initialize();

# Context helper: delegate to Root controller's check_user_roles
# Allows controllers to call $c->check_user_roles('admin') directly
sub check_user_roles {
    my ($c, @roles) = @_;
    my $root = $c->controller('Root');
    return 0 unless $root;
    return $root->check_user_roles($c, @roles);
}

# Context helper: delegate to Root controller's user_exists
sub user_exists {
    my ($c) = @_;
    my $root = $c->controller('Root');
    return 0 unless $root;
    return $root->user_exists($c);
}

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

sub _initialize_session_schema {
    my $class = shift;
    
    eval {
        use Comserv::Util::Logging;
        my $log = Comserv::Util::Logging->instance;
        
        my $schema = $class->model('DBEncy');
        if ($schema && $schema->storage && $schema->storage->dbh) {
            my $dbh = $schema->storage->dbh;
            my $sth = $dbh->prepare("SHOW TABLES LIKE 'sessions'");
            $sth->execute();
            my $exists = $sth->fetchrow_arrayref();
            
            if (!$exists) {
                $log->log_with_details(undef, 'info', __FILE__, __LINE__, '_initialize_session_schema',
                    "Sessions table 'sessions' not found in ENCY database. Creating it automatically...");
                
                my $sql = q{
                    CREATE TABLE `sessions` (
                        `id` VARCHAR(72) NOT NULL,
                        `session_data` TEXT DEFAULT NULL,
                        `expires` INT(11) DEFAULT NULL,
                        PRIMARY KEY (`id`)
                    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
                };
                
                $dbh->do($sql);
                $log->log_with_details(undef, 'info', __FILE__, __LINE__, '_initialize_session_schema',
                    "Sessions table 'sessions' created successfully.");
            }
        }
    };
    if ($@) {
        warn "Warning: Could not auto-initialize sessions table: $@\n";
    }
    
    return 1;
}

# --- DUAL-BACKUP SELF-HEALING SESSION STORAGE SYSTEM ---
# This custom implementation bypasses the static compile-time load requirements of
# Session::Store::DBIC, preventing startup failures when database is down,
# and automatically falls back to file-based sessions if the DB table is missing or down.

my $last_db_check = 0;
my $is_db_ok = 1;

use Storable qw(freeze thaw);
use MIME::Base64 qw(encode_base64 decode_base64);

sub _serialize_session {
    my ($data) = @_;
    return undef unless defined $data;
    return $data unless ref $data; # If not a reference, return as-is
    
    my $frozen = eval { freeze($data) };
    if ($@ || !defined $frozen) {
        warn "Failed to freeze session data: $@\n";
        return undef;
    }
    return encode_base64($frozen, ''); # '' disables newlines
}

sub _deserialize_session {
    my ($serialized, $key) = @_;
    return undef unless defined $serialized;
    return $serialized if ref $serialized;
    
    if ($serialized =~ /^HASH\(0x[0-9a-fA-F]+\)/) {
        return undef;
    }
    
    my $decoded = eval { decode_base64($serialized) };
    if ($@ || !defined $decoded || $decoded eq '') {
        if (defined $key && $key =~ /^session:/) {
            return undef;
        }
        return $serialized;
    }
    
    my $data = eval { thaw($decoded) };
    if ($@ || !defined $data) {
        if (defined $key && $key =~ /^session:/) {
            return undef;
        }
        return $serialized;
    }
    
    if (defined $key && $key =~ /^session:/ && !ref($data)) {
        return undef;
    }
    
    return $data;
}

sub _is_db_session_operational {
    my ($c) = @_;
    
    # Check at most once every 5 seconds to avoid database check overhead
    my $now = time();
    if ($now - $last_db_check < 5) {
        return $is_db_ok;
    }
    $last_db_check = $now;
    
    eval {
        my $schema = $c->model('DBEncy');
        if ($schema && $schema->storage && $schema->storage->dbh) {
            my $dbh = $schema->storage->dbh;
            # Fast probe query to verify if the sessions table is available and readable
            my $sth = $dbh->prepare("SELECT 1 FROM sessions LIMIT 1");
            $sth->execute();
            $sth->finish();
            $is_db_ok = 1;
        } else {
            $is_db_ok = 0;
        }
    };
    if ($@) {
        $is_db_ok = 0;
    }
    return $is_db_ok;
}

sub _get_file_session_fallback_dir {
    my $dir = $ENV{COMSERV_SESSION_DIR} || $ENV{COMSERV_SESSION_FALLBACK_DIR} || '/tmp/comserv_sessions';
    eval {
        use File::Path qw(make_path);
        make_path($dir) unless -d $dir;
        chmod(0777, $dir); # Ensure all application worker processes can access
    };
    return $dir;
}

sub _get_file_session_data {
    my ($key) = @_;
    my $dir = _get_file_session_fallback_dir() or return undef;
    my $safe_key = $key;
    $safe_key =~ s/[^0-9a-fA-F_]//g;
    return undef unless length($safe_key);
    
    use File::Spec;
    my $file = File::Spec->catfile($dir, $safe_key);
    return undef unless -f $file;
    
    use Storable qw(retrieve);
    my $data = eval { retrieve($file) };
    if ($@) {
        warn "Failed to retrieve fallback session file $file: $@\n";
        return undef;
    }
    
    if (ref $data eq 'HASH' && exists $data->{expires}) {
        if ($data->{expires} < time()) {
            # Session expired, purge it
            eval { unlink($file) };
            return undef;
        }
        return $data->{session_data};
    }
    
    return $data;
}

sub _store_file_session_data {
    my ($key, $data) = @_;
    my $dir = _get_file_session_fallback_dir() or return;
    my $safe_key = $key;
    $safe_key =~ s/[^0-9a-fA-F_]//g;
    return unless length($safe_key);
    
    use File::Spec;
    my $file = File::Spec->catfile($dir, $safe_key);
    my $expires = time() + 86400; # 24 hours default expiry
    
    my $stored_obj = {
        session_data => $data,
        expires => $expires,
    };
    
    use Storable qw(nstore);
    eval { nstore($stored_obj, $file) };
    if ($@) {
        warn "Failed to store fallback session file $file: $@\n";
    }
}

sub _delete_file_session_data {
    my ($key) = @_;
    my $dir = _get_file_session_fallback_dir() or return;
    my $safe_key = $key;
    $safe_key =~ s/[^0-9a-fA-F_]//g;
    return unless length($safe_key);
    
    use File::Spec;
    my $file = File::Spec->catfile($dir, $safe_key);
    if (-f $file) {
        eval { unlink($file) };
    }
}

sub _cleanup_expired_file_sessions {
    my $dir = _get_file_session_fallback_dir() or return;
    eval {
        opendir(my $dh, $dir) or return;
        my $now = time();
        use File::Spec;
        use Storable qw(retrieve);
        while (my $entry = readdir($dh)) {
            next if $entry =~ /^\./;
            my $file = File::Spec->catfile($dir, $entry);
            next unless -f $file;
            
            my $data = eval { retrieve($file) };
            if ($@ || (ref $data eq 'HASH' && exists $data->{expires} && $data->{expires} < $now)) {
                unlink($file);
            }
        }
        closedir($dh);
    };
}

sub get_session_data {
    my ($c, $key) = @_;
    
    if (_is_db_session_operational($c)) {
        my $serialized = eval {
            my $model = $c->model('DBEncy');
            if ($model) {
                my $rs = $model->resultset('Session');
                if ($rs) {
                    my $row = $rs->find($key);
                    if ($row) {
                        if (defined $row->expires && $row->expires < time()) {
                            $row->delete();
                            return undef;
                        }
                        return $row->session_data;
                    }
                }
            }
            return undef;
        };
        if (!$@ && defined $serialized) {
            if ($key =~ /^session:/ && $serialized =~ /^HASH\(0x[0-9a-fA-F]+\)/) {
                eval {
                    my $model = $c->model('DBEncy');
                    my $rs = $model ? $model->resultset('Session') : undef;
                    $rs->find($key)->delete() if $rs;
                };
                return undef;
            }
            my $data = _deserialize_session($serialized, $key);
            if ($key =~ /^session:/ && defined $data && !ref($data)) {
                return undef;
            }
            return $data;
        }
        if ($@) {
            warn "Database session retrieval failed for key '$key': $@. Falling back to file storage.\n";
        }
    }
    
    my $serialized = _get_file_session_data($key);
    if (defined $serialized) {
        if ($key =~ /^session:/ && $serialized =~ /^HASH\(0x[0-9a-fA-F]+\)/) {
            _delete_file_session_data($key);
            return undef;
        }
        my $data = _deserialize_session($serialized, $key);
        if ($key =~ /^session:/ && defined $data && !ref($data)) {
            _delete_file_session_data($key);
            return undef;
        }
        return $data;
    }
    return undef;
}

sub store_session_data {
    my ($c, $key, $data) = @_;
    
    if ($key =~ /^session:/ && !ref($data)) {
        warn "CRITICAL WARNING: Attempted to store non-reference data for session key '$key': '$data'. Ignoring to prevent corruption.\n";
        return;
    }
    
    my $serialized = _serialize_session($data);
    return unless defined $serialized;
    
    if (_is_db_session_operational($c)) {
        my $success = eval {
            my $model = $c->model('DBEncy');
            if ($model) {
                my $rs = $model->resultset('Session');
                if ($rs) {
                    my $expires = time() + ($c->config->{'Plugin::Session'}{expires} || 86400);
                    $rs->update_or_create({
                        id           => $key,
                        session_data => $serialized,
                        expires      => $expires,
                    });
                    eval { _store_file_session_data($key, $serialized) };
                    return 1;
                }
            }
            return 0;
        };
        if ($success) {
            return;
        }
        warn "Database session store failed for key '$key': $@. Falling back to file storage.\n";
    }
    
    _store_file_session_data($key, $serialized);
}

sub delete_session_data {
    my ($c, $key) = @_;
    
    if (_is_db_session_operational($c)) {
        my $success = eval {
            my $model = $c->model('DBEncy');
            if ($model) {
                my $rs = $model->resultset('Session');
                if ($rs) {
                    my $row = $rs->find($key);
                    if ($row) {
                        $row->delete();
                    }
                    eval { _delete_file_session_data($key) };
                    return 1;
                }
            }
            return 0;
        };
        if ($success) {
            return;
        }
        warn "Database session delete failed for key '$key': $@. Falling back to file storage.\n";
    }
    
    _delete_file_session_data($key);
}

sub delete_expired_sessions {
    my ($c) = @_;
    
    if (_is_db_session_operational($c)) {
        eval {
            my $model = $c->model('DBEncy');
            if ($model) {
                my $rs = $model->resultset('Session');
                if ($rs) {
                    $rs->search({ expires => { '<' => time() } })->delete();
                }
            }
        };
    }
    
    _cleanup_expired_file_sessions();
}

