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
                    StackTrace
                    Session
                    Session::State::Cookie
                    Session::Store::File
                    Authentication
                /;

extends 'Catalyst';

our $VERSION = '0.01';

__PACKAGE__->log(Catalyst::Log->new(output => sub {
    my ($self, $level, $message) = @_;
    $level = 'debug' unless defined $level;
    $message = '' unless defined $message;
    $self->dispatchers->[0]->log(level => $level, message => $message);
}));

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
        storage => '/tmp/session_data',
        expires => 3600,
        cookie_name => 'comserv_session',
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

                
                __PACKAGE__->setup();

                1;