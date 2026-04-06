package Comserv::Model::Weather;
use Moose;
use namespace::autoclean;
use JSON;
use DateTime;
use Try::Tiny;
use Comserv::Util::Logging;

extends 'Catalyst::Model';

=head1 NAME

Comserv::Model::Weather - Weather Data Model

=head1 DESCRIPTION

This model handles weather configuration and data storage operations using the existing DBEncy schema.

=cut

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

sub _get_schema {
    my $self = shift;
    require Comserv::Model::RemoteDB;
    require Comserv::Model::Schema::Ency;

    my $remote_db = Comserv::Model::RemoteDB->new();
    my $connection_info = $remote_db->get_connection_info('ency');

    die "Weather: Cannot get ency database connection from RemoteDB\n"
        unless $connection_info;

    my $conn    = $connection_info->{config};
    my $db_type = $conn->{db_type} || 'mysql';

    my $dsn;
    my %opts = (RaiseError => 1, PrintError => 0, AutoCommit => 1);

    if ($db_type eq 'sqlite') {
        $dsn = "dbi:SQLite:dbname=" . $conn->{database_path};
        return Comserv::Model::Schema::Ency->connect($dsn, '', '', \%opts);
    }

    my $driver = 'MariaDB';
    eval { require DBD::MariaDB; 1 } or do { $driver = 'mysql' };
    $dsn = "dbi:$driver:database=$conn->{database};host=$conn->{host};port=$conn->{port}";

    return Comserv::Model::Schema::Ency->connect(
        $dsn, $conn->{username}, $conn->{password}, \%opts
    );
}

=head1 METHODS

=head2 get_weather_config

Get the active weather configuration for a specific user and site

=cut

sub get_weather_config {
    my ($self, $user_id, $site_id) = @_;

    my $schema = eval { $self->_get_schema };
    return undef if $@ || !$schema;

    my $config;
    eval {
        my @priorities;
        push @priorities, { user_id => $user_id, site_id => $site_id, is_active => '1' }
            if $user_id && $site_id;
        push @priorities, { user_id => 0, site_id => 0, is_active => '1' };

        for my $where (@priorities) {
            my $row = $schema->resultset('WeatherConfig')->search(
                $where,
                { order_by => { -desc => 'id' }, rows => 1 }
            )->first;
            if ($row) {
                $config = { $row->get_inflated_columns };
                last;
            }
        }
        1;
    };
    return $config;
}

=head2 save_weather_config

Save or update weather configuration for a specific user and site

=cut

sub save_weather_config {
    my ($self, $config, $user_id, $site_id) = @_;

    my $schema = eval { $self->_get_schema };
    return undef if $@ || !$schema;
    
    eval {
        # First, deactivate all existing configs for this user and site
        $schema->resultset('WeatherConfig')->search({
            user_id => $user_id,
            site_id => $site_id
        })->update({ is_active => 0 });
        
        # Insert new configuration
        my $new_config = $schema->resultset('WeatherConfig')->create({
            user_id => $user_id,
            site_id => $site_id,
            api_service => $config->{api_service},
            api_key => $config->{api_key},
            location_method => $config->{location_method},
            location_value => $config->{location_value},
            country_code => $config->{country_code} || 'US',
            update_interval => $config->{update_interval} || 30,
            temperature_units => $config->{temperature_units} || 'metric',
            language => $config->{language} || 'en',
            is_active => 1
        });
        
        return $new_config->id;
    };
    
    if ($@) {
        die "Error saving weather configuration: $@";
    }
}

=head2 get_weather_providers

Get list of available weather providers

=cut

sub get_weather_providers {
    my ($self) = @_;

    my $default_providers = [
        {
            provider_name   => 'openweathermap',
            api_base_url    => 'https://api.openweathermap.org/data/2.5',
            documentation_url => 'https://openweathermap.org/api'
        },
        {
            provider_name   => 'weatherapi',
            api_base_url    => 'https://api.weatherapi.com/v1',
            documentation_url => 'https://www.weatherapi.com/docs/'
        }
    ];

    my $schema = eval { $self->_get_schema };
    return $default_providers if $@ || !$schema;

    my $result = eval {
        my @providers = $schema->resultset('WeatherProviders')->search(
            { is_active => 1 },
            { order_by => 'provider_name' }
        );
        return [ map { $_->get_inflated_columns } @providers ];
    };

    return ($@ || !$result) ? $default_providers : $result;
}

sub get_cached_weather_data {
    my ($self, $data_type, $max_age_minutes) = @_;

    my $schema = eval { $self->_get_schema };
    return undef if $@ || !$schema;

    my $result = eval {
        my $cutoff = DateTime->now->subtract(minutes => $max_age_minutes)->epoch;
        $schema->resultset('WeatherData')->search(
            { data_type => $data_type, fetched_at => { '>=' => $cutoff } },
            { order_by => { -desc => 'fetched_at' }, rows => 1 }
        )->first;
    };
    return undef if $@ || !$result;

    my $raw = eval { JSON->new->utf8->decode($result->data_json) };
    return $@ ? undef : $raw;
}

sub cache_weather_data {
    my ($self, $config_id, $data_type, $data) = @_;

    my $schema = eval { $self->_get_schema };
    return 0 if $@ || !$schema;

    eval {
        $schema->resultset('WeatherData')->create({
            config_id  => $config_id,
            data_type  => $data_type,
            data_json  => JSON->new->utf8->encode($data),
            fetched_at => time(),
        });
        1;
    } or do { return 0 };
    return 1;
}

sub track_api_usage {
    my ($self, $config_id, $api_service) = @_;
    return 1;
}

__PACKAGE__->meta->make_immutable;

1;

=head1 AUTHOR

Shanta

=head1 LICENSE

This library is free software. You can redistribute it and/or modify
it under the same terms as Perl itself.

=cut