package Comserv;
use Moose;
use namespace::autoclean;
use Catalyst::Plugin::AutoCRUD;
use Config::JSON;
use FindBin '$Bin';
# perl
                package Comserv;
                use Moose;
                use namespace::autoclean;
                use Config::JSON;
                use FindBin '$Bin';

use Catalyst::Runtime 5.80;
use Catalyst qw/
    ConfigLoader
    Static::Simple
    AutoCRUD
    StackTrace
    Session
    Session::Store::File
    Session::State::Cookie
    Authentication
    Authorization::Roles
    Log::Dispatch
    Authorization::ACL
/;
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

    'Plugin::AutoCRUD' => {
        model => 'DBEncy',
        login_url => '/user/login',
        logout_url => '/user/logout',
        editable => 1,
        page_size => 25,
        exclude_tables => ['sessions', 'users'],
        default_view => 'TT'
    },

    'View::TT' => {
        INCLUDE_PATH => [
            __PACKAGE__->path_to('root'),
            __PACKAGE__->path_to('root', 'log'),
    default_view => 'TT',
    use_request_uri_for_path => 1,  # Use the request URI for path matching
    use_hash_path_suffix => 1,      # Use hash path suffix for better URL handling
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
        TEMPLATE_EXTENSION => '.tt',
        ERROR => 'error.tt',
        WRAPPER => 'layout.tt',
    },
);

sub check_and_update_schema {
    my ($self) = @_;
    # Code to check and update the schema
}
                __PACKAGE__->config(
                    name => 'Comserv',
                    disable_component_resolution_regex_fallback => 1,
                    enable_catalyst_header => $ENV{CATALYST_HEADER} // 1,
                    encoding => 'UTF-8',
                    debug => $ENV{CATALYST_DEBUG} // 0,
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
                );

sub psgi_app {
    my ($self) = shift;
    my $app = $self->SUPER::psgi_app(@_);

                    return sub {
                        my $env = shift;

                        $self->config->{enable_catalyst_header} = $ENV{CATALYST_HEADER} // 1;
                        $self->config->{debug} = $ENV{CATALYST_DEBUG} // 0;

        return $app->($env);
    };
}

sub schema_needs_update {
    my ($self) = @_;
    return $self->{schema_needs_update};
}

sub deploy_schema {
    my ($self) = @_;
    # Code to deploy the schema
}

__PACKAGE__->setup();
                __PACKAGE__->setup();

                1;