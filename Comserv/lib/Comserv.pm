# perl

package Comserv;
use Moose;
use namespace::autoclean;
use Config::JSON;
use FindBin '$Bin';
use Comserv::Util::Logging;

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
    use_request_uri_for_path => 1,  # Use the request URI for path matching
    use_hash_path_suffix => 1,      # Use hash path suffix for better URL handling
    # Configure URI generation to not include port
    using_frontend_proxy => 1,
    ignore_frontend_proxy_port => 1,
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
        expires => 3600,
        cookie_name => 'comserv_session',
        cookie_secure => 0,
        cookie_httponly => 1,
    },
    'Plugin::Session::Store::File' => {
        dir => '/tmp/session_data',
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

    return sub {
        my $env = shift;

        $self->config->{enable_catalyst_header} = $ENV{CATALYST_HEADER} // 1;
        $self->config->{debug} = $ENV{CATALYST_DEBUG} // 0;

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
    my ($orig, $self, $c) = @_;
    
    # Log all unhandled errors with context
    if ($c->error && @{$c->error}) {
        my $error = $c->error->[0];
        my $error_msg = ref $error ? $error->message : $error;
        my $logger = Comserv::Util::Logging->instance;
        $logger->log_with_details($c, 'error', __FILE__, __LINE__, 'global_error_handler',
            "[GLOBAL ERROR] Unhandled exception: $error_msg");
    }
    
    # If error.tt hasn't been rendered yet, render it now
    unless ($c->response->body) {
        $c->response->status(500) unless $c->response->status;
        
        # Set up error template stash if not already set
        $c->stash->{error_title} ||= 'Application Error';
        $c->stash->{error_msg} ||= 'An unexpected error occurred.';
        $c->stash->{technical_details} ||= join(', ', @{$c->error});
        $c->stash->{template} = 'error.tt';
        
        # Try to render error page
        eval {
            my $view = $c->view('TT');
            $view->process($c);
        };
        
        # If that fails, send a plain text error response
        if ($@) {
            $c->response->content_type('text/plain; charset=utf-8');
            $c->response->body("Internal Server Error\n\n" . 
                               "An error occurred and we were unable to render the error page.\n" .
                               "Please contact the system administrator.");
        }
    }
    
    # Call the original finalize_error to complete response processing
    $self->$orig($c);
};

__PACKAGE__->setup();

1;