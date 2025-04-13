package Comserv::Controller::Hosting;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;
use JSON::MaybeXS qw(encode_json decode_json);
use LWP::UserAgent;
use Try::Tiny;
use Config::General;

BEGIN { extends 'Catalyst::Controller'; }

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

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
                    $api_config = {
                        url => $config_hash{NPM}->{endpoint} || $api_config->{url},
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
        "Hosting controller auto method called");

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

    # Initialize API client
    $c->stash->{npm_ua} = LWP::UserAgent->new(
        timeout => 10,
        default_headers => HTTP::Headers->new(
            Authorization => "Bearer " . $self->npm_api->{key},
            'Content-Type' => 'application/json'
        )
    );

    return 1;
}

sub index :Path :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
        "Hosting dashboard accessed");

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
        
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'index',
            "Unauthorized access attempt to Hosting dashboard. User: " . 
            ($c->session->{username} || 'none') . ", Roles: " . $roles_debug);
        $c->response->status(403);
        $c->stash(
            template => 'CSC/error/access_denied.tt',
            error_message => 'You do not have permission to access the Hosting dashboard.'
        );
        return;
    }

    # For admin users, we allow access from any location (including remote)
    # This is used for creating proxies for new customer sites over ZeroTier VPN
    if ($c->req->address !~ /^127\.0\.0\.1$|^::1$|^192\.168\.|^10\.|^172\.(1[6-9]|2[0-9]|3[0-1])\./) {
        # Just log the remote access for auditing purposes
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
            "Remote access to Hosting from IP: " . $c->req->address . 
            " by user: " . ($c->session->{username} || 'none') . 
            ", Roles: " . (ref($c->session->{roles}) eq 'ARRAY' ? 
                          join(', ', @{$c->session->{roles}}) : 
                          ($c->session->{roles} || 'none')));
        
        # Push debug message to stash as requested (no warning displayed to user)
        $c->stash->{debug_msg} = "Remote access from " . $c->req->address . 
            " by user " . ($c->session->{username} || 'none');
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
                error_title => 'Hosting Error',
                error_msg => 'Failed to initialize the API client for Nginx Proxy Manager.',
                technical_details => 'The npm_ua object could not be created. This may indicate a configuration issue.',
                action_required => 'Please check your NPM API configuration in the environment or config file.',
                debug_msg => "Failed to initialize npm_ua in Hosting index action"
            );
            return;
        }
        
        # Log the API request for debugging
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'index',
            "Making API request to: " . $self->npm_api->{url} . "/nginx/proxy-hosts");
        
        my $res = $c->stash->{npm_ua}->get($self->npm_api->{url} . "/nginx/proxy-hosts");
        unless ($res->is_success) {
            my $error_details = "Status: " . $res->status_line;
            if ($res->code == 401) {
                $error_details .= " - This may indicate an invalid API key";
            } elsif ($res->code == 404) {
                $error_details .= " - This may indicate an incorrect API URL";
            } elsif ($res->code == 0) {
                $error_details .= " - This may indicate that the Nginx Proxy Manager is not running or not accessible";
            }
            
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'index',
                "Failed to fetch proxies: " . $error_details);
            
            # Use the general error template with more specific error details
            $c->response->status(500);
            $c->stash(
                template => 'error.tt',
                error_title => 'Hosting Error',
                error_msg => 'Failed to fetch proxies from the Nginx Proxy Manager API.',
                technical_details => 'API request failed: ' . $error_details,
                action_required => 'Please check that the Nginx Proxy Manager is running and accessible, and that your API key is valid.',
                debug_msg => "Failed to fetch proxies in Hosting index action"
            );
            return;
        }

        $c->stash(
            proxies => decode_json($res->decoded_content),
            template => 'CSC/proxy_manager.tt',
            environment => $self->npm_api->{environment},
            access_scope => $self->npm_api->{access_scope}
        );
    } catch {
        my $error_message = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'index',
            "Proxy fetch failed: $error_message");
        
        # Determine the likely cause of the error
        my $action_required = 'Please check that the Nginx Proxy Manager is running and accessible.';
        if ($error_message =~ /Can't call method "get" on an undefined value/) {
            $action_required = 'The API client was not properly initialized. Please check your NPM API configuration and ensure the auto method is being called correctly.';
        } elsif ($error_message =~ /Connection refused/) {
            $action_required = 'Connection to the Nginx Proxy Manager was refused. Please check that the service is running and the URL is correct.';
        } elsif ($error_message =~ /timeout/i) {
            $action_required = 'The connection to the Nginx Proxy Manager timed out. Please check that the service is running and responsive.';
        } elsif ($error_message =~ /certificate/i) {
            $action_required = 'There was an SSL certificate issue connecting to the Nginx Proxy Manager. Please check your SSL configuration.';
        }
        
        # Use the general error template with more specific error details
        $c->response->status(500);
        $c->stash(
            template => 'error.tt',
            error_title => 'Hosting Error',
            error_msg => 'Failed to fetch proxies from the Nginx Proxy Manager API.',
            technical_details => 'Exception: ' . $error_message,
            action_required => $action_required,
            debug_msg => "Exception caught in Hosting index action"
        );
        return;
    };
}

sub create_proxy :Local :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_proxy',
        "Creating new proxy mapping");

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
        
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'create_proxy',
            "Unauthorized access attempt to create proxy. User: " . 
            ($c->session->{username} || 'none') . ", Roles: " . $roles_debug);
        $c->response->status(403);
        $c->stash(
            template => 'CSC/error/access_denied.tt',
            error_message => 'You do not have permission to create proxy mappings.'
        );
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
                error_title => 'Hosting Proxy Creation Error',
                error_msg => 'Failed to initialize the API client for Nginx Proxy Manager.',
                technical_details => 'The npm_ua object could not be created. This may indicate a configuration issue.',
                action_required => 'Please check your NPM API configuration in the environment or config file.',
                debug_msg => "Failed to initialize npm_ua in Hosting create_proxy action"
            );
            return;
        }
        
        # Log the API request for debugging
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'create_proxy',
            "Making API request to: " . $self->npm_api->{url} . "/nginx/proxy-hosts for domain: " . $params->{domain_names}[0]);
        
        my $res = $c->stash->{npm_ua}->post(
            $self->npm_api->{url} . "/nginx/proxy-hosts",
            Content => encode_json($params)
        );

        unless ($res->is_success) {
            my $error_details = "Status: " . $res->status_line;
            if ($res->code == 401) {
                $error_details .= " - This may indicate an invalid API key";
            } elsif ($res->code == 404) {
                $error_details .= " - This may indicate an incorrect API URL";
            } elsif ($res->code == 0) {
                $error_details .= " - This may indicate that the Nginx Proxy Manager is not running or not accessible";
            } elsif ($res->code == 400) {
                $error_details .= " - This may indicate invalid parameters or a duplicate domain";
            }
            
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_proxy',
                "Proxy creation failed: " . $error_details);
            
            # Use the general error template with more specific error details
            $c->response->status(500);
            $c->stash(
                template => 'error.tt',
                error_title => 'Hosting Proxy Creation Error',
                error_msg => 'Failed to create proxy for domain: ' . $params->{domain_names}[0],
                technical_details => 'API request failed: ' . $error_details,
                action_required => 'Please check that the Nginx Proxy Manager is running and accessible, and that your API key is valid.',
                debug_msg => "Failed to create proxy in Hosting create_proxy action"
            );
            return;
        }

        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_proxy',
            "Successfully created proxy for " . $params->{domain_names}[0]);
        $c->res->redirect($c->uri_for('/hosting'));
    } catch {
        my $error_message = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_proxy',
            "Proxy creation error: $error_message");
        
        # Determine the likely cause of the error
        my $action_required = 'Please check that the Nginx Proxy Manager is running and accessible.';
        if ($error_message =~ /Can't call method "post" on an undefined value/) {
            $action_required = 'The API client was not properly initialized. Please check your NPM API configuration and ensure the auto method is being called correctly.';
        } elsif ($error_message =~ /Connection refused/) {
            $action_required = 'Connection to the Nginx Proxy Manager was refused. Please check that the service is running and the URL is correct.';
        } elsif ($error_message =~ /timeout/i) {
            $action_required = 'The connection to the Nginx Proxy Manager timed out. Please check that the service is running and responsive.';
        } elsif ($error_message =~ /certificate/i) {
            $action_required = 'There was an SSL certificate issue connecting to the Nginx Proxy Manager. Please check your SSL configuration.';
        } elsif ($error_message =~ /JSON/i) {
            $action_required = 'There was an error encoding the request parameters. Please check that all required fields are provided and valid.';
        }
        
        # Use the general error template with more specific error details
        $c->response->status(500);
        $c->stash(
            template => 'error.tt',
            error_title => 'Hosting Proxy Creation Error',
            error_msg => 'Failed to create proxy for domain: ' . $params->{domain_names}[0],
            technical_details => 'Exception: ' . $error_message,
            action_required => $action_required,
            debug_msg => "Exception caught in Hosting create_proxy action"
        );
        return;
    };
}

__PACKAGE__->meta->make_immutable;
1;