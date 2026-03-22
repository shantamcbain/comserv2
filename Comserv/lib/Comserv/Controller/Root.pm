package Comserv::Controller::Root;
use Moose;
use namespace::autoclean;
use Template;
use Data::Dumper;
use DateTime;
use JSON;
use URI;
use Time::HiRes qw(gettimeofday);
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

# Cache the RemoteDB config status so we don't hit the filesystem on every request.
# Refreshes every 5 minutes. Each Starman worker has its own copy (that's fine).
my $_remotedb_status       = undef;   # 'ok', 'missing', 'error', 'fallback'
my $_remotedb_last_checked = 0;
my $_REMOTEDB_TTL          = 300;     # seconds between re-checks


# Add user_exists method
sub user_exists {
    my ($self, $c) = @_;
    return ($c->session->{username} && $c->session->{user_id}) ? 1 : 0;
}

# Add check_user_roles method
sub check_user_roles {
    my ($self, $c, $role) = @_;

    return 0 unless $self->user_exists($c);

    my $roles       = $c->session->{roles};
    my $user_groups = $c->session->{user_groups};

    if ($role eq 'admin') {
        return 1 if $c->session->{is_admin};

        if (ref($roles) eq 'ARRAY') {
            return 1 if grep { lc($_) eq 'admin' } @$roles;
        } elsif (defined $roles && !ref($roles)) {
            return 1 if $roles =~ /\badmin\b/i;
        }

        if (ref($user_groups) eq 'ARRAY') {
            return 1 if grep { lc($_) eq 'admin' } @$user_groups;
        } elsif (defined $user_groups && !ref($user_groups)) {
            return 1 if $user_groups =~ /\badmin\b/i;
        }

        return 0;
    }

    if (ref($roles) eq 'ARRAY') {
        return 1 if grep { lc($_) eq lc($role) } @$roles;
    } elsif (defined $roles && !ref($roles)) {
        return 1 if $roles =~ /\b\Q$role\E\b/i;
    }

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

sub get_server_ip :Private {
    my ($self, $c) = @_;
    
    # Check if running in Docker container
    if (-f '/.dockerenv' || -f '/run/.containerenv') {
        # Get container's IP address
        my $ip = `hostname -i | awk '{print \$1}'`;
        chomp($ip);
        return $ip || 'unknown';
    }
    
    # Fallback to host IP for non-containerized environments
    my $ip = `ip route get 1.1.1.1 | awk '{print \$7; exit}'`;
    chomp($ip);
    
    return $ip || 'unknown';
}

# Auto method to set up common stash variables for all requests
sub auto :Private {
    my ($self, $c) = @_;

    # Skip everything for health checks and monitoring endpoints immediately
    # This prevents creating session files for Docker health checks
    if ($c->req->path =~ m{^/health(?:/|$)}) {
        return 1;
    }
    # LAYER 1: Auto Method Protection - wrap entire method in error handling
    eval {
        # Skip setup redirect for setup pages themselves and static assets
        # Note: $c->req->path returns path WITHOUT leading slash (e.g., "setup/k8s-secrets")
        unless ($c->req->path =~ m{^/?setup(?:/|$)} || $c->req->path =~ m{^/?static/}) {
            # Check RemoteDB configuration status — cached per worker to avoid hitting
            # the filesystem (K8s secrets, db_config.json) on every single request.
            my $now = time();
            if (!defined $_remotedb_status || ($now - $_remotedb_last_checked) > $_REMOTEDB_TTL) {
                eval {
                    my $remotedb_class = $c->model('RemoteDB');
                    my $remotedb;
                    if (!ref($remotedb_class)) {
                        require Comserv::Model::RemoteDB;
                        $remotedb = Comserv::Model::RemoteDB->new();
                        $remotedb->_load_config();
                    } else {
                        $remotedb = $remotedb_class;
                    }
                    $_remotedb_status = ($remotedb && ref($remotedb))
                        ? ($remotedb->{configuration_status} // 'ok')
                        : 'ok';
                };
                if ($@) {
                    $_remotedb_status = 'ok';
                    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'auto',
                        "Error checking RemoteDB configuration status: $@");
                }
                $_remotedb_last_checked = $now;
            }

            if ($_remotedb_status =~ /^(MISSING|ERROR)$/) {
                if ($c->config->{debug} || $ENV{COMSERV_DEV_MODE}) {
                    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto',
                        "Dev mode: redirecting to K8s secrets setup (status: $_remotedb_status)");
                    $c->response->redirect($c->uri_for('/setup/k8s-secrets'));
                    $c->detach();
                    return 0;
                } else {
                    $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'auto',
                        "Production mode: returning 503 - database configuration required (status: $_remotedb_status)");
                    $c->response->status(503);
                    $c->response->body('Service Unavailable: Database configuration required. Contact administrator.');
                    $c->detach();
                    return 0;
                }
            }
        }

        # CRITICAL: Capture debug parameter from URL query string
        # URL format: http://host/path?debug=1 activates debug mode
        #             http://host/path?debug=0 deactivates debug mode
        my $debug_param = $c->req->params->{debug};
        if (defined $debug_param) {
            if ($debug_param eq '1') {
                $c->session->{debug_mode} = 1;
                $c->stash->{debug} = 1;
            } elsif ($debug_param eq '0') {
                $c->session->{debug_mode} = 0;
                $c->stash->{debug} = 0;
            }
        } else {
            # Ensure debug mode matches session or defaults to off
            $c->session->{debug_mode} = 0 unless defined $c->session->{debug_mode};
            $c->stash->{debug} = $c->session->{debug_mode};
        }
        
        # Set up site name with timeout protection
        eval {
            local $SIG{ALRM} = sub { die "Site name fetch timeout\n"; };
            alarm(3);  # 3 second timeout for site name fetch
            $self->fetch_and_set($c, 'SiteName');
            alarm(0);
        };
        alarm(0);  # Make sure alarm is cancelled
        if ($@) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'auto',
                "Site name fetch timed out or failed: $@. Using default site name.");
            $c->stash->{SiteName} = 'default';
        }
        
        # Set up theme using canonical ThemeConfig model with timeout protection
        my $SiteName = $c->stash->{SiteName} || $c->session->{SiteName} || 'default';
        eval {
            local $SIG{ALRM} = sub { die "Theme fetch timeout\n"; };
            alarm(3);  # 3 second timeout for theme fetch
            my $theme_name = $c->model('ThemeConfig')->get_site_theme($c, $SiteName);
            $c->stash->{theme_name} = $theme_name;
            my $site_favicon = $c->model('ThemeConfig')->get_site_favicon($c, $SiteName);
            $c->stash->{site_favicon} = $site_favicon if $site_favicon;
            alarm(0);
        };
        alarm(0);  # Make sure alarm is cancelled
        if ($@) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'auto',
                "Theme fetch timed out or failed: $@. Using default theme.");
            $c->stash->{theme_name} = 'default';
        }
        
        # Set up user information for templates
        # Check both Catalyst auth system and session-based auth
        my $user_logged_in = 0;
        my $username = '';
        my $user_id = '';
        my $user_roles = [];
        my $is_admin = 0;
        
        if ($self->user_exists($c)) {
            # Session-based authentication — never call $c->user to avoid DB lookup clearing session
            $user_logged_in = 1;
            $username   = $c->session->{username};
            $user_id    = $c->session->{user_id};
            $user_roles = $c->session->{roles} || [];
            # Normalise roles to always be an array ref
            if (!ref $user_roles) {
                $user_roles = [ map { s/^\s+|\s+$//gr } split /,/, $user_roles ];
                $c->session->{roles} = $user_roles;
            }
        }
        
        # Check admin status
        if ($user_logged_in) {
            $is_admin = $self->check_user_roles($c, 'admin');

            # If not admin from global roles, check UserSiteRole for the current site.
            # This allows site-specific admins to get admin privileges without re-login.
            if (!$is_admin && $user_id) {
                eval {
                    my $site_name_check = $c->stash->{SiteName} || $c->session->{SiteName} || '';
                    if ($site_name_check && lc($site_name_check) ne 'csc') {
                        my $site_obj = $c->model('DBEncy')->resultset('Site')
                            ->search({ name => $site_name_check })->single;
                        if ($site_obj) {
                            my $site_admin_count = $c->model('DBEncy')->resultset('UserSiteRole')->search({
                                user_id   => $user_id,
                                site_id   => $site_obj->id,
                                role      => { -like => 'admin' },
                                is_active => 1,
                            })->count;
                            if ($site_admin_count) {
                                $is_admin = 1;
                                $c->session->{is_admin} = 1;
                                unless (grep { lc($_) eq 'admin' } @$user_roles) {
                                    push @$user_roles, 'admin';
                                    $c->session->{roles} = $user_roles;
                                }
                                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto',
                                    "UserSiteRole admin granted for $username on site $site_name_check");
                            }
                        } else {
                            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'auto',
                                "Site not found in Site table: $site_name_check (user: $username)");
                        }
                    }
                };
                if ($@) {
                    $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'auto',
                        "UserSiteRole check failed for $username: $@");
                }
            }
        }
        
        # Set stash variables
        $c->stash->{username} = $username;
        $c->stash->{user_id} = $user_id;
        $c->stash->{user_roles} = $user_roles;
        $c->stash->{is_admin} = $is_admin;
        $c->stash->{user_logged_in} = $user_logged_in;
        
        # Initialize navigation variables with defaults to prevent template crashes
        $c->stash->{main_pages} = [];
        $c->stash->{member_pages} = [];
        $c->stash->{coop_pages} = [];
        $c->stash->{it_pages} = [];
        $c->stash->{helpdesk_pages} = [];
        $c->stash->{hosted_pages} = [];
        $c->stash->{main_links} = [];
        $c->stash->{member_links} = [];
        $c->stash->{coop_links} = [];
        $c->stash->{it_links} = [];
        $c->stash->{helpdesk_links} = [];
        $c->stash->{hosted_links} = [];
        $c->stash->{admin_pages} = [];
        $c->stash->{admin_links} = [];
        $c->stash->{private_links} = [];
        $c->stash->{navigation_error} = '';
        
        # Set up navigation data
        my $site_name = $c->stash->{SiteName} || 'All';
        my $nav_controller = $c->controller('Navigation');
        
        if ($nav_controller) {
            # Wrap navigation setup with timeout to prevent hanging if database is unreachable
            eval {
                local $SIG{ALRM} = sub { die "Navigation setup timeout\n"; };
                alarm(5);  # 5 second timeout for navigation setup
                
                # Ensure navigation tables exist and populate navigation data
                $nav_controller->populate_navigation($c);
                
                alarm(0);  # Cancel alarm on success
            };
            alarm(0);  # Make sure alarm is cancelled
            
            if ($@) {
                if ($@ =~ /timeout/i) {
                    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'auto',
                        "Navigation setup timed out (database connectivity issue). Continuing without navigation data.");
                    # Set empty navigation data to allow page to render
                    $c->stash->{main_pages} = [];
                    $c->stash->{member_pages} = [];
                    $c->stash->{coop_pages} = [];
                    $c->stash->{it_pages} = [];
                    $c->stash->{helpdesk_pages} = [];
                    $c->stash->{hosted_pages} = [];
                    $c->stash->{main_links} = [];
                    $c->stash->{member_links} = [];
                    $c->stash->{coop_links} = [];
                    $c->stash->{it_links} = [];
                    $c->stash->{helpdesk_links} = [];
                    $c->stash->{hosted_links} = [];
                    $c->stash->{navigation_error} = "Database connection failed. Navigation unavailable.";
                } else {
                    $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'auto',
                        "Navigation setup error: $@");
                }
            }
            
            # Only get menu items if navigation setup succeeded (no timeout)
            unless ($@) {
                # Get main menu items
                $c->stash->{main_pages} = $nav_controller->get_pages($c, 'Main', $site_name);
                $c->stash->{member_pages} = $nav_controller->get_pages($c, 'Member', $site_name);
                $c->stash->{coop_pages} = $nav_controller->get_pages($c, 'Coop', $site_name);
                $c->stash->{it_pages} = $nav_controller->get_pages($c, 'IT', $site_name);
                $c->stash->{helpdesk_pages} = $nav_controller->get_pages($c, 'HelpDesk', $site_name);
                $c->stash->{hosted_pages} = $nav_controller->get_pages($c, 'Hosted', $site_name);
                
                # Get internal links
                $c->stash->{main_links} = $nav_controller->get_internal_links($c, 'Main_links', $site_name);
                $c->stash->{member_links} = $nav_controller->get_internal_links($c, 'Member_links', $site_name);
                $c->stash->{coop_links} = $nav_controller->get_internal_links($c, 'Coop_links', $site_name);
                $c->stash->{it_links} = $nav_controller->get_internal_links($c, 'IT_links', $site_name);
                $c->stash->{helpdesk_links} = $nav_controller->get_internal_links($c, 'HelpDesk_links', $site_name);
                $c->stash->{hosted_links} = $nav_controller->get_internal_links($c, 'Hosted_links', $site_name);
                
                # Get admin data if user is admin
                if ($c->stash->{is_admin}) {
                    $c->stash->{admin_pages} = $nav_controller->get_admin_pages($c, $site_name);
                    $c->stash->{admin_links} = $nav_controller->get_admin_links($c, $site_name);
                }
                
                # Get private links for logged in users
                if ($c->stash->{user_logged_in}) {
                    $c->stash->{private_links} = $nav_controller->get_private_links($c, $c->session->{username}, $site_name);
                }
            }
            
            # Get navigation items from the new navigation system (showing private items only to logged-in users)
            # Temporarily commented out to restore login functionality
            # eval {
            #     my $user_logged_in = $c->stash->{user_logged_in} || 0;
            #     if ($nav_controller->can('get_navigation_tree')) {
            #         $c->stash->{navigation_main} = $nav_controller->get_navigation_tree($c, 'Main', $user_logged_in);
            #         $c->stash->{navigation_member} = $nav_controller->get_navigation_tree($c, 'Member', $user_logged_in);
            #         $c->stash->{navigation_coop} = $nav_controller->get_navigation_tree($c, 'Coop', $user_logged_in);
            #         $c->stash->{navigation_it} = $nav_controller->get_navigation_tree($c, 'IT', $user_logged_in);
            #         $c->stash->{navigation_helpdesk} = $nav_controller->get_navigation_tree($c, 'HelpDesk', $user_logged_in);
            #         $c->stash->{navigation_hosted} = $nav_controller->get_navigation_tree($c, 'Hosted', $user_logged_in);
            #         
            #         # Get admin navigation if user is admin
            #         if ($c->stash->{is_admin}) {
            #             $c->stash->{navigation_admin} = $nav_controller->get_navigation_tree($c, 'Admin', $user_logged_in);
            #         }
            #     }
            # };
            # if ($@) {
            #     $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'auto',
            #         "Error loading new navigation system: $@");
            # }
            
            # Debug logging for menu data
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'auto',
                "Menu data loaded for site '$site_name': " .
                "main_pages=" . (@{$c->stash->{main_pages} || []} . " items, ") .
                "main_links=" . (@{$c->stash->{main_links} || []} . " items, ") .
                "user_logged_in=" . ($c->stash->{user_logged_in} ? 'yes' : 'no') . ", " .
                "is_admin=" . ($c->stash->{is_admin} ? 'yes' : 'no')
            );
        } else {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'auto',
                "Navigation controller not found - menus will be empty");
        }
        
        # CRITICAL: Debug Bar Implementation - DO NOT REMOVE
        # This section provides server information for the debug bar UI
        # which displays hostname, IP, and database connection info to admins/debug mode.
        # Removing this breaks admin diagnostic capability and page rendering visibility.
        
        # Get server information - extract from database connection if available
        my $db_host = 'Unknown';
        my $system_info = Comserv::Util::SystemInfo::get_system_info();
        
        # Get application directory name to distinguish between workflows
        my $app_workflow = Comserv::Util::SystemInfo->get_app_workflow($c->config->{home});
        $c->stash->{app_workflow} = $app_workflow;

        # Expose the friendly system identifier (workstation / production) to all templates
        $c->stash->{system_identifier} = Comserv::Util::Logging->get_system_identifier();
        
        # Validate system_info returned valid data, add defaults if needed
        if (!$system_info || !ref($system_info)) {
            $system_info = {
                hostname => 'Unknown',
                ip => 'Unknown',
                os => $^O,
                perl_version => $^V,
            };
        }
        
        # CRITICAL: Ensure system_info values are never empty strings - treat empty as Unknown
        $system_info->{hostname} = 'Unknown' if !$system_info->{hostname} || $system_info->{hostname} eq '';
        $system_info->{ip} = 'Unknown' if !$system_info->{ip} || $system_info->{ip} eq '';
        
        # Populate database connections information for debug display
        my @db_connections;
        eval {
            # Try to get database connection info from active models
            if ($c->model('DBEncy')) {
                eval {
                    my $conn_info = $c->model('DBEncy')->get_connection_info();
                    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'auto', 
                        "DBEncy connection info: " . (defined $conn_info ? (ref $conn_info ? "hash ref" : "scalar: $conn_info") : "undef"));
                        
                    if ($conn_info && ref($conn_info) eq 'HASH') {
                        my $dsn = $conn_info->{current_dsn};
                        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'auto', 
                            "DBEncy DSN: $dsn");
                        
                        # Extract host from DSN: DBI:mysql:database=xyz;host=192.168.1.198;port=3306
                        # or dbi:MariaDB:database=ency;host=192.168.1.198;port=3306
                        my $host = 'Unknown';
                        if ($dsn && $dsn ne '' && $dsn ne 'Unknown') {
                            if ($dsn =~ /host=([^;]+)/) {
                                $host = $1;
                                # Clean up host value
                                $host =~ s/^\s+|\s+$//g;  # Trim whitespace
                                $db_host = $host if $db_host eq 'Unknown' && $host ne 'Unknown';  # Use first available host
                                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'auto', 
                                    "DBEncy host extracted: $host");
                            } else {
                                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'auto', 
                                    "DBEncy DSN has no host= pattern (likely SQLite): $dsn");
                            }
                        }
                        
                        push @db_connections, {
                            type => 'DBEncy',
                            name => 'Ency',
                            ip => $host
                        };
                        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'auto', 
                            "Added DBEncy to db_connections with host: $host");
                    } else {
                        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'auto', 
                            "DBEncy connection info is not a valid hash ref");
                    }
                };
                if ($@) {
                    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'auto', 
                        "Error extracting DBEncy connection info: $@");
                }
            } else {
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'auto', 
                    "DBEncy model not available");
            }
            
            if ($c->model('DBForager')) {
                eval {
                    my $conn_info = $c->model('DBForager')->get_connection_info();
                    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'auto', 
                        "DBForager connection info: " . (defined $conn_info ? (ref $conn_info ? "hash ref" : "scalar: $conn_info") : "undef"));
                        
                    if ($conn_info && ref($conn_info) eq 'HASH') {
                        my $dsn = $conn_info->{current_dsn};
                        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'auto', 
                            "DBForager DSN: $dsn");
                        
                        # Extract host from DSN
                        my $host = 'Unknown';
                        if ($dsn && $dsn ne '' && $dsn ne 'Unknown') {
                            if ($dsn =~ /host=([^;]+)/) {
                                $host = $1;
                                # Clean up host value
                                $host =~ s/^\s+|\s+$//g;  # Trim whitespace
                                $db_host = $host if $db_host eq 'Unknown' && $host ne 'Unknown';  # Use first available host
                                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'auto', 
                                    "DBForager host extracted: $host");
                            } else {
                                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'auto', 
                                    "DBForager DSN has no host= pattern (likely SQLite): $dsn");
                            }
                        }
                        
                        push @db_connections, {
                            type => 'DBForager',
                            name => 'Forager',
                            ip => $host
                        };
                        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'auto', 
                            "Added DBForager to db_connections with host: $host");
                    } else {
                        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'auto', 
                            "DBForager connection info is not a valid hash ref");
                    }
                };
                if ($@) {
                    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'auto', 
                        "Error extracting DBForager connection info: $@");
                }
            } else {
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'auto', 
                    "DBForager model not available");
            }
        };
        if ($@) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'auto', 
                "Error in database connection extraction: $@");
        }
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', 
            "Database connections collected: " . scalar(@db_connections) . " entries");
        
        # CRITICAL FALLBACK: If no database connections were added from models,
        # add a placeholder entry to ensure debug bar shows database info
        if (scalar(@db_connections) == 0) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'auto', 
                "No database connections collected from models - adding fallback entries");
            
            # Add placeholder entries so the debug bar displays SOMETHING
            push @db_connections, {
                type => 'DBEncy',
                name => 'Ency (fallback)',
                ip => 'Not available'
            };
            push @db_connections, {
                type => 'DBForager',
                name => 'Forager (fallback)',
                ip => 'Not available'
            };
        }
        
        # FALLBACK: If no host extracted from models (they may have fallen back to SQLite),
        # try to read db_config.json directly to get the configured primary database host
        if ($db_host eq 'Unknown') {
            eval {
                require JSON;
                my $config_paths = [
                    '/opt/comserv/db_config.json',  # Docker/production path
                    $ENV{COMSERV_DB_CONFIG},  # Environment variable override
                    (exists $ENV{CATALYST_ROOT}) ? ($ENV{CATALYST_ROOT} . '/../db_config.json') : (),
                ];
                
                foreach my $config_path (@$config_paths) {
                    next unless $config_path && -f $config_path;
                    
                    eval {
                        local $/;
                        open my $fh, '<', $config_path or die "Cannot open $config_path: $!";
                        my $json_text = <$fh>;
                        close $fh;
                        
                        my $config = JSON::decode_json($json_text);
                        
                        # Get the first non-placeholder production connection (highest priority)
                        foreach my $conn_name (sort {
                            ($config->{$a}{priority} // 999) <=> ($config->{$b}{priority} // 999)
                        } keys %$config) {
                            my $conn = $config->{$conn_name};
                            next unless ref($conn) eq 'HASH';
                            next if $conn->{db_type} && $conn->{db_type} eq 'sqlite';  # Skip SQLite
                            next unless $conn->{host};
                            next if $conn->{host} =~ /YOUR_|PLACEHOLDER|localhost/i;  # Skip placeholders and localhost
                            
                            $db_host = $conn->{host};
                            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto',
                                "Extracted DB host from config: $db_host (from $conn_name)");
                            last;
                        }
                    };
                    last if $db_host ne 'Unknown';
                }
            };
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto',
                "DB config fallback: db_host = $db_host") if $db_host ne 'Unknown';
        }
        
        $c->stash->{db_connections} = \@db_connections;
        
        # Set active database environment
        eval {
            require Comserv::Util::DatabaseEnv;
            my $db_env = Comserv::Util::DatabaseEnv->new();
            my $active_env = $db_env->get_active_environment($c);
            $c->stash->{active_db_environment} = $active_env;
        };
        if ($@) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'auto',
                "Error getting active database environment: $@");
            $c->stash->{active_db_environment} = 'production';
        }
        
        # CRITICAL DIAGNOSTICS: Log actual values before stash assignment
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto',
            "DEBUG: system_info->{hostname}='" . (defined $system_info->{hostname} ? $system_info->{hostname} : 'UNDEF') . "', " .
            "system_info->{ip}='" . (defined $system_info->{ip} ? $system_info->{ip} : 'UNDEF') . "', " .
            "db_host='$db_host'");
        
        # Set server_hostname to the Catalyst web server's IP (NOT the database host).
        # The database host is already shown separately in the Databases section.
        # system_info->{ip} returns the actual IP of the machine running Catalyst.
        my $display_hostname = ($system_info->{ip} && $system_info->{ip} ne 'Unknown')
            ? $system_info->{ip} : $system_info->{hostname};
        # Final safety check - ensure it's never empty or undef
        $display_hostname = 'Unknown' if !$display_hostname || $display_hostname eq '';
        
        # CRITICAL: Before setting stash, log the exact value being set
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'auto',
            "CRITICAL DEBUG: About to set server_hostname='$display_hostname' into stash");
        $c->stash->{server_hostname} = $display_hostname;
        
        # Verify stash was actually set
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'auto',
            "CRITICAL DEBUG: Verified stash server_hostname='" . $c->stash->{server_hostname} . "'");
        
        # Set server_ip to the actual server's network IP (Docker container IP for Catalyst)
        # CRITICAL: Always ensure a non-empty value to prevent blank display in templates
        my $display_ip = $system_info->{ip};
        # Final safety check - ensure it's never empty or undef
        $display_ip = 'Unknown' if !$display_ip || $display_ip eq '';
        
        # CRITICAL: Before setting stash, log the exact value being set
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'auto',
            "CRITICAL DEBUG: About to set server_ip='$display_ip' into stash");
        $c->stash->{server_ip} = $display_ip;
        
        # Verify stash was actually set
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'auto',
            "CRITICAL DEBUG: Verified stash server_ip='" . $c->stash->{server_ip} . "'");
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', 
            "Server info - DB Host: $db_host, Hostname: $display_hostname, IP: $display_ip");
        
        return 1; # Continue processing
    };
    
    # Error handling for auto() method
    if ($@) {
        my $error = $@;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'auto', 
            "Exception in auto() method: $error");
        
        # Set HTTP 500 status
        $c->response->status(500);
        
        # Prepare error stash variables for error.tt template
        $c->stash->{error_title} = 'Application Initialization Error';
        $c->stash->{error_msg} = 'An error occurred while initializing the application.';
        $c->stash->{technical_details} = $error;
        $c->stash->{template} = 'error.tt';
        
        # Use detach() to cleanly exit and let default view rendering handle it
        # DO NOT use forward() as it can cause infinite loops with view processing
        $c->detach( $c->view('TT') );
        
        # Return 0 to halt further action processing after error
        return 0;
    }
    
    return 1;
}

sub health :Path('/health') :Args(0) {
    my ($self, $c) = @_;
    
    # Lightweight liveness check — no DB query, no session, no logging.
    # Purpose: tell Docker the web process is alive and accepting connections.
    # DB health is monitored separately by ContainerHealthMonitor.pl.
    $c->response->content_type('application/json');
    $c->response->status(200);
    $c->response->body('{"status":"ok"}');
    $c->detach;
    return;
}

sub health_detail :Path('/health/detail') :Args(0) {
    my ($self, $c) = @_;

    $c->response->content_type('application/json');

    my %info;
    my $ok = 1;

    # 1. Process info
    $info{pid}     = $$;
    $info{uptime}  = time() - $^T;

    # 2. Memory (Linux /proc/self/status)
    eval {
        open my $fh, '<', '/proc/self/status' or die;
        while (<$fh>) {
            if (/^VmRSS:\s+(\d+)\s+kB/) { $info{mem_rss_kb} = $1 + 0; last }
        }
        close $fh;
    };

    # 3. Starman sibling workers (how many Perl processes share same parent)
    eval {
        my $ppid = getppid();
        my @siblings = split /\n/, `ps --no-headers -o pid --ppid $ppid 2>/dev/null` // '';
        $info{worker_siblings} = scalar(grep { /\d/ } @siblings);
    };

    # 4. Session dir writable
    eval {
        my $sess_dir = $ENV{COMSERV_SESSION_DIR} || '/tmp/comserv/session';
        $info{session_dir_ok} = (-d $sess_dir && -w $sess_dir) ? 1 : 0;
        $ok = 0 unless $info{session_dir_ok};
    };

    # 5. Quick DB ping (non-blocking, 2s timeout)
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm(2);
        my $schema = $c->model('DBEncy');
        $schema->storage->dbh->ping;
        alarm(0);
        $info{db_ok} = 1;
    };
    if ($@) {
        alarm(0);
        $info{db_ok}    = 0;
        $info{db_error} = "$@";
        $ok = 0;
    }

    my $status = $ok ? 'ok' : 'degraded';
    $info{status} = $status;

    # Log to system_log if degraded so admin/logging shows the reason
    if (!$ok) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'health_detail',
            "[HEALTH_DETAIL] status=$status db_ok=" . ($info{db_ok}//0) .
            " mem_rss_kb=" . ($info{mem_rss_kb}//'?') .
            " workers=" . ($info{worker_siblings}//'?') .
            " session_ok=" . ($info{session_dir_ok}//'?') .
            " db_error=" . ($info{db_error}//'none'));
    }

    require JSON;
    $c->response->status($ok ? 200 : 503);
    $c->response->body(JSON::encode_json(\%info));
    $c->detach;
    return;
}

sub index :Path('/') :Args(0) {
    my ($self, $c) = @_;

    # LAYER 2: Index Action Protection - wrap entire action in error handling
    eval {
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
                return 1;  # Return after redirect, do not detach (causes catalyst_detach exception)
            } else {
                # Log the error and fall back to Root's index template
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'index',
                    "Controller '$ControllerName' not found or not loaded. Falling back to Root's index template.");

                # Set a flash message for debugging
                $c->flash->{error_msg} = "Controller '$ControllerName' not found. Please try again or contact the administrator.";

                # Default to Root's index template - let default view rendering handle it
                $c->stash(template => 'index.tt');
                return 1;
            }
        } else {
            # Default to Root's index template - let default view rendering handle it
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Defaulting to Root's index template");
            $c->stash(template => 'index.tt');
            return 1;
        }

        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Completed index action");
        return 1; # Allow the request to proceed
    };
    
    # Error handling for index() method
    if ($@) {
        my $error = $@;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'index', 
            "Exception in index() action: $error");
        
        # Set HTTP 500 status
        $c->response->status(500);
        
        # Prepare error stash variables for error.tt template
        $c->stash->{error_title} = 'Home Page Error';
        $c->stash->{error_msg} = 'An error occurred while loading the home page.';
        $c->stash->{technical_details} = $error;
        $c->stash->{template} = 'error.tt';
        
        # Use detach() to cleanly exit and let default view rendering handle it
        # DO NOT use forward() as it can cause infinite loops with view processing
        $c->detach( $c->view('TT') );
        
        return 0; # Halt further processing
    }
}


sub set_theme {
    my ($self, $c) = @_;

    # Get the site name
    my $site_name = $c->stash->{SiteName} || $c->session->{SiteName} || 'default';

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'set_theme', "Setting theme for site: $site_name");

    # Get all available themes from canonical ThemeConfig
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
    } elsif (my $hdr_site = $c->req->header('X-Sitename')) {
        $hdr_site =~ s/[^a-zA-Z0-9._-]//g;
        if ($hdr_site) {
            $value = $hdr_site;
            $c->stash->{SiteName} = $value;
            $c->session->{SiteName} = $value;
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'fetch_and_set', "X-Sitename header found: $value");
        }
    }

    if (!defined $c->stash->{SiteName}) {
        if (defined $c->session->{SiteName}) {
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
    
    # Temporarily add back the uri_no_port function to prevent template errors
    # This will be removed once all templates are updated
    $c->stash->{uri_no_port} = sub {
        my $path = shift;
        my $uri = $c->uri_for($path, @_);
        return $uri;
    };
    
    # Note: user_exists and check_user_roles methods are available via controller('Root')
    
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
        # Backward-compatible bulk generator (optional: only if the method exists)
        if (ref $c->model('ThemeConfig') && $c->model('ThemeConfig')->can('generate_all_theme_css')) {
            $c->model('ThemeConfig')->generate_all_theme_css($c);
        } else {
            # Fallback: perform per-theme CSS generation using available definitions
            my $themes = $c->model('ThemeConfig')->get_all_themes($c);
            foreach my $theme_name (keys %$themes) {
                my $theme_id = $themes->{$theme_name}{id} || next;
                next unless $theme_id;
                my $css = $c->model('ThemeConfig')->generate_theme_css($c, $theme_id);
                my $dir = $c->path_to('root', 'static', 'css', 'themes');
                my $file = "$dir/$theme_name.css";
                require File::Path;
                unless (-d $dir) { File::Path::make_path($dir); }
                use File::Slurp;
                write_file($file, $css);
            }
        }
        $self->_theme_css_generated(1);
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "Generated all theme CSS files");
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
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto',
        "FINAL CHECK: site_display_name='" . ($c->stash->{site_display_name}//'UNDEF') . "'");
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
            
            # Connect to the SMTP server with debug enabled
            my $smtp = Net::SMTP->new(
                $smtp_host,
                Port => $smtp_port,
                Debug => 1,
                Timeout => 30
            );
            
            unless ($smtp) {
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'send_email',
                    "Could not connect to SMTP server $smtp_host:$smtp_port: $!");
                return 0; # Return failure instead of dying
            }
            
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'send_email',
                "Connected to SMTP server $smtp_host:$smtp_port");
            
            # Start TLS if needed
            if ($smtp_ssl eq 'starttls') {
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'send_email',
                    "Starting TLS");
                $smtp->starttls() or die "STARTTLS failed: " . $smtp->message();
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

            # Detach to the error template and stop processing
            $c->detach($c->view('TT')); # Clean exit - no forward() to avoid infinite loop
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
            $c->stash->{debug_msg} = [] unless ref $c->stash->{debug_msg} eq 'ARRAY';
            push @{$c->stash->{debug_msg}}, "Domain '$domain' not found in sitedomain table. Please add it using the Site Administration interface.";

            # Set flash error message to ensure it's displayed
            $c->flash->{error_msg} = "Domain Error: This domain ($domain) is not properly configured in the system.";

            # Detach to the error template and stop processing
            $c->detach($c->view('TT')); # Clean exit - no forward() to avoid infinite loop
        }
    }

    $self->site_setup($c, $c->session->{SiteName});
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'setup_site', 'Completed site setup');
}

sub site_setup {
    my ($self, $c, $SiteName) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'site_setup', "SiteName (input): '" . (defined $SiteName ? $SiteName : 'UNDEF') . "'");
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'site_setup', 'MARKER: site_setup instrumentation active v1');

    # Get the current domain for HostName
    my $domain = $c->req->uri->host;
    my $port = $c->req->uri->port;
    my $host_port = $domain;
    if ($port && $port != 80 && $port != 443) {
        $host_port .= ":$port";
    }

    # Set a default HostName based on the current domain
    my $protocol = $c->req->secure ? 'https' : 'http';
    my $default_hostname = "$protocol://$host_port";
    $c->stash->{HostName} = $default_hostname;
    $c->session->{Domain} = $domain;

    # Log key context prior to DB lookup
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'site_setup',
        "Context: Domain='$domain', Session.SiteName='" . ($c->session->{SiteName}//'UNDEF') . "', Stash.SiteName='" . ($c->stash->{SiteName}//'UNDEF') . "'");

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

    # Primary attempt: lookup by SiteName (as provided)
    my $site = $c->model('Site')->get_site_details_by_name($c, $SiteName);
    if (!defined $site) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'site_setup',
            "No site found by name='" . (defined $SiteName ? $SiteName : 'UNDEF') . "'. Attempting domain-based resolution for '$domain'.");
        # Fallback: resolve via domain to site_id then fetch details
        my $site_domain = eval { $c->model('Site')->get_site_domain($c, $domain) };
        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'site_setup', "get_site_domain error: $@");
        }
        if ($site_domain) {
            my $site_id = eval { $site_domain->site_id };
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'site_setup', "Resolved site_id via domain: '" . (defined $site_id ? $site_id : 'UNDEF') . "'");
            if (defined $site_id) {
                $site = eval { $c->model('Site')->get_site_details($c, $site_id) };
                if ($@) {
                    $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'site_setup', "get_site_details error: $@");
                }
            }
        } else {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'site_setup', "Domain-based resolution failed for domain '$domain'");
        }
    }

    unless (defined $site) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'site_setup', "No site could be resolved. SiteName='" . ($SiteName//'UNDEF') . "', Domain='" . ($domain//'UNDEF') . "'");

        # Ensure site_display_name is never missing in stash/session, even on failure
        my $fallback_display = $c->stash->{SiteName} || $c->session->{SiteName} || 'Site';
        $c->stash->{SiteDisplayName}   = $fallback_display;
        $c->stash->{site_display_name} = $fallback_display;
        $c->session->{site_display_name} = $fallback_display;

        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'site_setup',
            "STASH_CHECK: site_display_name='" . ($c->stash->{site_display_name}//'UNDEF') .
            "', SiteDisplayName='" . ($c->stash->{SiteDisplayName}//'UNDEF') . "' (fallback)");

        # Set default values for other critical variables
        $c->stash->{ScriptDisplayName} = 'Site';
        $c->stash->{css_view_name} = '/static/css/default.css';
        $c->stash->{mail_to_admin} = 'admin@computersystemconsulting.ca';
        $c->stash->{mail_replyto} = 'helpdesk.computersystemconsulting.ca';

        # Add debug information
        $c->stash->{debug_errors} //= [];
        push @{$c->stash->{debug_errors}}, "ERROR: No site found (by name or domain).";

        # Ensure debug_msg is always an array
        $c->stash->{debug_msg} = [] unless ref $c->stash->{debug_msg} eq 'ARRAY';
        push @{$c->stash->{debug_msg}}, "Using default site settings because no site was resolved for '" . ($SiteName//"UNDEF") . "'";

        return;
    }

    # Log ALL site values we care about for diagnostics
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'site_setup',
        "SITE RECORD: id='" . ($site->can('id') ? ($site->id//'UNDEF') : 'NA') .
        "' name='" . ($site->can('name') ? ($site->name//'UNDEF') : 'NA') .
        "' site_display_name='" . ($site->can('site_display_name') ? ($site->site_display_name//'UNDEF') : 'NA') .
        "' css_view_name='" . ($site->can('css_view_name') ? ($site->css_view_name//'UNDEF') : 'NA') .
        "' mail_to_admin='" . ($site->can('mail_to_admin') ? ($site->mail_to_admin//'UNDEF') : 'NA') .
        "' mail_replyto='" . ($site->can('mail_replyto') ? ($site->mail_replyto//'UNDEF') : 'NA') .
        "' document_root_url='" . ($site->can('document_root_url') ? ($site->document_root_url//'UNDEF') : 'NA') .
        "' home_view='" . ($site->can('home_view') ? ($site->home_view//'UNDEF') : 'NA') . "'");

    my $css_view_name     = $site->can('css_view_name')     ? ($site->css_view_name || '/static/css/default.css') : '/static/css/default.css';
    my $site_display_name = $site->can('site_display_name') ? $site->site_display_name : undef;
    my $mail_to_admin     = $site->can('mail_to_admin')     ? ($site->mail_to_admin || 'admin@computersystemconsulting.ca') : 'admin@computersystemconsulting.ca';
    my $mail_replyto      = $site->can('mail_replyto')      ? ($site->mail_replyto || 'helpdesk.computersystemconsulting.ca') : 'helpdesk.computersystemconsulting.ca';
    my $site_name         = $site->can('name')              ? ($site->name || $SiteName) : $SiteName;

    # If site has a document_root_url, use it for HostName
    if ($site->can('document_root_url') && $site->document_root_url && $site->document_root_url ne '') {
        $c->stash->{HostName} = $site->document_root_url;
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'site_setup',
            "Set HostName from document_root_url: " . $site->document_root_url);
    }

    # Get theme from canonical ThemeConfig
    my $theme_name = $c->model('ThemeConfig')->get_site_theme($c, $site_name);

    # Set theme in stash for Header.tt to use
    $c->stash->{theme_name} = $theme_name;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'site_setup',
        "Set theme_name in stash: $theme_name");

    # Write resolved values to stash/session
    $c->stash->{SiteDisplayName}   = $site_display_name;
    $c->stash->{site_display_name} = $site_display_name;
    $c->stash->{css_view_name}     = $css_view_name;
    $c->stash->{mail_to_admin}     = $mail_to_admin;
    $c->stash->{mail_replyto}      = $mail_replyto;
    $c->stash->{SiteName}          = $site_name;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'site_setup',
        "STASH_CHECK: site_display_name='" . ($c->stash->{site_display_name}//'UNDEF') .
        "', SiteDisplayName='" . ($c->stash->{SiteDisplayName}//'UNDEF') . "'");

    $c->session->{site_display_name} = $site_display_name;
    $c->session->{SiteName}          = $site_name;

    # Log the final values being set for verification
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'site_setup',
        "STASHED: site_display_name='" . ($c->stash->{site_display_name}//'UNDEF') .
        "', SiteDisplayName='" . ($c->stash->{SiteDisplayName}//'UNDEF') .
        "', SiteName='" . ($c->stash->{SiteName}//'UNDEF') .
        "', css_view_name='" . ($c->stash->{css_view_name}//'UNDEF') . "'");

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

# Request lifecycle: Begin - log request start
sub begin :Private {
    my ($self, $c) = @_;
    
    # Store request start time for timing analysis
    $c->stash->{_request_start_time} = time();
    $c->stash->{_request_start_hires} = [gettimeofday()];
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'begin', 
        "[REQUEST_START] Method: " . $c->req->method . 
        " Path: " . $c->req->path . 
        " at " . scalar(localtime($c->stash->{_request_start_time})));

    # Ensure SiteName is established as early as possible for all routes
    eval {
        my $sn = $c->stash->{SiteName} // $c->session->{SiteName};
        unless (defined $sn && $sn ne '' && $sn ne 'none') {
            $self->fetch_and_set($c, 'SiteName');
            $sn = $c->stash->{SiteName} // $c->session->{SiteName};
        }
        # Always perform site_setup at begin to guarantee site_display_name in stash
        if (defined $sn && $sn ne '') {
            $self->site_setup($c, $sn);
        } else {
            # As absolute fallback, try with 'CSC' (commonly configured)
            $self->site_setup($c, 'CSC');
        }
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'begin',
            "BEGIN INIT: site_display_name='" . ($c->stash->{site_display_name}//'UNDEF') . "', SiteName='" . ($c->stash->{SiteName}//'UNDEF') . "'");
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'begin', "BEGIN INIT ERROR: $@");
    }
}

sub end : ActionClass('RenderView') {
    my ($self, $c) = @_;

    # Intercept unhandled Catalyst errors and render a friendly error page —
    # but only in production (CATALYST_DEBUG=0). In debug mode, let Catalyst
    # show its full error page so developers can see the real stack trace.
    if (@{$c->error || []} && !$c->response->body && !$c->debug) {
        my @errors   = @{$c->error};
        my $err_text = join(' | ', map { defined $_ ? "$_" : 'UNDEF' } @errors);

        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'end',
            "Unhandled application error: $err_text");

        eval {
            require Comserv::Util::HealthLogger;
            Comserv::Util::HealthLogger->log_health_event(
                undef, 'error', 'HTTP_ERROR',
                "Unhandled 500: $err_text",
                { sitename => ($c->stash->{SiteName} || '') }
            );
        };

        $c->clear_errors;
        $c->response->status(500);
        $c->stash(
            template    => 'error.tt',
            error_title => 'Temporary Service Issue',
            error_msg   => 'We encountered an error processing your request. '
                         . 'The system administrator has been notified. '
                         . 'Please try again in a few minutes, or use the Back button.',
        );
    }

    # Never try to render a template for redirect or no-content responses
    my $status = $c->response->status || 0;
    if ($status >= 300 && $status < 400) {
        return;
    }
    if ($status == 204) {
        return;
    }
    # Also skip if a JSON/non-HTML body has already been set
    if ($c->response->body && $c->response->content_type &&
        $c->response->content_type !~ m{^text/html}i) {
        return;
    }

    if ($c->res->content_type && $c->res->content_type =~ m{^text/html}i) {
        $c->res->headers->header(
            'Content-Security-Policy' => 
                "default-src 'self'; " .
                "script-src 'self' 'unsafe-inline'; " .
                "style-src 'self' 'unsafe-inline'; " .
                "img-src 'self' data: https:; " .
                "font-src 'self'; " .
                "frame-src 'none'; " .
                "object-src 'none'; " .
                "base-uri 'self'; " .
                "form-action 'self' https://www.paypal.com https://www.sandbox.paypal.com;"
        );
    }
    
    # Calculate request duration
    if ($c->stash->{_request_start_time}) {
        my $duration = time() - $c->stash->{_request_start_time};
        my $status = $c->response->status || 'unknown';
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'end', 
            "[REQUEST_END] Method: " . $c->req->method . 
            " Path: " . $c->req->path . 
            " Status: " . $status . 
            " Duration: ${duration}s");
        
        # Warn if request took too long
        if ($duration > 5) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'end', 
                "[SLOW_REQUEST] Request took ${duration}s - may indicate database hang or processing issue");
        }
    }
}

# Default action for handling 404 errors
sub default :Path {
    my ($self, $c) = @_;

    my $requested_path = $c->req->path;

    # Classify the requester for logging context
    my %req_info = Comserv::Util::Logging::extract_request_info($c);
    my $req_type    = $req_info{request_type} // 'unknown';
    my $ip          = $req_info{ip_address}   // '-';
    my $ua          = $req_info{user_agent}   // '-';
    my $method      = $req_info{request_method} // '-';
    my $referer     = $req_info{referer}      // '-';

    # Detect if the request targets a restricted admin path.
    # For security, a 404 (not a 403) is returned so the path's existence is not revealed.
    my $is_admin_path = ($requested_path =~ m{^/admin\b}i
                      || $requested_path =~ m{^/csc/admin\b}i);
    my $is_admin_user = $self->check_user_roles($c, 'admin');

    if ($is_admin_path && !$is_admin_user) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'default',
            "Stealth-404 for admin path '$requested_path' — "
            . "IP:$ip Type:$req_type Method:$method Referer:$referer");
        $c->response->status(404);
        $self->logging->log_access($c, 404);
        $c->stash(
            template    => 'error.tt',
            error_title => 'Page Not Found',
            error_msg   => 'The page you requested could not be found.',
        );
        return;
    }

    my $log_level = ($req_type eq 'scanner') ? 'error'
                  : ($req_type eq 'bot')     ? 'info'
                  :                            'warn';

    $self->logging->log_with_details($c, $log_level, __FILE__, __LINE__, 'default',
        "404 Not Found: '$requested_path' — "
        . "IP:$ip Type:$req_type Method:$method Referer:$referer");

    $c->response->status(404);
    $self->logging->log_access($c, 404);
    $c->stash(
        template          => 'error.tt',
        error_title       => 'Page Not Found',
        error_msg         => "The page you requested could not be found: /$requested_path.",
        requested_path    => $requested_path,
        technical_details => '',
    );

    $c->stash->{debug_msg} = [] unless ref($c->stash->{debug_msg}) eq 'ARRAY';
    push @{$c->stash->{debug_msg}}, "Page not found: /$requested_path";
}

__PACKAGE__->meta->make_immutable;

1;
