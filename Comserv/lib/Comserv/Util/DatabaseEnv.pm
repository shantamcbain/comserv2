package Comserv::Util::DatabaseEnv;

use strict;
use warnings;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;
use Comserv::Model::RemoteDB;

has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

has 'remote_db' => (
    is      => 'ro',
    default => sub { Comserv::Model::RemoteDB->new }
);

sub get_active_environment {
    my ($self, $c) = @_;
    
    if ($c && $c->session && exists $c->session->{active_db_environment}) {
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'get_active_environment',
            "Using session-based environment override: " . $c->session->{active_db_environment});
        return $c->session->{active_db_environment};
    }
    
    my $env = $ENV{ACTIVE_DB_ENVIRONMENT} || 'production';
    
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'get_active_environment',
        "Active database environment: $env");
    
    return $env;
}

sub set_active_environment {
    my ($self, $c, $env_name) = @_;
    
    unless ($self->validate_environment($env_name)) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'set_active_environment',
            "Invalid environment name: $env_name");
        return 0;
    }
    
    if ($c && $c->session) {
        $c->session->{active_db_environment} = $env_name;
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'set_active_environment',
            "Set session database environment to: $env_name");
        return 1;
    }
    
    return 0;
}

sub clear_active_environment {
    my ($self, $c) = @_;
    
    if ($c && $c->session && exists $c->session->{active_db_environment}) {
        delete $c->session->{active_db_environment};
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'clear_active_environment',
            "Cleared session database environment override");
        return 1;
    }
    
    return 0;
}

sub list_environments {
    my ($self) = @_;
    
    return ['production', 'staging', 'dev'];
}

sub get_environment_connection {
    my ($self, $c, $env_name, $db_name) = @_;
    
    unless ($self->validate_environment($env_name)) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_environment_connection',
            "Invalid environment name: $env_name");
        return;
    }
    
    $db_name ||= 'ency';
    
    my $conn_name = "${db_name}_${env_name}";
    
    my $all_connections = $self->remote_db->get_all_connections();
    
    if (exists $all_connections->{$conn_name}) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_environment_connection',
            "Found connection '$conn_name' for environment '$env_name' and database '$db_name'");
        return $all_connections->{$conn_name};
    }
    
    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'get_environment_connection',
        "Connection '$conn_name' not found for environment '$env_name' and database '$db_name'");
    
    return;
}

sub validate_environment {
    my ($self, $env_name) = @_;
    
    my $valid_envs = $self->list_environments();
    
    return grep { $_ eq $env_name } @$valid_envs;
}

sub get_environment_metadata {
    my ($self, $env_name) = @_;
    
    my %metadata = (
        production => {
            name => 'production',
            display_name => 'Production',
            color => 'red',
            css_class => 'env-production',
            warning_level => 'critical',
            description => 'Production database - live data',
            read_only_recommended => 1,
            confirmation_required => 1,
        },
        staging => {
            name => 'staging',
            display_name => 'Staging',
            color => 'yellow',
            css_class => 'env-staging',
            warning_level => 'medium',
            description => 'Staging database - testing environment',
            read_only_recommended => 0,
            confirmation_required => 1,
        },
        dev => {
            name => 'dev',
            display_name => 'Development',
            color => 'green',
            css_class => 'env-dev',
            warning_level => 'low',
            description => 'Development database - safe to modify',
            read_only_recommended => 0,
            confirmation_required => 0,
        },
    );
    
    return $metadata{$env_name};
}

sub get_available_environments {
    my ($self, $c, $db_name) = @_;
    
    $db_name ||= 'ency';
    
    my $all_connections = $self->remote_db->get_all_connections();
    my @available = ();
    
    foreach my $env (@{$self->list_environments()}) {
        my $conn_name = "${db_name}_${env}";
        
        if (exists $all_connections->{$conn_name}) {
            my $metadata = $self->get_environment_metadata($env);
            push @available, {
                environment => $env,
                connection_name => $conn_name,
                available => 1,
                metadata => $metadata,
                connection => $all_connections->{$conn_name},
            };
        } else {
            my $metadata = $self->get_environment_metadata($env);
            push @available, {
                environment => $env,
                connection_name => $conn_name,
                available => 0,
                metadata => $metadata,
            };
        }
    }
    
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'get_available_environments',
        "Found " . scalar(@available) . " environments for database '$db_name'");
    
    return \@available;
}

sub get_connection_for_database {
    my ($self, $c, $db_name) = @_;
    
    my $active_env = $self->get_active_environment($c);
    
    return $self->get_environment_connection($c, $active_env, $db_name);
}

__PACKAGE__->meta->make_immutable;

1;
