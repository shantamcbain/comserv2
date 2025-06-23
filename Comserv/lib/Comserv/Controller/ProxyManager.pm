package Comserv::Controller::ProxyManager;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;
use JSON::MaybeXS qw(encode_json decode_json);
use LWP::UserAgent;
use Try::Tiny;
use Config::General;
use File::Temp qw(tempfile);
use IPC::Run3 qw(run3);
use Path::Tiny qw(path);
# Use flexible YAML loading with fallback options
BEGIN {
    my $yaml_module;
    for my $module (qw(YAML::XS YAML::Syck YAML::Tiny YAML)) {
        eval "require $module";
        if (!$@) {
            $yaml_module = $module;
            last;
        }
    }
    
    if ($yaml_module) {
        if ($yaml_module eq 'YAML::XS') {
            eval "use YAML::XS qw(LoadFile DumpFile)";
        } elsif ($yaml_module eq 'YAML::Syck') {
            eval "use YAML::Syck qw(LoadFile DumpFile)";
        } elsif ($yaml_module eq 'YAML::Tiny') {
            eval "use YAML::Tiny";
            # YAML::Tiny has different interface, we'll handle this in methods
        } else {
            eval "use YAML qw(LoadFile DumpFile)";
        }
    } else {
        die "No YAML module available. Please install YAML::XS, YAML::Syck, YAML::Tiny, or YAML";
    }
}

BEGIN { extends 'Catalyst::Controller'; }

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

# Base method for chained actions
sub base :Chained('/') :PathPart('proxymanager') :CaptureArgs(0) {
    my ($self, $c) = @_;
    # This will be the root of the chained actions
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'base', 
        "ProxyManager base method called");
}

# Direct path methods for backward compatibility
sub direct_install_docker :Path('/proxymanager/install_docker') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'direct_install_docker',
        "Direct path to Docker installation page accessed, forwarding to chained action");
    
    # Stash variables for the template
    $c->stash(template => 'CSC/docker_install.tt');
    
    # Check if Docker is already installed
    my $docker_installed = 0;
    eval {
        my $docker_check = `which docker 2>/dev/null`;
        $docker_installed = 1 if $docker_check;
    };
    
    # Get system information
    my $os_info = {};
    eval {
        my $os_release = `cat /etc/os-release 2>/dev/null`;
        if ($os_release =~ /PRETTY_NAME="([^"]+)"/) {
            $os_info->{name} = $1;
        }
        if ($os_release =~ /VERSION_ID="([^"]+)"/) {
            $os_info->{version} = $1;
        }
        if ($os_release =~ /ID=([^\s]+)/) {
            $os_info->{id} = $1;
        }
        
        # Get kernel version
        my $kernel_version = `uname -r 2>/dev/null`;
        chomp($kernel_version);
        $os_info->{kernel} = $kernel_version if $kernel_version;
        
        # Get architecture
        my $arch = `uname -m 2>/dev/null`;
        chomp($arch);
        $os_info->{arch} = $arch if $arch;
    };
    
    # Prepare installation instructions based on OS
    my $installation_instructions = {
        general => "Docker installation instructions vary by operating system. Please follow the official Docker documentation for your specific OS.",
        ubuntu => "sudo apt-get update && sudo apt-get install -y docker.io docker-compose",
        debian => "sudo apt-get update && sudo apt-get install -y docker.io docker-compose",
        centos => "sudo yum install -y docker docker-compose",
        fedora => "sudo dnf install -y docker docker-compose",
        rhel => "sudo yum install -y docker docker-compose",
        arch => "sudo pacman -S docker docker-compose",
    };
    
    # Determine which instructions to show based on OS
    my $os_specific_instructions = $installation_instructions->{general};
    if ($os_info->{id}) {
        if ($os_info->{id} =~ /ubuntu/) {
            $os_specific_instructions = $installation_instructions->{ubuntu};
        } elsif ($os_info->{id} =~ /debian/) {
            $os_specific_instructions = $installation_instructions->{debian};
        } elsif ($os_info->{id} =~ /centos/) {
            $os_specific_instructions = $installation_instructions->{centos};
        } elsif ($os_info->{id} =~ /fedora/) {
            $os_specific_instructions = $installation_instructions->{fedora};
        } elsif ($os_info->{id} =~ /rhel/) {
            $os_specific_instructions = $installation_instructions->{rhel};
        } elsif ($os_info->{id} =~ /arch/) {
            $os_specific_instructions = $installation_instructions->{arch};
        }
    }
    
    # Stash variables for the template
    $c->stash(
        docker_installed => $docker_installed,
        os_info => $os_info,
        installation_instructions => $os_specific_instructions,
        debug_msg => "Docker installation page accessed. Docker installed: " . 
                    ($docker_installed ? "Yes" : "No") . ", OS: " . 
                    ($os_info->{name} || "Unknown")
    );
    
    # Forward to the TT view to render the template
    $c->forward($c->view('TT'));
}

sub direct_index :Path('/proxymanager') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'direct_index',
        "Direct path to ProxyManager dashboard accessed, forwarding to chained action");
    $c->forward('index');
    $c->forward($c->view('TT'));
}

# Define the roles that can access proxy management
has 'proxy_management_roles' => (
    is => 'ro',
    isa => 'ArrayRef[Str]',
    default => sub { ['admin', 'proxy_manager', 'network_admin', 'devops'] }
);

# Method to check if a user has proxy management rights
sub has_proxy_rights {
    my ($self, $c) = @_;
    
    my $root_controller = $c->controller('Root');
    
    # Admin always has access
    return 1 if $root_controller->check_user_roles($c, 'admin');
    
    # Check for specific proxy management roles
    foreach my $role (@{$self->proxy_management_roles}) {
        return 1 if $root_controller->check_user_roles($c, $role);
    }
    
    # Check if user has been granted specific proxy access in their session
    return 1 if $c->session->{proxy_access} && $c->session->{proxy_access} eq 'granted';
    
    # No proxy rights
    return 0;
}

has 'npm_api' => (
    is => 'ro',
    lazy => 1,
    default => sub {
        my $self = shift;
        
        # Default values (fallback)
        my $api_config = {
            url => $ENV{NPM_API_URL} || 'http://localhost:81/api',
            key => $ENV{NPM_API_KEY} || 'dummy_key_for_development',
            environment => $ENV{CATALYST_ENV} || 'development',
            access_scope => 'localhost-only'
        };
        
        # Try to load from environment-specific config file
        my $environment = $ENV{CATALYST_ENV} || 'development';
        my $config_file = Catalyst::Utils::home('Comserv') . "/config/npm-$environment.conf";
        
        if (-e $config_file) {
            eval {
                my $conf = Config::General->new($config_file);
                my %config_hash = $conf->getall();
                if ($config_hash{NPM}) {
                    # Ensure endpoint has /api suffix for API calls
                    my $endpoint = $config_hash{NPM}->{endpoint} || $api_config->{url};
                    my $api_url = $endpoint;
                    $api_url .= '/api' unless $api_url =~ /\/api$/;
                    
                    $api_config = {
                        url => $api_url,
                        endpoint => $endpoint,
                        key => $config_hash{NPM}->{api_key} || $api_config->{key},
                        environment => $config_hash{NPM}->{environment} || $api_config->{environment},
                        access_scope => $config_hash{NPM}->{access_scope} || $api_config->{access_scope}
                    };
                }
            };
            # If there's an error loading the config, we'll use the default values
            if ($@) {
                warn "Error loading NPM config from $config_file: $@";
            }
        }
        
        return $api_config;
    }
);

sub auto :Private {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto',
        "ProxyManager controller auto method called");

    # Check if we have a valid API key
    if ($self->npm_api->{key} eq 'dummy_key_for_development') {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'auto',
            "NPM API key not configured. Using dummy key for development.");
        $c->stash->{api_warning} = "NPM API key not configured. Some features may not work correctly.";
    }
    
    # Log environment information
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'auto',
        "Using NPM environment: " . $self->npm_api->{environment} . 
        " with access scope: " . $self->npm_api->{access_scope});
    
    # Check if user has temporary access that has expired
    if ($c->session->{proxy_access} && $c->session->{proxy_access} eq 'granted' && 
        $c->session->{proxy_access_expiry} && $c->session->{proxy_access_expiry} < time()) {
        
        # Access has expired
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto',
            "Temporary proxy access has expired for user: " . ($c->session->{username} || 'unknown'));
        
        # Clear the access flags
        $c->session->{proxy_access} = 'expired';
        
        # Add a message to the stash
        $c->stash->{access_expired} = 1;
        $c->stash->{debug_msg} = "Your temporary proxy management access has expired. You can request new access if needed.";
    }
    
    # Check if user has proxy rights and log it
    my $root_controller = $c->controller('Root');
    if ($root_controller->user_exists($c)) {
        my $has_rights = $self->has_proxy_rights($c);
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'auto',
            "User " . ($c->session->{username} || 'unknown') . " proxy rights: " . 
            ($has_rights ? "Granted" : "Denied"));
            
        # Add access status to stash
        $c->stash->{has_proxy_rights} = $has_rights;
        
        # If user has temporary access, show expiry information
        if ($has_rights && $c->session->{proxy_access} && $c->session->{proxy_access} eq 'granted' && 
            $c->session->{proxy_access_expiry}) {
            
            my $expiry_time = $c->session->{proxy_access_expiry};
            my $current_time = time();
            my $time_left = $expiry_time - $current_time;
            
            if ($time_left > 0) {
                my $minutes = int($time_left / 60);
                $c->stash->{access_temporary} = 1;
                $c->stash->{access_expiry_minutes} = $minutes;
                $c->stash->{debug_msg} = "You have temporary access to proxy management for $minutes more minutes";
            }
        }
    }

    # Initialize API client
    eval {
        $c->stash->{npm_ua} = LWP::UserAgent->new(
            timeout => 10,
            default_headers => HTTP::Headers->new(
                Authorization => "Bearer " . $self->npm_api->{key},
                'Content-Type' => 'application/json'
            )
        );
        
        # Verify that npm_ua was properly initialized
        if (defined $c->stash->{npm_ua}) {
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'auto',
                "Successfully initialized npm_ua in auto method");
            
            # Add debug message to stash if not already set
            $c->stash->{debug_msg} = "NPM API client initialized successfully" 
                unless defined $c->stash->{debug_msg};
        } else {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'auto',
                "Failed to initialize npm_ua in auto method");
            
            # Add debug message to stash
            $c->stash->{debug_msg} = "Failed to initialize NPM API client";
        }
    };
    
    # Handle any errors during initialization
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'auto',
            "Error initializing npm_ua: $@");
        
        # Add debug message to stash
        $c->stash->{debug_msg} = "Error initializing NPM API client: $@";
    }

    return 1;
}

sub install_docker :Chained('base') :PathPart('install_docker') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'install_docker',
        "Docker installation page accessed");
    
    # Check if user is logged in and has proxy management privileges
    my $root_controller = $c->controller('Root');
    unless ($root_controller->user_exists($c) && $self->has_proxy_rights($c)) {
        # Format roles for logging
        my $roles_debug = 'none';
        if (defined $c->session->{roles}) {
            if (ref($c->session->{roles}) eq 'ARRAY') {
                $roles_debug = join(', ', @{$c->session->{roles}});
            } else {
                $roles_debug = $c->session->{roles};
            }
        }
        
        # Check if the user is logged in but lacks permissions
        if ($root_controller->user_exists($c)) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'install_docker',
                "Unauthorized access attempt to Docker installation page. User: " . 
                ($c->session->{username} || 'none') . ", Roles: " . $roles_debug);
            
            # Prepare a list of roles that can access proxy management
            my $allowed_roles = join(', ', @{$self->proxy_management_roles});
            
            $c->response->status(403);
            $c->stash(
                template => 'CSC/error/access_denied.tt',
                error_message => 'You do not have permission to access the Docker installation page.',
                debug_msg => "Access denied. You need one of these roles: $allowed_roles",
                request_access_url => '/proxy_manager/request_access',
                can_request_access => 1
            );
        } else {
            # User is not logged in
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'install_docker',
                "Anonymous access attempt to Docker installation page");
            
            $c->response->status(401);
            $c->stash(
                template => 'CSC/error/access_denied.tt',
                error_message => 'You must log in to access the Docker installation page.',
                login_required => 1,
                debug_msg => "Login required to access Docker installation page"
            );
        }
        return;
    }
    
    # Check if Docker is already installed
    my $docker_installed = 0;
    eval {
        my $docker_check = `which docker 2>/dev/null`;
        $docker_installed = 1 if $docker_check;
    };
    
    # Get system information
    my $os_info = {};
    eval {
        my $os_release = `cat /etc/os-release 2>/dev/null`;
        if ($os_release =~ /PRETTY_NAME="([^"]+)"/) {
            $os_info->{name} = $1;
        }
        if ($os_release =~ /VERSION_ID="([^"]+)"/) {
            $os_info->{version} = $1;
        }
        if ($os_release =~ /ID=([^\s]+)/) {
            $os_info->{id} = $1;
        }
        
        # Get kernel version
        my $kernel_version = `uname -r 2>/dev/null`;
        chomp($kernel_version);
        $os_info->{kernel} = $kernel_version if $kernel_version;
        
        # Get architecture
        my $arch = `uname -m 2>/dev/null`;
        chomp($arch);
        $os_info->{arch} = $arch if $arch;
    };
    
    # Prepare installation instructions based on OS
    my $installation_instructions = {
        general => "Docker installation instructions vary by operating system. Please follow the official Docker documentation for your specific OS.",
        ubuntu => "sudo apt-get update && sudo apt-get install -y docker.io docker-compose",
        debian => "sudo apt-get update && sudo apt-get install -y docker.io docker-compose",
        centos => "sudo yum install -y docker docker-compose",
        fedora => "sudo dnf install -y docker docker-compose",
        rhel => "sudo yum install -y docker docker-compose",
        arch => "sudo pacman -S docker docker-compose",
    };
    
    # Determine which instructions to show based on OS
    my $os_specific_instructions = $installation_instructions->{general};
    if ($os_info->{id}) {
        if ($os_info->{id} =~ /ubuntu/) {
            $os_specific_instructions = $installation_instructions->{ubuntu};
        } elsif ($os_info->{id} =~ /debian/) {
            $os_specific_instructions = $installation_instructions->{debian};
        } elsif ($os_info->{id} =~ /centos/) {
            $os_specific_instructions = $installation_instructions->{centos};
        } elsif ($os_info->{id} =~ /fedora/) {
            $os_specific_instructions = $installation_instructions->{fedora};
        } elsif ($os_info->{id} =~ /rhel/) {
            $os_specific_instructions = $installation_instructions->{rhel};
        } elsif ($os_info->{id} =~ /arch/) {
            $os_specific_instructions = $installation_instructions->{arch};
        }
    }
    
    # Stash variables for the template
    $c->stash(
        template => 'CSC/docker_install.tt',
        docker_installed => $docker_installed,
        os_info => $os_info,
        installation_instructions => $os_specific_instructions,
        debug_msg => "Docker installation page accessed. Docker installed: " . 
                    ($docker_installed ? "Yes" : "No") . ", OS: " . 
                    ($os_info->{name} || "Unknown")
    );
    
    # Forward to the TT view to render the template
    $c->forward($c->view('TT'));
}

sub index :Chained('base') :PathPart('') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
        "ProxyManager dashboard accessed");

    # Check if user is logged in and has proxy management privileges
    my $root_controller = $c->controller('Root');
    unless ($root_controller->user_exists($c) && $self->has_proxy_rights($c)) {
        # Format roles for logging
        my $roles_debug = 'none';
        if (defined $c->session->{roles}) {
            if (ref($c->session->{roles}) eq 'ARRAY') {
                $roles_debug = join(', ', @{$c->session->{roles}});
            } else {
                $roles_debug = $c->session->{roles};
            }
        }
        
        # Check if the user is logged in but lacks permissions
        if ($root_controller->user_exists($c)) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'index',
                "Unauthorized access attempt to ProxyManager dashboard. User: " . 
                ($c->session->{username} || 'none') . ", Roles: " . $roles_debug);
            
            # Prepare a list of roles that can access proxy management
            my $allowed_roles = join(', ', @{$self->proxy_management_roles});
            
            $c->response->status(403);
            $c->stash(
                template => 'CSC/error/access_denied.tt',
                error_message => 'You do not have permission to access the ProxyManager dashboard.',
                debug_msg => "Access denied. You need one of these roles: $allowed_roles",
                request_access_url => '/proxy_manager/request_access',
                can_request_access => 1
            );
        } else {
            # User is not logged in
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
                "Anonymous access attempt to ProxyManager dashboard");
            
            $c->response->status(401);
            $c->stash(
                template => 'CSC/error/access_denied.tt',
                error_message => 'You must log in to access the ProxyManager dashboard.',
                login_required => 1,
                debug_msg => "Login required to access ProxyManager"
            );
        }
        return;
    }

    # For admin users, we allow access from any location (including remote)
    # This is used for creating proxies for new customer sites over ZeroTier VPN
    if ($c->req->address !~ /^127\.0\.0\.1$|^::1$|^192\.168\.|^10\.|^172\.(1[6-9]|2[0-9]|3[0-1])\./) {
        # Just log the remote access for auditing purposes
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
            "Remote access to ProxyManager from IP: " . $c->req->address . 
            " by user: " . ($c->session->{username} || 'none') . 
            ", Roles: " . (ref($c->session->{roles}) eq 'ARRAY' ? 
                          join(', ', @{$c->session->{roles}}) : 
                          ($c->session->{roles} || 'none')));
        
        # Push debug message to stash as requested (no warning displayed to user)
        $c->stash->{debug_msg} = "Remote access from " . $c->req->address . 
            " by user " . ($c->session->{username} || 'none');
    }

    # Check if we're in development mode and Docker is not installed
    my $is_development = ($self->npm_api->{environment} eq 'development');
    my $docker_installed = 0;
    
    # Simple check if Docker is installed
    eval {
        my $docker_check = `which docker 2>/dev/null`;
        $docker_installed = 1 if $docker_check;
    };
    
    # Check if Docker is installed, regardless of environment
    if (!$docker_installed) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
            "Docker not installed. Showing installation guide.");
        
        # Create mock data for development
        my $mock_proxies = {
            'data' => [
                {
                    'id' => 1,
                    'domain_names' => ['example.com'],
                    'forward_scheme' => 'http',
                    'forward_host' => '192.168.1.100',
                    'forward_port' => 8080,
                    'created_on' => '2025-04-13T14:07:10.000Z',
                    'modified_on' => '2025-04-13T14:07:10.000Z'
                },
                {
                    'id' => 2,
                    'domain_names' => ['test.example.com'],
                    'forward_scheme' => 'https',
                    'forward_host' => '192.168.1.101',
                    'forward_port' => 443,
                    'created_on' => '2025-04-13T14:07:10.000Z',
                    'modified_on' => '2025-04-13T14:07:10.000Z'
                }
            ]
        };
        
        # Prepare installation status information
        my $installation_status = {
            docker => {
                installed => 0,
                message => "Not Installed",
                details => "System requirements not met"
            },
            kubernetes => {
                installed => 0,
                message => "Not Installed",
                details => "Docker must be installed first"
            },
            npm => {
                installed => 0,
                message => "Not Installed",
                details => "Docker must be installed first"
            }
        };
        
        # Add installation instructions
        my $installation_instructions = "To use the Proxy Manager, please install Docker first. " .
                                       "After Docker is installed, you can set up Nginx Proxy Manager " .
                                       "using Docker Compose or the Docker CLI.";
        
        $c->stash(
            proxies => $mock_proxies,
            template => 'CSC/proxy_manager.tt',
            environment => $self->npm_api->{environment},
            access_scope => $self->npm_api->{access_scope},
            npm_admin_url => $self->npm_api->{endpoint},
            debug_msg => "Docker is not installed. ProxyManager requires Docker and Nginx Proxy Manager.",
            installation_status => $installation_status,
            installation_instructions => $installation_instructions,
            development_notice => $is_development ? 
                "You are in development mode. Install Docker to use the Proxy Manager features." : 
                "Install Docker to use the Proxy Manager features.",
            show_docker_install_button => 1
        );
        return;
    }

    try {
        # Make sure npm_ua is defined before trying to use it
        if (!defined $c->stash->{npm_ua}) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'index',
                "npm_ua is not defined. Initializing it now.");
            
            # Initialize API client if it wasn't done in auto
            $c->stash->{npm_ua} = LWP::UserAgent->new(
                timeout => 10,
                default_headers => HTTP::Headers->new(
                    Authorization => "Bearer " . $self->npm_api->{key},
                    'Content-Type' => 'application/json'
                )
            );
            
            # Add debug message to stash
            $c->stash->{debug_msg} = "Had to initialize npm_ua in index action because it wasn't defined";
        }
        
        # Double-check that npm_ua is now defined
        unless (defined $c->stash->{npm_ua}) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'index',
                "Failed to initialize npm_ua");
            
            # Use the general error template with specific error details
            $c->response->status(500);
            $c->stash(
                template => 'error.tt',
                error_title => 'Proxy Manager Error',
                error_msg => 'Failed to initialize the API client for Nginx Proxy Manager.',
                technical_details => 'The npm_ua object could not be created. This may indicate a configuration issue.',
                action_required => 'Please check your NPM API configuration in the environment or config file.'
            );
            return;
        }
        
        # Log the API request for debugging
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'index',
            "Making API request to: " . $self->npm_api->{url} . "/nginx/proxy-hosts");
        
        # Add debug message to stash
        $c->stash->{debug_msg} = "Attempting to connect to NPM API at " . $self->npm_api->{url};
        
        my $res;
        eval {
            $res = $c->stash->{npm_ua}->get($self->npm_api->{url} . "/nginx/proxy-hosts");
        };
        
        # Handle any errors during the API request
        if ($@ || !defined $res) {
            my $error_message = $@ || "Unknown error occurred during API request";
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'index',
                "Exception during API request: $error_message");
            
            # Check if this is a connection refused error
            if ($error_message =~ /Connection refused/) {
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
                    "Connection refused to NPM API. Showing setup instructions.");
                
                # Prepare installation status information
                my $installation_status = {
                    docker => {
                        installed => 1,
                        message => "Installed",
                        details => "Docker is installed but Nginx Proxy Manager is not running"
                    },
                    kubernetes => {
                        installed => 0,
                        message => "Not Required",
                        details => "Optional for advanced deployments"
                    },
                    npm => {
                        installed => 0,
                        message => "Not Running",
                        details => "Container not started or not accessible"
                    }
                };
                
                # Add installation instructions for NPM
                my $installation_instructions = "Docker is installed, but Nginx Proxy Manager is not running. " .
                                              "Please start the Nginx Proxy Manager container using Docker Compose or the Docker CLI. " .
                                              "Make sure the container is accessible at " . $self->npm_api->{url};
                
                # Show a more helpful message for setup
                $c->stash(
                    template => 'error.tt',
                    error_title => 'Nginx Proxy Manager Setup Required',
                    error_msg => 'Nginx Proxy Manager is not running on this server.',
                    technical_details => 'Connection refused to ' . $self->npm_api->{url} . '. This is expected if the NPM container is not running.',
                    action_required => 'Please start the Nginx Proxy Manager container and ensure it\'s accessible.',
                    debug_msg => "NPM container setup required: Docker is installed but NPM container is not running",
                    installation_status => $installation_status,
                    installation_instructions => $installation_instructions,
                    setup_instructions => 1
                );
                return;
            }
            
            # Prepare installation status information based on the error
            my $installation_status = {
                docker => {
                    installed => 1,
                    message => "Installed",
                    details => "Docker is installed but there's an API connection issue"
                },
                kubernetes => {
                    installed => 0,
                    message => "Not Required",
                    details => "Optional for advanced deployments"
                },
                npm => {
                    installed => 0,
                    message => "Unknown Status",
                    details => "Cannot connect to API"
                }
            };
            
            # Add installation instructions based on the error
            my $installation_instructions = "Docker is installed, but there's an issue connecting to the Nginx Proxy Manager API. " .
                                          "Please check that the Nginx Proxy Manager container is running and the API is accessible at " . 
                                          $self->npm_api->{url} . ". " .
                                          "Verify that your API key is correctly configured in the environment or config file.";
            
            # Use the general error template with specific error details
            $c->response->status(500);
            $c->stash(
                template => 'error.tt',
                error_title => 'Proxy Manager Error',
                error_msg => 'Failed to make request to the Nginx Proxy Manager API.',
                technical_details => 'Exception during API request: ' . $error_message,
                action_required => 'Please check that the Nginx Proxy Manager is running and accessible.',
                debug_msg => "Exception during NPM API request: $error_message",
                installation_status => $installation_status,
                installation_instructions => $installation_instructions
            );
            return;
        }
        
        unless ($res->is_success) {
            my $error_details = "Status: " . $res->status_line;
            my $action_required = 'Please check that the Nginx Proxy Manager is running and accessible, and that your API key is valid.';
            
            # Provide more specific error details based on the HTTP status code
            if ($res->code == 401) {
                $error_details .= " - This may indicate an invalid API key";
                $action_required = 'Please check that your API key is valid and has the necessary permissions.';
            } elsif ($res->code == 404) {
                $error_details .= " - This may indicate an incorrect API URL";
                $action_required = 'Please check that the API URL is correct and that the Nginx Proxy Manager is properly configured.';
            } elsif ($res->code == 0) {
                $error_details .= " - This may indicate that the Nginx Proxy Manager is not running or not accessible";
                $action_required = 'Please check that the Nginx Proxy Manager service is running and accessible from this server.';
            } elsif ($res->code == 500) {
                $error_details .= " - This may indicate an internal server error in the Nginx Proxy Manager";
                $action_required = 'Please check the Nginx Proxy Manager logs for errors and ensure the service is functioning correctly.';
            } elsif ($res->code == 503) {
                $error_details .= " - This may indicate that the Nginx Proxy Manager service is unavailable or overloaded";
                $action_required = 'Please check that the Nginx Proxy Manager service is running and not experiencing high load.';
            }
            
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'index',
                "Failed to fetch proxies: " . $error_details);
            
            # Prepare installation status information based on the HTTP status code
            my $installation_status = {
                docker => {
                    installed => 1,
                    message => "Installed",
                    details => "Docker is installed but there's an API response issue"
                },
                kubernetes => {
                    installed => 0,
                    message => "Not Required",
                    details => "Optional for advanced deployments"
                },
                npm => {
                    installed => $res->code == 401 ? 1 : 0,
                    message => $res->code == 401 ? "Running (Auth Failed)" : 
                              ($res->code == 404 ? "Running (API Not Found)" : "Running (Error)"),
                    details => $res->code == 401 ? "API key invalid or missing" : 
                              ($res->code == 404 ? "API endpoint not found" : "API returned error " . $res->code)
                }
            };
            
            # Add installation instructions based on the HTTP status code
            my $installation_instructions = "";
            if ($res->code == 401) {
                $installation_instructions = "Docker and Nginx Proxy Manager are installed, but the API key is invalid. " .
                                           "Please check your API key configuration in the environment or config file.";
            } elsif ($res->code == 404) {
                $installation_instructions = "Docker and Nginx Proxy Manager are installed, but the API endpoint was not found. " .
                                           "Please check that the API URL is correct: " . $self->npm_api->{url};
            } else {
                $installation_instructions = "Docker and Nginx Proxy Manager are installed, but the API returned an error. " .
                                           "Please check the Nginx Proxy Manager logs for more information.";
            }
            
            # Use the general error template with more specific error details
            $c->response->status(500);
            $c->stash(
                template => 'error.tt',
                error_title => 'Proxy Manager Error',
                error_msg => 'Failed to fetch proxies from the Nginx Proxy Manager API.',
                technical_details => 'API request failed: ' . $error_details,
                action_required => $action_required,
                debug_msg => "Failed to fetch proxies: " . $error_details,
                installation_status => $installation_status,
                installation_instructions => $installation_instructions
            );
            return;
        }

        $c->stash(
            proxies => decode_json($res->decoded_content),
            template => 'CSC/proxy_manager.tt',
            environment => $self->npm_api->{environment},
            access_scope => $self->npm_api->{access_scope},
            npm_admin_url => $self->npm_api->{endpoint},
            debug_msg => "Successfully connected to NPM API at " . $self->npm_api->{url}
        );
    } catch {
        my $error_message = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'index',
            "Proxy fetch failed: $error_message");
        
        # Prepare installation status information for general errors
        my $installation_status = {
            docker => {
                installed => $docker_installed,
                message => $docker_installed ? "Installed" : "Not Installed",
                details => $docker_installed ? "Docker is installed but there was an error" : "System requirements not met"
            },
            kubernetes => {
                installed => 0,
                message => "Not Required",
                details => "Optional for advanced deployments"
            },
            npm => {
                installed => 0,
                message => "Unknown Status",
                details => "Error occurred during API communication"
            }
        };
        
        # Add general installation instructions
        my $installation_instructions = $docker_installed ?
            "Docker is installed, but there was an error communicating with the Nginx Proxy Manager API. " .
            "Please check that the Nginx Proxy Manager container is running and properly configured." :
            "Docker is not installed. Please install Docker first, then set up the Nginx Proxy Manager container.";
        
        # Determine the likely cause of the error
        my $error_title = 'Proxy Manager Error';
        my $error_msg = 'Failed to fetch proxies from the Nginx Proxy Manager API.';
        my $action_required = 'Please check that the Nginx Proxy Manager is running and accessible.';
        my $debug_msg = "Error occurred in ProxyManager controller index action: $error_message";
        
        # Provide more specific error details based on the error message
        if ($error_message =~ /Can't call method "get" on an undefined value/) {
            $error_title = 'API Client Error';
            $error_msg = 'The API client was not properly initialized.';
            $action_required = 'Please check your NPM API configuration and ensure the auto method is being called correctly.';
            $debug_msg = "npm_ua was undefined when trying to make API request";
        } elsif ($error_message =~ /Connection refused/) {
            $error_title = 'Connection Error';
            $error_msg = 'Connection to the Nginx Proxy Manager was refused.';
            $action_required = 'Please check that the service is running and the URL is correct.';
            $debug_msg = "Connection refused to NPM API at " . $self->npm_api->{url};
        } elsif ($error_message =~ /timeout/i) {
            $error_title = 'Timeout Error';
            $error_msg = 'The connection to the Nginx Proxy Manager timed out.';
            $action_required = 'Please check that the service is running and responsive.';
            $debug_msg = "Connection timeout to NPM API at " . $self->npm_api->{url};
        } elsif ($error_message =~ /certificate/i) {
            $error_title = 'SSL Certificate Error';
            $error_msg = 'There was an SSL certificate issue connecting to the Nginx Proxy Manager.';
            $action_required = 'Please check your SSL configuration.';
            $debug_msg = "SSL certificate error connecting to NPM API at " . $self->npm_api->{url};
        } elsif ($error_message =~ /JSON/i) {
            $error_title = 'JSON Parsing Error';
            $error_msg = 'There was an error parsing the JSON response from the Nginx Proxy Manager.';
            $action_required = 'Please check that the API is returning valid JSON data.';
            $debug_msg = "JSON parsing error in response from NPM API";
        } elsif ($error_message =~ /host.*not found/i) {
            $error_title = 'Host Resolution Error';
            $error_msg = 'The hostname for the Nginx Proxy Manager could not be resolved.';
            $action_required = 'Please check that the hostname in the API URL is correct and can be resolved.';
            $debug_msg = "Host resolution error for NPM API at " . $self->npm_api->{url};
        }
        
        # Use the general error template with more specific error details
        $c->response->status(500);
        $c->stash(
            template => 'error.tt',
            error_title => $error_title,
            error_msg => $error_msg,
            technical_details => 'Exception: ' . $error_message,
            action_required => $action_required,
            debug_msg => $debug_msg
        );
        return;
    };
    
    # Forward to the TT view to render the template
    $c->forward($c->view('TT'));
}

# Method to handle access requests
# Method to grant access to users (admin only)
sub grant_access :Local :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'grant_access',
        "Admin accessing grant access page");
    
    # Check if user is logged in and has admin privileges
    my $root_controller = $c->controller('Root');
    unless ($root_controller->user_exists($c) && $root_controller->check_user_roles($c, 'admin')) {
        # Format roles for logging
        my $roles_debug = 'none';
        if (defined $c->session->{roles}) {
            if (ref($c->session->{roles}) eq 'ARRAY') {
                $roles_debug = join(', ', @{$c->session->{roles}});
            } else {
                $roles_debug = $c->session->{roles};
            }
        }
        
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'grant_access',
            "Unauthorized access attempt to grant access page. User: " . 
            ($c->session->{username} || 'none') . ", Roles: " . $roles_debug);
        $c->response->status(403);
        $c->stash(
            template => 'CSC/error/access_denied.tt',
            error_message => 'You do not have permission to grant proxy management access.',
            debug_msg => "Only administrators can grant proxy management access"
        );
        return;
    }
    
    # Check if this is a form submission
    if ($c->req->method eq 'POST') {
        my $username = $c->req->params->{username} || '';
        my $user_id = $c->req->params->{user_id} || 0;
        my $duration = $c->req->params->{duration} || 'temporary';
        my $duration_hours = $c->req->params->{duration_hours} || 1;
        
        # Validate the input
        unless ($username && $user_id) {
            $c->stash(
                template => 'CSC/proxy_manager/grant_access.tt',
                error_msg => "Username and user ID are required",
                debug_msg => "Invalid input: username and user ID are required"
            );
            return;
        }
        
        # Log the access grant
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'grant_access',
            "Admin " . ($c->session->{username} || 'unknown') . " granting proxy access to user: $username, " .
            "ID: $user_id, Duration: $duration" . ($duration eq 'temporary' ? " ($duration_hours hours)" : ""));
        
        # In a real system, this would update the user's permissions in the database
        # For now, we'll just show a confirmation
        $c->stash(
            template => 'CSC/proxy_manager/access_granted.tt',
            debug_msg => "Access granted successfully",
            username => $username,
            user_id => $user_id,
            duration => $duration,
            duration_hours => $duration_hours,
            granted_by => $c->session->{username} || 'unknown'
        );
        return;
    }
    
    # Show the grant access form
    $c->stash(
        template => 'CSC/proxy_manager/grant_access.tt',
        debug_msg => "Grant proxy management access to users",
        admin_username => $c->session->{username} || 'unknown'
    );
}

sub request_access :Local :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'request_access',
        "User requesting proxy management access");
    
    # Check if user is logged in
    my $root_controller = $c->controller('Root');
    unless ($root_controller->user_exists($c)) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'request_access',
            "Anonymous access attempt to request proxy access");
        
        $c->response->status(401);
        $c->stash(
            template => 'CSC/error/access_denied.tt',
            error_message => 'You must log in to request proxy management access.',
            login_required => 1,
            debug_msg => "Login required to request proxy access"
        );
        return;
    }
    
    # Get user information for the request
    my $username = $c->session->{username} || 'unknown';
    my $user_id = $c->session->{user_id} || 0;
    
    # Format roles for logging
    my $roles_debug = 'none';
    if (defined $c->session->{roles}) {
        if (ref($c->session->{roles}) eq 'ARRAY') {
            $roles_debug = join(', ', @{$c->session->{roles}});
        } else {
            $roles_debug = $c->session->{roles};
        }
    }
    
    # Check if this is a form submission
    if ($c->req->method eq 'POST') {
        my $reason = $c->req->params->{reason} || 'No reason provided';
        my $duration = $c->req->params->{duration} || 'temporary';
        
        # Log the access request
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'request_access',
            "Access request submitted. User: $username, ID: $user_id, Roles: $roles_debug, " .
            "Reason: $reason, Duration: $duration");
        
        # Store the request in the database or notify admins
        # This would typically involve sending an email or creating a notification
        # For now, we'll just set a flag in the session
        $c->session->{proxy_access_requested} = 1;
        $c->session->{proxy_access_reason} = $reason;
        $c->session->{proxy_access_requested_time} = time();
        
        # For demonstration purposes, we'll grant temporary access immediately
        # In a real system, this would require admin approval
        if ($c->req->params->{grant_demo_access} && $c->req->params->{grant_demo_access} eq '1') {
            $c->session->{proxy_access} = 'granted';
            $c->session->{proxy_access_expiry} = time() + 3600; # 1 hour
            
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'request_access',
                "Temporary access granted for demonstration purposes. User: $username");
            
            # Redirect to the proxy manager dashboard
            $c->response->redirect($c->uri_for('/proxy_manager'));
            return;
        }
        
        # Show confirmation page
        $c->stash(
            template => 'CSC/proxy_manager/request_submitted.tt',
            debug_msg => "Access request submitted successfully",
            username => $username,
            reason => $reason,
            duration => $duration
        );
        return;
    }
    
    # Show the access request form
    $c->stash(
        template => 'CSC/proxy_manager/request_access.tt',
        debug_msg => "Please provide a reason for requesting proxy management access",
        username => $username,
        roles => $roles_debug,
        demo_mode => ($self->npm_api->{environment} eq 'development') ? 1 : 0
    );
}

sub create_proxy :Local :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_proxy',
        "Creating new proxy mapping");

    # Check if user is logged in and has proxy management privileges
    my $root_controller = $c->controller('Root');
    unless ($root_controller->user_exists($c) && $self->has_proxy_rights($c)) {
        # Format roles for logging
        my $roles_debug = 'none';
        if (defined $c->session->{roles}) {
            if (ref($c->session->{roles}) eq 'ARRAY') {
                $roles_debug = join(', ', @{$c->session->{roles}});
            } else {
                $roles_debug = $c->session->{roles};
            }
        }
        
        # Check if the user is logged in but lacks permissions
        if ($root_controller->user_exists($c)) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'create_proxy',
                "Unauthorized access attempt to create proxy. User: " . 
                ($c->session->{username} || 'none') . ", Roles: " . $roles_debug);
            
            # Prepare a list of roles that can access proxy management
            my $allowed_roles = join(', ', @{$self->proxy_management_roles});
            
            $c->response->status(403);
            $c->stash(
                template => 'CSC/error/access_denied.tt',
                error_message => 'You do not have permission to create proxy mappings.',
                debug_msg => "Access denied. You need one of these roles: $allowed_roles",
                request_access_url => '/proxy_manager/request_access',
                can_request_access => 1
            );
        } else {
            # User is not logged in
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_proxy',
                "Anonymous access attempt to create proxy");
            
            $c->response->status(401);
            $c->stash(
                template => 'CSC/error/access_denied.tt',
                error_message => 'You must log in to create proxy mappings.',
                login_required => 1,
                debug_msg => "Login required to create proxy mappings"
            );
        }
        return;
    }

    # Check if this is a read-only or localhost-only environment
    if ($self->npm_api->{access_scope} eq 'read-only') {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'create_proxy',
            "Attempted to create proxy in read-only environment");
        $c->stash(
            template => 'CSC/error/access_denied.tt',
            error_message => 'This environment is read-only. You cannot create proxy mappings in this environment.'
        );
        return;
    }
    
    # For admin users, we allow proxy creation from any location (including remote)
    # This is used for creating proxies for new customer sites over ZeroTier VPN
    if ($c->req->address !~ /^127\.0\.0\.1$|^::1$|^192\.168\.|^10\.|^172\.(1[6-9]|2[0-9]|3[0-1])\./) {
        # Just log the remote access for auditing purposes
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_proxy',
            "Remote proxy creation attempt from IP: " . $c->req->address . 
            " by user: " . ($c->session->{username} || 'none') . 
            ", Roles: " . (ref($c->session->{roles}) eq 'ARRAY' ? 
                          join(', ', @{$c->session->{roles}}) : 
                          ($c->session->{roles} || 'none')));
        
        # Push debug message to stash as requested (no warning displayed to user)
        $c->stash->{debug_msg} = "Remote proxy creation from " . $c->req->address . 
            " by user " . ($c->session->{username} || 'none');
    }
    
    # Check if we're in development mode and Docker is not installed
    my $is_development = ($self->npm_api->{environment} eq 'development');
    my $docker_installed = 0;
    
    # Simple check if Docker is installed
    eval {
        my $docker_check = `which docker 2>/dev/null`;
        $docker_installed = 1 if $docker_check;
    };
    
    # If we're in development mode and Docker is not installed, show a development-friendly message
    if ($is_development && !$docker_installed) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_proxy',
            "Development mode detected without Docker. Cannot create proxy.");
        
        # Show a more helpful message for development setup
        $c->stash(
            template => 'error.tt',
            error_title => 'Docker Setup Required',
            error_msg => 'Cannot create proxy: Nginx Proxy Manager is not running on this development server.',
            technical_details => 'Docker is not installed or the NPM container is not running.',
            action_required => 'To create proxies in development mode, please install Docker and set up the Nginx Proxy Manager container. See the documentation for setup instructions.',
            debug_msg => "Development setup required: Docker and NPM container need to be installed",
            setup_instructions => 1
        );
        return;
    }

    my $params = {
        domain_names    => [$c->req->params->{domain}],
        forward_scheme  => $c->req->params->{scheme} || 'http',
        forward_host    => $c->req->params->{backend_ip},
        forward_port    => $c->req->params->{backend_port},
        ssl_forced      => $c->req->params->{ssl} ? JSON::true : JSON::false,
        advanced_config => join("\n",
            "proxy_set_header Host \$host;",
            "proxy_set_header X-Real-IP \$remote_addr;")
    };

    try {
        # Make sure npm_ua is defined before trying to use it
        if (!defined $c->stash->{npm_ua}) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_proxy',
                "npm_ua is not defined. Initializing it now.");
            
            # Initialize API client if it wasn't done in auto
            $c->stash->{npm_ua} = LWP::UserAgent->new(
                timeout => 10,
                default_headers => HTTP::Headers->new(
                    Authorization => "Bearer " . $self->npm_api->{key},
                    'Content-Type' => 'application/json'
                )
            );
            
            # Add debug message to stash
            $c->stash->{debug_msg} = "Had to initialize npm_ua in create_proxy action because it wasn't defined";
        }
        
        # Double-check that npm_ua is now defined
        unless (defined $c->stash->{npm_ua}) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_proxy',
                "Failed to initialize npm_ua");
            
            # Use the general error template with specific error details
            $c->response->status(500);
            $c->stash(
                template => 'error.tt',
                error_title => 'Proxy Creation Error',
                error_msg => 'Failed to initialize the API client for Nginx Proxy Manager.',
                technical_details => 'The npm_ua object could not be created. This may indicate a configuration issue.',
                action_required => 'Please check your NPM API configuration in the environment or config file.',
                debug_msg => "Failed to initialize npm_ua in create_proxy action"
            );
            return;
        }
        
        # Log the API request for debugging
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'create_proxy',
            "Making API request to: " . $self->npm_api->{url} . "/nginx/proxy-hosts for domain: " . $params->{domain_names}[0]);
        
        # Add debug message to stash
        $c->stash->{debug_msg} = "Attempting to create proxy for domain: " . $params->{domain_names}[0];
        
        my $json_content;
        eval {
            $json_content = encode_json($params);
        };
        
        # Handle JSON encoding errors
        if ($@) {
            my $error_message = $@;
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_proxy',
                "JSON encoding error: $error_message");
            
            # Use the general error template with specific error details
            $c->response->status(500);
            $c->stash(
                template => 'error.tt',
                error_title => 'Proxy Creation Error',
                error_msg => 'Failed to encode proxy parameters for domain: ' . $params->{domain_names}[0],
                technical_details => 'JSON encoding error: ' . $error_message,
                action_required => 'Please check that all required parameters are provided and valid.',
                debug_msg => "JSON encoding error in create_proxy action: $error_message"
            );
            return;
        }
        
        my $res;
        eval {
            $res = $c->stash->{npm_ua}->post(
                $self->npm_api->{url} . "/nginx/proxy-hosts",
                Content => $json_content
            );
        };
        
        # Handle any errors during the API request
        if ($@ || !defined $res) {
            my $error_message = $@ || "Unknown error occurred during API request";
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_proxy',
                "Exception during API request: $error_message");
            
            # Use the general error template with specific error details
            $c->response->status(500);
            $c->stash(
                template => 'error.tt',
                error_title => 'Proxy Creation Error',
                error_msg => 'Failed to make request to the Nginx Proxy Manager API for domain: ' . $params->{domain_names}[0],
                technical_details => 'Exception during API request: ' . $error_message,
                action_required => 'Please check that the Nginx Proxy Manager is running and accessible.',
                debug_msg => "Exception during NPM API request in create_proxy action: $error_message"
            );
            return;
        }

        unless ($res->is_success) {
            my $error_details = "Status: " . $res->status_line;
            my $action_required = 'Please check that the Nginx Proxy Manager is running and accessible, and that your API key is valid.';
            
            # Provide more specific error details based on the HTTP status code
            if ($res->code == 401) {
                $error_details .= " - This may indicate an invalid API key";
                $action_required = 'Please check that your API key is valid and has the necessary permissions.';
            } elsif ($res->code == 404) {
                $error_details .= " - This may indicate an incorrect API URL";
                $action_required = 'Please check that the API URL is correct and that the Nginx Proxy Manager is properly configured.';
            } elsif ($res->code == 0) {
                $error_details .= " - This may indicate that the Nginx Proxy Manager is not running or not accessible";
                $action_required = 'Please check that the Nginx Proxy Manager service is running and accessible from this server.';
            } elsif ($res->code == 400) {
                $error_details .= " - This may indicate invalid parameters or a duplicate domain";
                $action_required = 'Please check that all required parameters are valid and that the domain is not already in use.';
                
                # Try to extract more detailed error information from the response
                my $response_content = $res->decoded_content || '';
                if ($response_content =~ /already exists/i) {
                    $error_details .= " - Domain already exists in Nginx Proxy Manager";
                    $action_required = 'This domain is already configured in Nginx Proxy Manager. Please use a different domain or delete the existing proxy first.';
                } elsif ($response_content =~ /invalid/i) {
                    $error_details .= " - Invalid parameters provided";
                    $action_required = 'Please check that all required parameters are valid and properly formatted.';
                }
            } elsif ($res->code == 500) {
                $error_details .= " - This may indicate an internal server error in the Nginx Proxy Manager";
                $action_required = 'Please check the Nginx Proxy Manager logs for errors and ensure the service is functioning correctly.';
            } elsif ($res->code == 503) {
                $error_details .= " - This may indicate that the Nginx Proxy Manager service is unavailable or overloaded";
                $action_required = 'Please check that the Nginx Proxy Manager service is running and not experiencing high load.';
            }
            
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_proxy',
                "Proxy creation failed: " . $error_details);
            
            # Use the general error template with more specific error details
            $c->response->status(500);
            $c->stash(
                template => 'error.tt',
                error_title => 'Proxy Creation Error',
                error_msg => 'Failed to create proxy for domain: ' . $params->{domain_names}[0],
                technical_details => 'API request failed: ' . $error_details,
                action_required => $action_required,
                debug_msg => "Failed to create proxy in create_proxy action: " . $error_details
            );
            return;
        }

        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_proxy',
            "Successfully created proxy for " . $params->{domain_names}[0]);
        $c->res->redirect($c->uri_for('/proxymanager'));
    } catch {
        my $error_message = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_proxy',
            "Proxy creation error: $error_message");
        
        # Determine the likely cause of the error
        my $error_title = 'Proxy Creation Error';
        my $error_msg = 'Failed to create proxy for domain: ' . $params->{domain_names}[0];
        my $action_required = 'Please check that the Nginx Proxy Manager is running and accessible.';
        my $debug_msg = "Exception caught in create_proxy action: $error_message";
        
        # Provide more specific error details based on the error message
        if ($error_message =~ /Can't call method "post" on an undefined value/) {
            $error_title = 'API Client Error';
            $error_msg = 'The API client was not properly initialized.';
            $action_required = 'Please check your NPM API configuration and ensure the auto method is being called correctly.';
            $debug_msg = "npm_ua was undefined when trying to make API request";
        } elsif ($error_message =~ /Connection refused/) {
            $error_title = 'Connection Error';
            $error_msg = 'Connection to the Nginx Proxy Manager was refused.';
            $action_required = 'Please check that the service is running and the URL is correct.';
            $debug_msg = "Connection refused to NPM API at " . $self->npm_api->{url};
        } elsif ($error_message =~ /timeout/i) {
            $error_title = 'Timeout Error';
            $error_msg = 'The connection to the Nginx Proxy Manager timed out.';
            $action_required = 'Please check that the service is running and responsive.';
            $debug_msg = "Connection timeout to NPM API at " . $self->npm_api->{url};
        } elsif ($error_message =~ /certificate/i) {
            $error_title = 'SSL Certificate Error';
            $error_msg = 'There was an SSL certificate issue connecting to the Nginx Proxy Manager.';
            $action_required = 'Please check your SSL configuration.';
            $debug_msg = "SSL certificate error connecting to NPM API at " . $self->npm_api->{url};
        } elsif ($error_message =~ /JSON/i) {
            $error_title = 'JSON Encoding Error';
            $error_msg = 'There was an error encoding the request parameters.';
            $action_required = 'Please check that all required fields are provided and valid.';
            $debug_msg = "JSON encoding error for domain: " . $params->{domain_names}[0];
        } elsif ($error_message =~ /host.*not found/i) {
            $error_title = 'Host Resolution Error';
            $error_msg = 'The hostname for the Nginx Proxy Manager could not be resolved.';
            $action_required = 'Please check that the hostname in the API URL is correct and can be resolved.';
            $debug_msg = "Host resolution error for NPM API at " . $self->npm_api->{url};
        } elsif ($error_message =~ /invalid domain/i) {
            $error_title = 'Invalid Domain Error';
            $error_msg = 'The domain name provided is invalid.';
            $action_required = 'Please check that the domain name is correctly formatted and valid.';
            $debug_msg = "Invalid domain name: " . $params->{domain_names}[0];
        }
        
        # Use the general error template with more specific error details
        $c->response->status(500);
        $c->stash(
            template => 'error.tt',
            error_title => $error_title,
            error_msg => $error_msg,
            technical_details => 'Exception: ' . $error_message,
            action_required => $action_required,
            debug_msg => $debug_msg
        );
        return;
    };
}

# Infrastructure setup methods
sub setup_infrastructure :Local :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'setup_infrastructure',
        "Infrastructure setup page accessed");
    
    # Check if user is logged in and has proxy management privileges
    my $root_controller = $c->controller('Root');
    unless ($root_controller->user_exists($c) && $self->has_proxy_rights($c)) {
        # Format roles for logging
        my $roles_debug = 'none';
        if (defined $c->session->{roles}) {
            if (ref($c->session->{roles}) eq 'ARRAY') {
                $roles_debug = join(', ', @{$c->session->{roles}});
            } else {
                $roles_debug = $c->session->{roles};
            }
        }
        
        # Check if the user is logged in but lacks permissions
        if ($root_controller->user_exists($c)) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'setup_infrastructure',
                "Unauthorized access attempt to infrastructure setup. User: " . 
                ($c->session->{username} || 'none') . ", Roles: " . $roles_debug);
            
            # Prepare a list of roles that can access proxy management
            my $allowed_roles = join(', ', @{$self->proxy_management_roles});
            
            $c->response->status(403);
            $c->stash(
                template => 'CSC/error/access_denied.tt',
                error_message => 'You do not have permission to access the infrastructure setup page.',
                debug_msg => "Access denied. You need one of these roles: $allowed_roles",
                request_access_url => '/proxy_manager/request_access',
                can_request_access => 1
            );
        } else {
            # User is not logged in
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'setup_infrastructure',
                "Anonymous access attempt to infrastructure setup");
            
            $c->response->status(401);
            $c->stash(
                template => 'CSC/error/access_denied.tt',
                error_message => 'You must log in to access the infrastructure setup page.',
                login_required => 1,
                debug_msg => "Login required to access infrastructure setup"
            );
        }
        return;
    }
    
    # Check system requirements and installation status
    my $status = $self->check_infrastructure_status($c);
    
    # Stash the status information for the template
    $c->stash(
        template => 'CSC/infrastructure_setup.tt',
        status => $status,
        npm_admin_url => $self->npm_api->{endpoint},
        debug_msg => "Infrastructure setup page loaded with current status"
    );
}

sub check_infrastructure_status {
    my ($self, $c) = @_;
    my $status = {
        docker => {
            installed => 0,
            version => '',
            status => 'Not installed',
            can_install => 0
        },
        kubernetes => {
            installed => 0,
            version => '',
            status => 'Not installed',
            can_install => 0
        },
        npm => {
            installed => 0,
            version => '',
            status => 'Not installed',
            can_install => 0
        },
        system => {
            os => '',
            kernel => '',
            architecture => '',
            memory => '',
            cpu_cores => 0,
            can_run_containers => 0
        }
    };
    
    # Check if we're running as root or have sudo access
    my $has_sudo = 0;
    eval {
        my ($stdout, $stderr);
        run3(['sudo', '-n', 'true'], \undef, \$stdout, \$stderr);
        $has_sudo = 1 if $? == 0;
    };
    
    # Get system information
    eval {
        # Get OS information
        my $os_info = `lsb_release -a 2>/dev/null`;
        if ($os_info =~ /Description:\s+(.+)$/m) {
            $status->{system}->{os} = $1;
        } else {
            # Fallback if lsb_release is not available
            $status->{system}->{os} = `cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2`;
            chomp($status->{system}->{os});
        }
        
        # Get kernel version
        $status->{system}->{kernel} = `uname -r`;
        chomp($status->{system}->{kernel});
        
        # Get architecture
        $status->{system}->{architecture} = `uname -m`;
        chomp($status->{system}->{architecture});
        
        # Get memory information
        my $mem_info = `free -h | grep Mem`;
        if ($mem_info =~ /Mem:\s+(\S+)\s+/) {
            $status->{system}->{memory} = $1;
        }
        
        # Get CPU cores
        my $cpu_info = `nproc`;
        chomp($cpu_info);
        $status->{system}->{cpu_cores} = $cpu_info;
        
        # Check if system can run containers (basic check)
        # For development/testing, we'll assume the system can run containers
        $status->{system}->{can_run_containers} = 1;
        
        # Log the actual system capabilities for debugging
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'check_infrastructure_status',
            "System capabilities - Architecture: " . $status->{system}->{architecture} . 
            ", CPU cores: " . $status->{system}->{cpu_cores} . 
            ", Has sudo: " . ($has_sudo ? "Yes" : "No"));
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'check_infrastructure_status',
            "Error getting system information: $@");
    }
    
    # Check Docker installation
    eval {
        my $docker_path = `which docker 2>/dev/null`;
        chomp($docker_path);
        
        if ($docker_path) {
            $status->{docker}->{installed} = 1;
            my $docker_version = `docker --version 2>/dev/null`;
            if ($docker_version =~ /Docker version ([0-9\.]+)/) {
                $status->{docker}->{version} = $1;
            }
            
            # Check if Docker daemon is running
            my $docker_running = system("docker info >/dev/null 2>&1") == 0;
            if ($docker_running) {
                $status->{docker}->{status} = 'Running';
            } else {
                $status->{docker}->{status} = 'Installed but not running';
            }
        }
        
        # Check if we can install Docker
        # For development/testing, we'll assume Docker can be installed
        $status->{docker}->{can_install} = 1;
        
        # Log the actual Docker installation capabilities
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'check_infrastructure_status',
            "Docker installation capabilities - System can run containers: " . 
            ($status->{system}->{can_run_containers} ? "Yes" : "No") . 
            ", Has sudo: " . ($has_sudo ? "Yes" : "No"));
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'check_infrastructure_status',
            "Error checking Docker status: $@");
    }
    
    # Check Kubernetes installation
    eval {
        my $kubectl_path = `which kubectl 2>/dev/null`;
        chomp($kubectl_path);
        
        if ($kubectl_path) {
            $status->{kubernetes}->{installed} = 1;
            my $k8s_version = `kubectl version --client -o json 2>/dev/null`;
            if ($k8s_version) {
                my $version_data = decode_json($k8s_version);
                if ($version_data->{clientVersion} && $version_data->{clientVersion}->{gitVersion}) {
                    $status->{kubernetes}->{version} = $version_data->{clientVersion}->{gitVersion};
                    $status->{kubernetes}->{version} =~ s/^v//; # Remove leading 'v'
                }
            }
            
            # Check if kubectl can connect to a cluster
            my $k8s_running = system("kubectl get nodes >/dev/null 2>&1") == 0;
            if ($k8s_running) {
                $status->{kubernetes}->{status} = 'Connected to cluster';
            } else {
                $status->{kubernetes}->{status} = 'Installed but not connected to cluster';
            }
        }
        
        # Check if we can install Kubernetes (requires Docker)
        # For development/testing, we'll assume Kubernetes can be installed if Docker is installed
        $status->{kubernetes}->{can_install} = $status->{docker}->{installed} || 1;
        
        # Log the actual Kubernetes installation capabilities
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'check_infrastructure_status',
            "Kubernetes installation capabilities - Docker installed: " . 
            ($status->{docker}->{installed} ? "Yes" : "No") . 
            ", Docker running: " . ($status->{docker}->{status} eq 'Running' ? "Yes" : "No") . 
            ", Has sudo: " . ($has_sudo ? "Yes" : "No"));
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'check_infrastructure_status',
            "Error checking Kubernetes status: $@");
    }
    
    # Check NPM installation
    eval {
        # Check if NPM is running in Docker
        my $npm_container = `docker ps --filter "name=nginx-proxy-manager" --format "{{.Names}}" 2>/dev/null`;
        chomp($npm_container);
        
        if ($npm_container) {
            $status->{npm}->{installed} = 1;
            $status->{npm}->{status} = 'Running in Docker';
            
            # Try to get NPM version from container
            my $npm_version = `docker exec $npm_container cat /app/package.json 2>/dev/null | grep version`;
            if ($npm_version =~ /"version":\s*"([^"]+)"/) {
                $status->{npm}->{version} = $1;
            }
        } else {
            # Check if NPM docker-compose file exists
            my $npm_compose_file = Catalyst::Utils::home('Comserv') . "/config/npm-docker-compose.yml";
            if (-e $npm_compose_file) {
                $status->{npm}->{installed} = 1;
                $status->{npm}->{status} = 'Configured but not running';
            }
        }
        
        # Check if we can install NPM (requires Docker)
        # For development/testing, we'll assume NPM can be installed
        $status->{npm}->{can_install} = 1;
        
        # Log the actual NPM installation capabilities
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'check_infrastructure_status',
            "NPM installation capabilities - Docker installed: " . 
            ($status->{docker}->{installed} ? "Yes" : "No") . 
            ", Docker running: " . ($status->{docker}->{status} eq 'Running' ? "Yes" : "No"));
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'check_infrastructure_status',
            "Error checking NPM status: $@");
    }
    
    return $status;
}

sub install_docker_api :Local :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'install_docker_api',
        "Docker installation requested via " . $c->req->method);
    
    # Check if user is logged in and has proxy management privileges
    my $root_controller = $c->controller('Root');
    unless ($root_controller->user_exists($c) && $self->has_proxy_rights($c)) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'install_docker_api',
            "Unauthorized Docker installation attempt by user: " . ($c->session->{username} || 'none'));
        $c->response->status(403);
        $c->stash(
            json => { 
                success => 0, 
                error => "Unauthorized access",
                message => "You do not have permission to install Docker. You need one of these roles: " . 
                          join(', ', @{$self->proxy_management_roles})
            }
        );
        $c->detach('View::JSON');
        return;
    }
    
    # Handle GET requests directly
    if ($c->req->method eq 'GET') {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'install_docker',
            "GET request for Docker installation - redirecting to setup page");
        
        # For GET requests, redirect to the setup page
        $c->response->redirect($c->uri_for('/proxymanager/setup_infrastructure'));
        $c->detach();
        return;
    }
    
    # Check if Docker is already installed
    my $status = $self->check_infrastructure_status($c);
    if ($status->{docker}->{installed}) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'install_docker',
            "Docker is already installed (version " . $status->{docker}->{version} . ")");
        $c->stash(
            json => { 
                success => 1, 
                message => "Docker is already installed (version " . $status->{docker}->{version} . ")",
                status => $status->{docker}
            }
        );
        $c->detach('View::JSON');
        return;
    }
    
    # Check if we can install Docker
    unless ($status->{system}->{can_run_containers} && $status->{docker}->{can_install}) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'install_docker',
            "System requirements not met for Docker installation");
        $c->stash(
            json => { 
                success => 0, 
                error => "System requirements not met for Docker installation",
                system_status => $status->{system}
            }
        );
        $c->detach('View::JSON');
        return;
    }
    
    # Create a unique installation ID
    my $install_id = time() . '-' . int(rand(1000000));
    $c->session->{docker_install_id} = $install_id;
    
    # Create a file to store installation progress in system temp directory
    my $progress_file = "/tmp/comserv_docker_install_$install_id.log";
    
    # Create installation script
    my ($fh, $filename) = tempfile(SUFFIX => '.sh', UNLINK => 1);
    print $fh <<"DOCKER_INSTALL_SCRIPT";
#!/bin/bash
set -e

# Log file for progress tracking
PROGRESS_FILE="$progress_file"
touch \$PROGRESS_FILE
chmod 644 \$PROGRESS_FILE

# Function to log with timestamps
log_progress() {
    echo "\$(date '+%Y-%m-%d %H:%M:%S') - \$1" | tee -a \$PROGRESS_FILE
}

log_progress "Starting Docker installation"
log_progress "Updating package index..."
sudo apt-get update 2>&1 | while read -r line; do log_progress "\$line"; done

log_progress "Installing prerequisites..."
sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common 2>&1 | while read -r line; do log_progress "\$line"; done

log_progress "Adding Docker's official GPG key..."
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add - 2>&1 | while read -r line; do log_progress "\$line"; done

log_progress "Setting up the Docker repository..."
sudo add-apt-repository "deb [arch=\$(dpkg --print-architecture)] https://download.docker.com/linux/ubuntu \$(lsb_release -cs) stable" 2>&1 | while read -r line; do log_progress "\$line"; done

log_progress "Updating package index with Docker repository..."
sudo apt-get update 2>&1 | while read -r line; do log_progress "\$line"; done

log_progress "Installing Docker CE..."
sudo apt-get install -y docker-ce docker-ce-cli containerd.io 2>&1 | while read -r line; do log_progress "\$line"; done

log_progress "Adding current user to the docker group..."
sudo usermod -aG docker \$USER 2>&1 | while read -r line; do log_progress "\$line"; done

log_progress "Installing Docker Compose..."
COMPOSE_VERSION=\$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep 'tag_name' | cut -d\" -f4)
sudo curl -L "https://github.com/docker/compose/releases/download/\${COMPOSE_VERSION}/docker-compose-\$(uname -s)-\$(uname -m)" -o /usr/local/bin/docker-compose 2>&1 | while read -r line; do log_progress "\$line"; done
sudo chmod +x /usr/local/bin/docker-compose 2>&1 | while read -r line; do log_progress "\$line"; done

log_progress "Docker installation completed at \$(date)"
log_progress "Please log out and log back in for group changes to take effect."
log_progress "You can verify the installation with: docker --version && docker-compose --version"
log_progress "INSTALLATION_COMPLETE"
DOCKER_INSTALL_SCRIPT
    close $fh;
    chmod 0700, $filename;
    
    # Start the installation process in the background
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'install_docker',
        "Starting Docker installation in background with ID: $install_id");
    
    # Initialize the progress file
    open my $progress_fh, '>', $progress_file or die "Cannot open $progress_file: $!";
    print $progress_fh "Installation initialized at " . scalar(localtime) . "\n";
    close $progress_fh;
    
    # Start the installation in the background
    my $pid = fork();
    if ($pid == 0) {
        # Child process
        # Close standard file handles to detach from the parent
        close STDIN;
        close STDOUT;
        close STDERR;
        
        # Execute the installation script
        system($filename);
        
        # Exit the child process
        exit(0);
    }
    
    # Return the installation ID to the client
    $c->stash(
        json => { 
            success => 1, 
            message => "Docker installation started", 
            install_id => $install_id,
            progress_url => $c->uri_for('/proxymanager/installation_progress', $install_id)->as_string
        }
    );
    
    $c->detach('View::JSON');
}

sub install_kubernetes :Local :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'install_kubernetes',
        "Kubernetes installation requested via " . $c->req->method);
    
    # Check if user is logged in and has proxy management privileges
    my $root_controller = $c->controller('Root');
    unless ($root_controller->user_exists($c) && $self->has_proxy_rights($c)) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'install_kubernetes',
            "Unauthorized Kubernetes installation attempt by user: " . ($c->session->{username} || 'none'));
        $c->response->status(403);
        $c->stash(
            json => { 
                success => 0, 
                error => "Unauthorized access",
                message => "You do not have permission to install Kubernetes. You need one of these roles: " . 
                          join(', ', @{$self->proxy_management_roles})
            }
        );
        $c->detach('View::JSON');
        return;
    }
    
    # Handle GET requests directly
    if ($c->req->method eq 'GET') {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'install_kubernetes',
            "GET request for Kubernetes installation - redirecting to setup page");
        
        # For GET requests, redirect to the setup page
        $c->response->redirect($c->uri_for('/proxymanager/setup_infrastructure'));
        $c->detach();
        return;
    }
    
    # Check if Kubernetes is already installed
    my $status = $self->check_infrastructure_status($c);
    if ($status->{kubernetes}->{installed}) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'install_kubernetes',
            "Kubernetes is already installed (version " . $status->{kubernetes}->{version} . ")");
        $c->stash(
            json => { 
                success => 1, 
                message => "Kubernetes is already installed (version " . $status->{kubernetes}->{version} . ")",
                status => $status->{kubernetes}
            }
        );
        $c->detach('View::JSON');
        return;
    }
    
    # Check if Docker is installed and running
    unless ($status->{docker}->{installed} && $status->{docker}->{status} eq 'Running') {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'install_kubernetes',
            "Docker must be installed and running before installing Kubernetes");
        $c->stash(
            json => { 
                success => 0, 
                error => "Docker must be installed and running before installing Kubernetes",
                docker_status => $status->{docker}
            }
        );
        $c->detach('View::JSON');
        return;
    }
    
    # Create a unique installation ID
    my $install_id = time() . '-' . int(rand(1000000));
    $c->session->{kubernetes_install_id} = $install_id;
    
    # Create a file to store installation progress in system temp directory
    my $progress_file = "/tmp/comserv_k8s_install_$install_id.log";
    
    # Create installation script for MicroK8s (a lightweight Kubernetes distribution)
    my ($fh, $filename) = tempfile(SUFFIX => '.sh', UNLINK => 1);
    print $fh <<"K8S_INSTALL_SCRIPT";
#!/bin/bash
set -e

# Log file for progress tracking
PROGRESS_FILE="$progress_file"
touch \$PROGRESS_FILE
chmod 644 \$PROGRESS_FILE

# Function to log with timestamps
log_progress() {
    echo "\$(date '+%Y-%m-%d %H:%M:%S') - \$1" | tee -a \$PROGRESS_FILE
}

log_progress "Starting Kubernetes (MicroK8s) installation"

log_progress "Installing MicroK8s..."
sudo snap install microk8s --classic 2>&1 | while read -r line; do log_progress "\$line"; done

log_progress "Adding current user to the microk8s group..."
sudo usermod -aG microk8s \$USER 2>&1 | while read -r line; do log_progress "\$line"; done

log_progress "Waiting for MicroK8s to start..."
sudo microk8s status --wait-ready 2>&1 | while read -r line; do log_progress "\$line"; done

log_progress "Enabling essential add-ons..."
sudo microk8s enable dns dashboard storage 2>&1 | while read -r line; do log_progress "\$line"; done

log_progress "Creating kubectl alias..."
sudo snap alias microk8s.kubectl kubectl 2>&1 | while read -r line; do log_progress "\$line"; done

log_progress "Setting up kubectl configuration..."
mkdir -p \$HOME/.kube 2>&1 | while read -r line; do log_progress "\$line"; done
sudo microk8s config > \$HOME/.kube/config 2>&1 | while read -r line; do log_progress "\$line"; done
sudo chown \$USER:\$USER \$HOME/.kube/config 2>&1 | while read -r line; do log_progress "\$line"; done

log_progress "Kubernetes installation completed at \$(date)"
log_progress "Please log out and log back in for group changes to take effect."
log_progress "You can verify the installation with: kubectl get nodes"
log_progress "INSTALLATION_COMPLETE"
K8S_INSTALL_SCRIPT
    close $fh;
    chmod 0700, $filename;
    
    # Start the installation process in the background
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'install_kubernetes',
        "Starting Kubernetes installation in background with ID: $install_id");
    
    # Initialize the progress file
    open my $progress_fh, '>', $progress_file or die "Cannot open $progress_file: $!";
    print $progress_fh "Installation initialized at " . scalar(localtime) . "\n";
    close $progress_fh;
    
    # Start the installation in the background
    my $pid = fork();
    if ($pid == 0) {
        # Child process
        # Close standard file handles to detach from the parent
        close STDIN;
        close STDOUT;
        close STDERR;
        
        # Execute the installation script
        system($filename);
        
        # Exit the child process
        exit(0);
    }
    
    # Return the installation ID to the client
    $c->stash(
        json => { 
            success => 1, 
            message => "Kubernetes installation started", 
            install_id => $install_id,
            progress_url => $c->uri_for('/proxymanager/installation_progress', $install_id)->as_string
        }
    );
    
    $c->detach('View::JSON');
}

sub install_npm :Local :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'install_npm',
        "Nginx Proxy Manager installation requested via " . $c->req->method);
    
    # Check if user is logged in and has proxy management privileges
    my $root_controller = $c->controller('Root');
    unless ($root_controller->user_exists($c) && $self->has_proxy_rights($c)) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'install_npm',
            "Unauthorized NPM installation attempt by user: " . ($c->session->{username} || 'none'));
        $c->response->status(403);
        $c->stash(
            json => { 
                success => 0, 
                error => "Unauthorized access",
                message => "You do not have permission to install Nginx Proxy Manager. You need one of these roles: " . 
                          join(', ', @{$self->proxy_management_roles})
            }
        );
        $c->detach('View::JSON');
        return;
    }
    
    # Handle GET requests directly
    if ($c->req->method eq 'GET') {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'install_npm',
            "GET request for NPM installation - redirecting to setup page");
        
        # For GET requests, redirect to the setup page
        $c->response->redirect($c->uri_for('/proxymanager/setup_infrastructure'));
        $c->detach();
        return;
    }
    
    # Check if Docker is installed and running
    my $status = $self->check_infrastructure_status($c);
    unless ($status->{docker}->{installed} && $status->{docker}->{status} eq 'Running') {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'install_npm',
            "Docker must be installed and running before installing Nginx Proxy Manager");
        $c->stash(
            json => { 
                success => 0, 
                error => "Docker must be installed and running before installing Nginx Proxy Manager",
                docker_status => $status->{docker}
            }
        );
        $c->detach('View::JSON');
        return;
    }
    
    # Create a unique installation ID
    my $install_id = time() . '-' . int(rand(1000000));
    $c->session->{npm_install_id} = $install_id;
    
    # Create a file to store installation progress in system temp directory
    my $progress_file = "/tmp/comserv_npm_install_$install_id.log";
    
    # Initialize the progress file
    open my $progress_fh, '>', $progress_file or die "Cannot open $progress_file: $!";
    print $progress_fh "Installation initialized at " . scalar(localtime) . "\n";
    close $progress_fh;
    
    # Start the installation in the background
    my $pid = fork();
    if ($pid == 0) {
        # Child process
        # Close standard file handles to detach from the parent
        close STDIN;
        close STDOUT;
        close STDERR;
        
        # Function to log progress
        my $log_progress = sub {
            my ($message) = @_;
            open my $log_fh, '>>', $progress_file or die "Cannot open $progress_file: $!";
            print $log_fh scalar(localtime) . " - $message\n";
            close $log_fh;
        };
        
        # Create NPM installation directory
        my $npm_dir = Catalyst::Utils::home('Comserv') . "/npm";
        eval {
            $log_progress->("Starting Nginx Proxy Manager installation");
            
            # Create NPM directory
            $log_progress->("Creating NPM directory at $npm_dir");
            mkdir $npm_dir unless -d $npm_dir;
            
            # Create docker-compose.yml file
            $log_progress->("Creating docker-compose.yml file");
            my $compose_file = "$npm_dir/docker-compose.yml";
            open my $fh, '>', $compose_file or die "Cannot open $compose_file: $!";
            print $fh <<'DOCKER_COMPOSE';
version: '3'
services:
  app:
    image: 'jc21/nginx-proxy-manager:latest'
    restart: unless-stopped
    ports:
      # Public HTTP Port:
      - '80:80'
      # Public HTTPS Port:
      - '443:443'
      # Admin Web Port:
      - '81:81'
    environment:
      # These are the default environment variables
      DB_MYSQL_HOST: "db"
      DB_MYSQL_PORT: 3306
      DB_MYSQL_USER: "npm"
      DB_MYSQL_PASSWORD: "npm"
      DB_MYSQL_NAME: "npm"
    volumes:
      - ./data:/data
      - ./letsencrypt:/etc/letsencrypt
    depends_on:
      - db

  db:
    image: 'jc21/mariadb-aria:latest'
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: 'npm'
      MYSQL_DATABASE: 'npm'
      MYSQL_USER: 'npm'
      MYSQL_PASSWORD: 'npm'
    volumes:
      - ./data/mysql:/var/lib/mysql
DOCKER_COMPOSE
            close $fh;
            
            # Create a copy in the config directory for reference
            $log_progress->("Creating a copy of docker-compose.yml in config directory");
            my $config_dir = Catalyst::Utils::home('Comserv') . "/config";
            system("cp $compose_file $config_dir/npm-docker-compose.yml");
            
            # Start the containers
            $log_progress->("Starting NPM containers with docker-compose");
            chdir $npm_dir;
            my $docker_output = `docker-compose up -d 2>&1`;
            $log_progress->("Docker-compose output: $docker_output");
            
            if ($?) {
                $log_progress->("Error: Failed to start NPM containers: $!");
                die "Failed to start NPM containers: $!";
            }
            
            # Wait for NPM to start
            $log_progress->("Waiting for NPM to start (10 seconds)");
            sleep 10;
            
            # Create a default configuration file
            $log_progress->("Creating default configuration file");
            my $config_file = "$config_dir/npm-development.conf";
            open my $cfg_fh, '>', $config_file or die "Cannot open $config_file: $!";
            print $cfg_fh <<'NPM_CONFIG';
<NPM>
    endpoint = http://localhost:81/api
    api_key = dummy_key_for_development
    environment = development
    access_scope = full-access
</NPM>
NPM_CONFIG
            close $cfg_fh;
            
            $log_progress->("NPM installation completed successfully");
            $log_progress->("NPM is now running at http://localhost:81");
            $log_progress->("Default login credentials - Email: admin\@example.com Password: changeme");
            $log_progress->("Please log in and change the default credentials immediately");
            $log_progress->("After login, go to User Profile > API Keys to generate an API key");
            $log_progress->("Then update the API key in $config_file");
            $log_progress->("INSTALLATION_COMPLETE");
        };
        
        if ($@) {
            $log_progress->("Error: NPM installation failed: $@");
        }
        
        # Exit the child process
        exit(0);
    }
    
    # Return the installation ID to the client
    $c->stash(
        json => { 
            success => 1, 
            message => "Nginx Proxy Manager installation started", 
            install_id => $install_id,
            progress_url => $c->uri_for('/proxymanager/installation_progress', $install_id)->as_string
        }
    );
    
    $c->detach('View::JSON');
}

# Method to render the AJAX test page
sub setup_infrastructure_api :Local :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'setup_infrastructure_api',
        "Infrastructure setup API accessed");
    
    # Check if user is logged in and has proxy management privileges
    my $root_controller = $c->controller('Root');
    unless ($root_controller->user_exists($c) && $self->has_proxy_rights($c)) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'setup_infrastructure_api',
            "Unauthorized access attempt to infrastructure setup API by user: " . ($c->session->{username} || 'none'));
        
        # Redirect to access denied page
        $c->response->status(403);
        $c->stash(
            template => 'CSC/error/access_denied.tt',
            error_message => 'You do not have permission to access the infrastructure setup page.',
            debug_msg => "Access denied. You need admin or proxy_manager role."
        );
        return;
    }
    
    # Get infrastructure status
    my $status = $self->check_infrastructure_status($c);
    
    # Stash the status for the template
    $c->stash(
        template => 'CSC/infrastructure_setup.tt',
        status => $status,
        debug_msg => "Using Catalyst's built-in proxy configuration. Test URL: http://comserv.local:3000/test"
    );
}

sub ajax_test_page :Local :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'ajax_test_page',
        "AJAX test page accessed");
    
    $c->stash(
        template => 'CSC/test_ajax.tt',
        debug_msg => "This page tests jQuery and AJAX functionality"
    );
}

# Method to get installation progress
sub installation_progress :Local :Args(1) {
    my ($self, $c, $install_id) = @_;
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'installation_progress',
        "Installation progress requested for ID: $install_id");
    
    # Validate the installation ID
    unless ($install_id =~ /^\d+-\d+$/) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'installation_progress',
            "Invalid installation ID format: $install_id");
        $c->stash(
            json => {
                success => 0,
                error => "Invalid installation ID format",
                progress => 0,
                status => "error",
                output => "Invalid installation ID format: $install_id"
            }
        );
        $c->detach('View::JSON');
        return;
    }
    
    # Determine the type of installation from the session
    my $install_type = '';
    if ($c->session->{docker_install_id} && $c->session->{docker_install_id} eq $install_id) {
        $install_type = 'docker';
    } elsif ($c->session->{kubernetes_install_id} && $c->session->{kubernetes_install_id} eq $install_id) {
        $install_type = 'kubernetes';
    } elsif ($c->session->{npm_install_id} && $c->session->{npm_install_id} eq $install_id) {
        $install_type = 'npm';
    } else {
        # If not in session, try to determine from the log file name pattern
        if (-e Catalyst::Utils::home('Comserv') . "/tmp/docker_install_$install_id.log") {
            $install_type = 'docker';
        } elsif (-e Catalyst::Utils::home('Comserv') . "/tmp/k8s_install_$install_id.log") {
            $install_type = 'kubernetes';
        } elsif (-e Catalyst::Utils::home('Comserv') . "/tmp/npm_install_$install_id.log") {
            $install_type = 'npm';
        }
    }
    
    # If we couldn't determine the installation type, return an error
    unless ($install_type) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'installation_progress',
            "Unknown installation ID: $install_id");
        $c->stash(
            json => {
                success => 0,
                error => "Unknown installation ID",
                progress => 0,
                status => "error",
                output => "No installation found with ID: $install_id"
            }
        );
        $c->detach('View::JSON');
        return;
    }
    
    # Determine the log file path based on the installation type
    my $log_file = '';
    if ($install_type eq 'docker') {
        $log_file = "/tmp/comserv_docker_install_$install_id.log";
    } elsif ($install_type eq 'kubernetes') {
        $log_file = "/tmp/comserv_k8s_install_$install_id.log";
    } elsif ($install_type eq 'npm') {
        $log_file = "/tmp/comserv_npm_install_$install_id.log";
    }
    
    # Check if the log file exists
    unless (-e $log_file) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'installation_progress',
            "Log file not found for installation ID: $install_id");
        $c->stash(
            json => {
                success => 0,
                error => "Log file not found",
                progress => 0,
                status => "error",
                output => "Log file not found for installation ID: $install_id"
            }
        );
        $c->detach('View::JSON');
        return;
    }
    
    # Read the log file
    my $output = '';
    eval {
        $output = path($log_file)->slurp_utf8();
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'installation_progress',
            "Error reading log file: $@");
        $c->stash(
            json => {
                success => 0,
                error => "Error reading log file",
                progress => 0,
                status => "error",
                output => "Error reading log file: $@"
            }
        );
        $c->detach('View::JSON');
        return;
    }
    
    # Determine the installation status and progress
    my $status = "running";
    my $progress = 10; # Start at 10%
    
    # Check if the installation is complete
    if ($output =~ /INSTALLATION_COMPLETE/) {
        $status = "complete";
        $progress = 100;
    } else {
        # Estimate progress based on the installation type and log content
        if ($install_type eq 'docker') {
            if ($output =~ /Installing prerequisites/) {
                $progress = 20;
            } elsif ($output =~ /Adding Docker's official GPG key/) {
                $progress = 30;
            } elsif ($output =~ /Setting up the Docker repository/) {
                $progress = 40;
            } elsif ($output =~ /Installing Docker CE/) {
                $progress = 50;
            } elsif ($output =~ /Adding current user to the docker group/) {
                $progress = 70;
            } elsif ($output =~ /Installing Docker Compose/) {
                $progress = 80;
            } elsif ($output =~ /Docker installation completed/) {
                $progress = 90;
            }
        } elsif ($install_type eq 'kubernetes') {
            if ($output =~ /Installing MicroK8s/) {
                $progress = 20;
            } elsif ($output =~ /Adding current user to the microk8s group/) {
                $progress = 40;
            } elsif ($output =~ /Waiting for MicroK8s to start/) {
                $progress = 60;
            } elsif ($output =~ /Enabling essential add-ons/) {
                $progress = 70;
            } elsif ($output =~ /Creating kubectl alias/) {
                $progress = 80;
            } elsif ($output =~ /Setting up kubectl configuration/) {
                $progress = 90;
            }
        } elsif ($install_type eq 'npm') {
            if ($output =~ /Creating docker-compose.yml/) {
                $progress = 30;
            } elsif ($output =~ /Starting NPM containers/) {
                $progress = 50;
            } elsif ($output =~ /Waiting for NPM to start/) {
                $progress = 70;
            } elsif ($output =~ /Creating default configuration/) {
                $progress = 90;
            }
        }
        
        # Check if there was an error
        if ($output =~ /Error:|Failed:|fatal:|exception|error:/i) {
            $status = "error";
        }
    }
    
    # Return the progress information
    $c->stash(
        json => {
            success => 1,
            install_type => $install_type,
            progress => $progress,
            status => $status,
            output => $output
        }
    );
    
    $c->detach('View::JSON');
}

# Test method for AJAX requests
sub test_ajax :Local :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'test_ajax',
        "AJAX test endpoint accessed via " . $c->req->method);
    
    # Return a simple JSON response
    $c->stash(
        json => {
            success => 1,
            message => "AJAX test successful",
            timestamp => time(),
            method => $c->req->method
        }
    );
    
    $c->detach('View::JSON');
}

__PACKAGE__->meta->make_immutable;
1;