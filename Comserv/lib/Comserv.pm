package Comserv;
use Moose;
use namespace::autoclean;
use Config::JSON;
use FindBin '$Bin';
use Comserv::Util::Logging;
use Try::Tiny;

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
    'View::TT' => {
        INCLUDE_PATH => [
            __PACKAGE__->path_to('root'),
            __PACKAGE__->path_to('root', 'WorkShops'),
        ],
        WRAPPER => 'layout.tt',
        DEBUG => 1,
        TEMPLATE_EXTENSION => '.tt',
        ERROR => 'error.tt',
    },
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
        default_realm => 'members',
        realms => {
            members => {
                credential => {
                    class => 'Password',
                    password_field => 'password',
                    password_type => 'hashed',
                },
                store => {
                    class => 'DBIx::Class',
                    user_model => 'DB::User',
                    role_relation => 'roles',
                    role_field => 'role',
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
    my $self = shift;

    my $app = $self->SUPER::psgi_app(@_);

    return sub {
        my $env = shift;

        $self->config->{enable_catalyst_header} = $ENV{CATALYST_HEADER} // 1;
        $self->config->{debug} = $ENV{CATALYST_DEBUG} // 0;

        return $app->($env);
    };
}

sub check_and_update_schema {
    my ($self) = @_;
    my $logging = Comserv::Util::Logging->instance;

    try {
        my $schema = Comserv::Model::DBEncy->new->schema;
        my $dbh = $schema->storage->dbh;

        # Check if the schema is up-to-date
        my $tables_exist = $dbh->selectrow_array("SHOW TABLES LIKE 'sitedomain'");

        if ($tables_exist) {
            # Assume no differences for now
            $self->{schema_needs_update} = 0;
        } else {
            $self->deploy_schema();
            $self->{schema_needs_update} = 0;
        }
    } catch {
        $logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'check_and_update_schema', "Error: $_");
        $self->{schema_needs_update} = 1;
    };
}

sub schema_needs_update {
    my ($self) = @_;
    return $self->{schema_needs_update};
}

sub deploy_schema {
    my ($self) = @_;
    my $logging = Comserv::Util::Logging->instance;
    
    try {
        # Get the schema
        my $schema = Comserv::Model::DBEncy->new->schema;
        
        # Deploy the schema
        $logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'deploy_schema', "Deploying schema");
        $schema->deploy();
        $logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'deploy_schema', "Schema deployed successfully");
        
        return 1;
    } catch {
        $logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'deploy_schema', "Error deploying schema: $_");
        return 0;
    };
}

__PACKAGE__->setup();

=encoding utf8

=head1 NAME

Comserv - Catalyst based application

=head1 SYNOPSIS

    script/comserv_server.pl

=head1 DESCRIPTION

[enter your description here]

=head1 SEE ALSO

L<Comserv::Controller::Root>, L<Catalyst>

=head1 AUTHOR

Shanta McBain

=head1 LICENSE

This library is free software. You can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

1;