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
    return Comserv::Model::DBEncy->new->schema;
}

=head1 METHODS

=head2 get_weather_config

Get the active weather configuration for a specific user and site

=cut

sub get_weather_config {
    my ($self, $user_id, $site_id) = @_;
    
    my $schema = $self->_get_schema;
    
    eval {
        my $config = $schema->resultset('WeatherConfig')->search(
            { 
                user_id => $user_id,
                site_id => $site_id,
                is_active => 1 
            },
            { order_by => { -desc => 'id' }, rows => 1 }
        )->first;
        
        return $config ? $config->get_inflated_columns : undef;
    };
    
    if ($@) {
        # Table doesn't exist yet, return undef
        return undef;
    }
}

=head2 save_weather_config

Save or update weather configuration for a specific user and site

=cut

sub save_weather_config {
    my ($self, $config, $user_id, $site_id) = @_;
    
    my $schema = $self->_get_schema;
    
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
    
    my $schema = $self->_get_schema;
    
    eval {
        my @providers = $schema->resultset('WeatherProviders')->search(
            { is_active => 1 },
            { order_by => 'provider_name' }
        );
        
        return [ map { $_->get_inflated_columns } @providers ];
    };
    
    if ($@) {
        # Return default providers if table doesn't exist
        return [
            {
                provider_name => 'openweathermap',
                api_base_url => 'https://api.openweathermap.org/data/2.5',
                documentation_url => 'https://openweathermap.org/api'
            },
            {
                provider_name => 'weatherapi',
                api_base_url => 'https://api.weatherapi.com/v1',
                documentation_url => 'https://www.weatherapi.com/docs/'
            }
        ];
    }
}

__PACKAGE__->meta->make_immutable;

1;

=head1 AUTHOR

Shanta

=head1 LICENSE

This library is free software. You can redistribute it and/or modify
it under the same terms as Perl itself.

=cut