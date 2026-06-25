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
    Session::Store::Dummy
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
    # Allow Shanta code editor from any browser (tablet/VPN) when server is the dev workstation
    remote_code_editor => ($ENV{SYSTEM_IDENTIFIER} || '') =~ /workstation/i ? 1 : 0,
    # SSH tunnel target for tablet → workstation (see script/aew_ssh_tunnel.sh)
    aew_ssh_host     => $ENV{AEW_SSH_HOST}     || '172.30.131.126',
    aew_browser_host => $ENV{AEW_BROWSER_HOST} || 'workstation.local',
    aew_zerotier_host => $ENV{AEW_ZEROTIER_HOST} || '172.30.131.126',
    aew_ssh_user     => $ENV{AEW_SSH_USER}     || 'shanta',
    aew_ssh_port     => $ENV{AEW_SSH_PORT}     || 22,
    aew_app_port     => $ENV{AEW_APP_PORT}     || 3001,
    aew_ssh_config_host => $ENV{AEW_SSH_CONFIG_HOST} || 'comserv-aew',
    # Dev preview: production proxies to workstation for site-admin / helpdesk workflows
    dev_preview_backend       => $ENV{DEV_PREVIEW_BACKEND}       || 'http://192.168.1.199:3001',
    dev_preview_backend_zt    => $ENV{DEV_PREVIEW_BACKEND_ZT}    || 'http://172.30.131.126:3001',
    dev_preview_backend_host  => $ENV{DEV_PREVIEW_BACKEND_HOST}  || 'dev.computersystemconsulting.ca',
    dev_preview_secret        => $ENV{DEV_PREVIEW_SECRET}        || '',
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
    'Model::AI' => {
        # Central AI facade. All heavy logic lives in Comserv::Model::AI::*
        # Providers, chat routing, conversations, usage, etc. are delegated here.
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
        
        # Names must match DBIx::Class Result ->table() values, not documentation labels.
        my @ai_chat_tables = (
            'documentationmetadataindex',
            'codesearchindex',
            'websearchresult',
            'ai_model_config',
            'documentationroleaccess',
            'ai_usage_logs',
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
    
    # Ensure AI usage logging table for customer billing + capacity monitoring
    eval { $class->_ensure_ai_usage_log_table(); };
    if ($@) {
        warn "Warning: Could not ensure ai_usage_logs table: $@\n";
    }

    eval { $class->_ensure_ai_navigation_shortcuts_table(); };
    eval { $class->_ensure_nav_submenu_table(); };
    if ($@) {
        warn "Warning: Could not ensure ai_navigation_shortcuts table: $@\n";
    }

    return 1;
}

=head2 _ensure_ai_usage_log_table

Creates the ai_usage_logs table (if missing) used for per-customer AI usage tracking,
provider breakdown, token counts, and cost estimates for billing and system load anticipation.
=cut

sub _ensure_ai_usage_log_table {
    my $class = shift;
    
    eval {
        use Comserv::Util::Logging;
        my $log = Comserv::Util::Logging->instance;
        
        my $schema = $class->model('DBEncy');
        return unless $schema && $schema->storage && $schema->storage->dbh;
        
        my $dbh = $schema->storage->dbh;
        my $sth = $dbh->prepare("SHOW TABLES LIKE 'ai_usage_logs'");
        $sth->execute();
        my $exists = $sth->fetchrow_arrayref();
        
        if (!$exists) {
            $log->log_with_details(undef, 'info', __FILE__, __LINE__, '_ensure_ai_usage_log_table',
                "Creating ai_usage_logs table for AI billing/monitoring...");
            
            my $sql = q{
                CREATE TABLE `ai_usage_logs` (
                    `id` INT(11) NOT NULL AUTO_INCREMENT,
                    `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                    `user_id` INT(11) DEFAULT NULL,
                    `site_id` INT(11) DEFAULT NULL,
                    `guest_session_id` VARCHAR(64) DEFAULT NULL,
                    `provider` VARCHAR(50) NOT NULL DEFAULT 'ollama',
                    `model` VARCHAR(100) NOT NULL DEFAULT 'unknown',
                    `prompt_tokens` INT(11) DEFAULT 0,
                    `completion_tokens` INT(11) DEFAULT 0,
                    `total_tokens` INT(11) DEFAULT 0,
                    `estimated_cost_usd` DECIMAL(10,6) DEFAULT 0.000000,
                    `currency` VARCHAR(10) DEFAULT 'USD',
                    `duration_ms` INT(11) DEFAULT NULL,
                    `request_type` VARCHAR(50) DEFAULT 'chat',
                    `conversation_id` INT(11) DEFAULT NULL,
                    `status` VARCHAR(20) NOT NULL DEFAULT 'success',
                    `error_message` TEXT DEFAULT NULL,
                    `ip_address` VARCHAR(45) DEFAULT NULL,
                    `ollama_host` VARCHAR(128) DEFAULT NULL,
                    `metadata` JSON DEFAULT NULL,
                    `plan_id` INT(11) DEFAULT NULL,
                    `plan_ai_requests_per_day` INT(11) DEFAULT NULL,
                    `within_free_quota` TINYINT(1) DEFAULT 1,
                    `billing_status` VARCHAR(20) DEFAULT NULL,
                    PRIMARY KEY (`id`),
                    KEY `idx_created` (`created_at`),
                    KEY `idx_user` (`user_id`),
                    KEY `idx_site` (`site_id`),
                    KEY `idx_provider_model` (`provider`, `model`),
                    KEY `idx_status` (`status`),
                    KEY `idx_conversation` (`conversation_id`)
                ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
            };
            
            $dbh->do($sql);
            $log->log_with_details(undef, 'info', __FILE__, __LINE__, '_ensure_ai_usage_log_table',
                "ai_usage_logs table created successfully.");
            return 1;
        }
        
        # Table exists — ensure new columns for quota/billing tracking are present (for upgrades)
        my @new_columns = (
            { name => 'plan_id',                  type => 'INT(11) DEFAULT NULL' },
            { name => 'plan_ai_requests_per_day', type => 'INT(11) DEFAULT NULL' },
            { name => 'within_free_quota',        type => 'TINYINT(1) DEFAULT 1' },
            { name => 'billing_status',           type => 'VARCHAR(20) DEFAULT NULL' },
        );
        
        foreach my $col (@new_columns) {
            my $col_sth = $dbh->prepare("SHOW COLUMNS FROM `ai_usage_logs` LIKE ?");
            $col_sth->execute($col->{name});
            my $col_exists = $col_sth->fetchrow_arrayref();
            
            unless ($col_exists) {
                my $alter = "ALTER TABLE `ai_usage_logs` ADD COLUMN `$col->{name}` $col->{type}";
                eval { $dbh->do($alter); };
                if ($@) {
                    $log->log_with_details(undef, 'warn', __FILE__, __LINE__, '_ensure_ai_usage_log_table',
                        "Could not add column $col->{name}: $@");
                } else {
                    $log->log_with_details(undef, 'info', __FILE__, __LINE__, '_ensure_ai_usage_log_table',
                        "Added missing column $col->{name} to ai_usage_logs");
                }
            }
        }
    };
    if ($@) {
        warn "Failed to ensure ai_usage_logs schema: $@\n";
    }
    return 1;
}

=head2 _ensure_ai_navigation_shortcuts_table

Creates ai_navigation_shortcuts (if missing) for DB-driven AI navigation and trigger phrases.
=cut

sub _ensure_ai_navigation_shortcuts_table {
    my $class = shift;

    eval {
        use Comserv::Util::Logging;
        my $log = Comserv::Util::Logging->instance;

        my $schema = $class->model('DBEncy');
        return unless $schema && $schema->storage && $schema->storage->dbh;

        my $dbh = $schema->storage->dbh;
        my $sth = $dbh->prepare("SHOW TABLES LIKE 'ai_navigation_shortcuts'");
        $sth->execute();
        my $exists = $sth->fetchrow_arrayref();

        if (!$exists) {
            $log->log_with_details(undef, 'info', __FILE__, __LINE__, '_ensure_ai_navigation_shortcuts_table',
                "Creating ai_navigation_shortcuts table...");

            my $sql = q{
                CREATE TABLE `ai_navigation_shortcuts` (
                    `id` INT(11) NOT NULL AUTO_INCREMENT,
                    `label` VARCHAR(100) NOT NULL,
                    `url` VARCHAR(512) NOT NULL,
                    `trigger_phrases` TEXT DEFAULT NULL,
                    `category` VARCHAR(50) DEFAULT NULL,
                    `sitename` VARCHAR(50) NOT NULL DEFAULT 'All',
                    `is_private` TINYINT(1) NOT NULL DEFAULT 0,
                    `owner_username` VARCHAR(100) DEFAULT NULL,
                    `min_role` VARCHAR(20) NOT NULL DEFAULT 'user',
                    `link_order` INT(11) DEFAULT 0,
                    `status` TINYINT(1) NOT NULL DEFAULT 1,
                    `source` VARCHAR(30) DEFAULT 'manual',
                    `created_at` DATETIME DEFAULT CURRENT_TIMESTAMP,
                    `updated_at` DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
                    PRIMARY KEY (`id`),
                    KEY `idx_ai_nav_shortcut_site` (`sitename`),
                    KEY `idx_ai_nav_shortcut_owner` (`owner_username`),
                    KEY `idx_ai_nav_shortcut_private` (`is_private`),
                    KEY `idx_ai_nav_shortcut_status` (`status`)
                ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
            };

            $dbh->do($sql);
            $log->log_with_details(undef, 'info', __FILE__, __LINE__, '_ensure_ai_navigation_shortcuts_table',
                "ai_navigation_shortcuts table created successfully.");
        }

        $class->_seed_newsletter_ai_shortcuts($dbh);
        $class->_seed_dev_preview_nav_links($dbh);
    };
    if ($@) {
        warn "Failed to ensure ai_navigation_shortcuts schema: $@\n";
    }
    return 1;
}

sub _seed_newsletter_ai_shortcuts {
    my ($class, $dbh) = @_;
    return unless $dbh;

    my @shortcuts = (
        {
            label => 'Newsletters',
            url   => '/newsletters',
            trigger_phrases => encode_json([
                'newsletter', 'newsletters', 'read newsletter', 'newsletter archive',
                'show newsletters', 'latest newsletter',
            ]),
            category  => 'Member_links',
            sitename  => 'All',
            min_role  => 'guest',
            link_order => 5,
        },
        {
            label => 'Subscribe to Newsletter',
            url   => '/mail/subscribe',
            trigger_phrases => encode_json([
                'subscribe newsletter', 'join mailing list', 'email subscribe',
                'newsletter signup',
            ]),
            category  => 'Member_links',
            sitename  => 'All',
            min_role  => 'guest',
            link_order => 6,
        },
        {
            label => 'Manage Newsletters',
            url   => '/mail/newsletters',
            trigger_phrases => encode_json([
                'manage newsletters', 'create newsletter', 'send newsletter',
                'newsletter admin', 'write newsletter',
            ]),
            category  => 'Main_links',
            sitename  => 'All',
            min_role  => 'admin',
            link_order => 20,
        },
        {
            label => 'Create Newsletter',
            url   => '/mail/newsletter/create',
            trigger_phrases => encode_json([
                'new newsletter', 'draft newsletter', 'compose newsletter',
            ]),
            category  => 'Main_links',
            sitename  => 'All',
            min_role  => 'admin',
            link_order => 21,
        },
        {
            label => 'SSH Terminal',
            url   => '/admin/ssh_terminal',
            trigger_phrases => encode_json([
                'terminal', 'ssh terminal', 'system terminal', 'shell',
                'open terminal', 'command line', 'system shell',
            ]),
            category  => 'Admin_links',
            sitename  => 'All',
            min_role  => 'admin',
            link_order => 10,
        },
        {
            label => 'Preview Upcoming Changes',
            url   => '/admin/dev-preview',
            trigger_phrases => encode_json([
                'dev preview', 'preview upcoming changes', 'preview changes',
                'upcoming changes', 'preview site', 'preview dev',
                'see dev changes', 'workstation preview',
            ]),
            category  => 'HelpDesk_links',
            sitename  => 'All',
            min_role  => 'admin',
            link_order => 15,
        },
    );

    require JSON;
    for my $sc (@shortcuts) {
        eval {
            my $check = $dbh->prepare(
                'SELECT id FROM ai_navigation_shortcuts WHERE url = ? AND sitename = ? LIMIT 1'
            );
            $check->execute($sc->{url}, $sc->{sitename});
            unless ($check->fetchrow_arrayref) {
                $dbh->do(
                    'INSERT INTO ai_navigation_shortcuts '
                    . '(label, url, trigger_phrases, category, sitename, min_role, link_order, status, source) '
                    . 'VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?)',
                    undef,
                    $sc->{label}, $sc->{url}, $sc->{trigger_phrases},
                    $sc->{category}, $sc->{sitename}, $sc->{min_role},
                    $sc->{link_order}, 'seed_newsletter',
                );
            }
        };
    }
}

sub _seed_dev_preview_nav_links {
    my ($class, $dbh) = @_;
    return unless $dbh;

    my @links = (
        {
            category    => 'HelpDesk_links',
            sitename    => 'All',
            name        => 'Preview Upcoming Changes',
            url         => '/admin/dev-preview',
            target      => '_self',
            description => 'admin_only',
            submenu     => 'resources',
            link_order  => 8,
        },
        {
            category    => 'Admin_links',
            sitename    => 'All',
            name        => 'Preview Upcoming Changes',
            url         => '/admin/dev-preview',
            target      => '_self',
            description => 'admin_only',
            submenu     => 'admin_links',
            link_order  => 8,
        },
    );

    for my $link (@links) {
        eval {
            my $check = $dbh->prepare(
                'SELECT id FROM internal_links_tb '
                . 'WHERE category = ? AND url = ? AND sitename = ? LIMIT 1'
            );
            $check->execute( $link->{category}, $link->{url}, $link->{sitename} );
            next if $check->fetchrow_arrayref;

            $dbh->do(
                'INSERT INTO internal_links_tb '
                . '(category, sitename, name, url, target, description, submenu, link_order, status) '
                . 'VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1)',
                undef,
                $link->{category}, $link->{sitename}, $link->{name}, $link->{url},
                $link->{target}, $link->{description}, $link->{submenu},
                $link->{link_order},
            );
        };
    }

    eval {
        $dbh->do(
            'UPDATE internal_links_tb SET submenu = ? '
            . 'WHERE category = ? AND url = ? '
            . "AND (submenu IS NULL OR submenu = '' OR submenu = 'cms_pages')",
            undef,
            'admin_links', 'Admin_links', '/admin/dev-preview',
        );
    };
}

sub _ensure_nav_submenu_table {
    my $class = shift;
    eval {
        my $schema = $class->model('DBEncy');
        return unless $schema && $schema->storage && $schema->storage->dbh;
        my $dbh = $schema->storage->dbh;
        my $sth = $dbh->prepare("SHOW TABLES LIKE 'nav_submenu_tb'");
        $sth->execute();
        unless ( $sth->fetchrow_arrayref ) {
            $dbh->do(q{
                CREATE TABLE nav_submenu_tb (
                    id INT NOT NULL AUTO_INCREMENT,
                    category VARCHAR(50) NOT NULL,
                    sitename VARCHAR(50) NOT NULL DEFAULT 'All',
                    submenu_id VARCHAR(64) NOT NULL,
                    label VARCHAR(120) NOT NULL,
                    icon VARCHAR(64) DEFAULT '',
                    header_url VARCHAR(255) DEFAULT '',
                    section_order INT NOT NULL DEFAULT 0,
                    is_system TINYINT(1) NOT NULL DEFAULT 0,
                    template_slot VARCHAR(64) DEFAULT '',
                    status TINYINT(1) NOT NULL DEFAULT 1,
                    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
                    PRIMARY KEY (id),
                    UNIQUE KEY uq_nav_submenu_scope (category, sitename, submenu_id),
                    KEY idx_nav_submenu_category (category),
                    KEY idx_nav_submenu_sitename (sitename),
                    KEY idx_nav_submenu_status (status)
                ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
            });
        }
        require Comserv::Controller::Navigation;
        my $nav = Comserv::Controller::Navigation->new;
        $nav->seed_nav_submenu_catalog_dbh($dbh);
    };
    if ($@) {
        warn "Failed to ensure nav_submenu_tb: $@\n";
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

