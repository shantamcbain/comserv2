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
                    Session::Store::File
                    Session::State::Cookie
                    Authentication
                    Authorization::Roles
                    Log::Dispatch
                    Authorization::ACL
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
                    'Plugin::Authentication' => {
                        default_realm => 'members',
                        realms        => {
                            members => {
                                credential => {
                                    class          => 'Password',
                                    password_field => 'password',
                                    password_type  => 'hashed',
                                },
                                store => {
                                    class         => 'DBIx::Class',
                                    user_model    => 'DB::User',
                                    role_relation => 'roles',
                                    role_field    => 'role',
                                },
                            },
                        },
                    },
                    'Plugin::Session' => {
                        storage => '/tmp/session_data',
                        expires => 3600,
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

                # Explicitly load controllers to ensure they're available
                use Comserv::Controller::ProxmoxServers;
                use Comserv::Controller::Proxmox;

                __PACKAGE__->setup();

                1;