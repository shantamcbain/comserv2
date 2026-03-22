package Comserv::Controller::Weather;
use Moose;
use namespace::autoclean;
use DateTime;
use JSON;
use Try::Tiny;
use Comserv::Util::Logging;
use Comserv::Service::WeatherAPI;
use Comserv::Model::Weather;

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

has 'weather_api' => (
    is => 'ro',
    isa => 'Comserv::Service::WeatherAPI',
    lazy => 1,
    default => sub { Comserv::Service::WeatherAPI->new }
);

has 'weather_model' => (
    is => 'ro',
    isa => 'Comserv::Model::Weather',
    lazy => 1,
    default => sub { Comserv::Model::Weather->new }
);

BEGIN { extends 'Catalyst::Controller'; }

=head1 NAME

Comserv::Controller::Weather - Weather Module Controller

=head1 DESCRIPTION

Weather module providing weather data integration for the entire application.
This module can be used by any part of the system to display weather information.

=head1 METHODS

=cut

sub index :Path('/Weather') :Args(0) {
    my ( $self, $c ) = @_;

    # Initialize debug_errors array
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};
    
    # Initialize debug_msg array if debug mode is enabled
    if ($c->session->{debug_mode}) {
        $c->stash->{debug_msg} = [] unless defined $c->stash->{debug_msg};
    }

    # Log entry into the index method
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', 'Entered Weather index method');
    push @{$c->stash->{debug_errors}}, "Entered Weather index method";

    # Add debug message only if debug mode is enabled
    if ($c->session->{debug_mode}) {
        push @{$c->stash->{debug_msg}}, "Weather Module - Landing Page loaded";
        push @{$c->stash->{debug_msg}}, "User: " . ($c->session->{username} || 'Guest');
        push @{$c->stash->{debug_msg}}, "Roles: " . join(', ', @{$c->session->{roles} || []});
    }

    # Check weather configuration status
    my $config_status = $self->_check_weather_config($c);
    
    # Get sample weather data to show functionality
    my $sample_weather = $self->_get_sample_weather_data($c);
    
    # Add debug info about configuration if debug mode is enabled
    if ($c->session->{debug_mode}) {
        push @{$c->stash->{debug_msg}}, "Configuration status checked";
        push @{$c->stash->{debug_msg}}, "Sample weather data prepared";
    }

    # Stash data for template
    $c->stash(
        config_status => $config_status,
        sample_weather => $sample_weather,
        template => 'Weather/index.tt'
    );
}

sub current :Path('/Weather/current') :Args(0) {
    my ( $self, $c ) = @_;

    # Initialize debug_errors array
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};

    # Log entry into the current method
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'current', 'Entered current weather method');
    push @{$c->stash->{debug_errors}}, "Entered current weather method";

    eval {
        # Get current weather data
        my $weather_data = $self->_get_current_weather($c);

        # Set response as JSON
        $c->response->content_type('application/json');
        $c->response->body(JSON->new->utf8->encode($weather_data));
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'current', 'Current weather data retrieved successfully');
        push @{$c->stash->{debug_errors}}, "Current weather data retrieved successfully";
        
    };
    
    if ($@) {
        my $error = $@;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'current', "Error retrieving current weather: $error");
        push @{$c->stash->{debug_errors}}, "Error retrieving current weather: $error";
        
        # Return error response
        $c->response->status(500);
        $c->response->content_type('application/json');
        $c->response->body(JSON->new->utf8->encode({
            error => 'Failed to retrieve weather data',
            message => $error
        }));
    }
}

sub forecast :Path('/Weather/forecast') :Args(0) {
    my ( $self, $c ) = @_;

    # Initialize debug_errors array
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};

    # Log entry into the forecast method
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'forecast', 'Entered forecast method');
    push @{$c->stash->{debug_errors}}, "Entered forecast method";

    # Add debug message
    if ($c->session->{debug_mode}) {
        $c->stash->{debug_msg} = [] unless defined $c->stash->{debug_msg};
        push @{$c->stash->{debug_msg}}, "Weather Forecast - Loading";
    }

    # Get forecast data
    my $forecast_data = $self->_get_forecast_data($c);

    # Stash data for template
    $c->stash(
        forecast_data => $forecast_data,
        template => 'Weather/forecast.tt'
    );
}

sub configuration :Path('/Weather/configuration') :Args(0) {
    my ( $self, $c ) = @_;

    # Initialize debug_errors array
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};

    # Log entry into the configuration method
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'configuration', 'Entered configuration method');
    push @{$c->stash->{debug_errors}}, "Entered configuration method";

    # Add debug message
    if ($c->session->{debug_mode}) {
        $c->stash->{debug_msg} = [] unless defined $c->stash->{debug_msg};
        push @{$c->stash->{debug_msg}}, "Weather Configuration - Loading";
    }

    # Handle POST request (saving configuration)
    if ($c->request->method eq 'POST') {
        return $self->_handle_configuration_save($c);
    }

    # Get current configuration
    my $current_config = $self->_get_weather_configuration($c);
    
    # Get available weather providers
    my $providers = $self->weather_model->get_weather_providers();

    # Stash data for template
    $c->stash(
        current_config => $current_config,
        weather_providers => $providers,
        template => 'Weather/configuration.tt'
    );
}

sub test_configuration :Path('/Weather/test_config') :Args(0) {
    my ( $self, $c ) = @_;

    # Initialize debug_errors array
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};

    # This endpoint handles AJAX requests for testing weather configuration
    my $config = {
        api_service => $c->request->param('api_service'),
        api_key => $c->request->param('api_key'),
        location_method => $c->request->param('location_method'),
        location_value => $c->request->param('location_value'),
        country_code => $c->request->param('country_code'),
        temperature_units => $c->request->param('temperature_units'),
        language => $c->request->param('language')
    };

    # Debug logging to see what we're actually receiving
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'test_configuration', 
        "Config received: " . JSON->new->encode($config));

    my $result = try {
        my $test_result = $self->weather_api->test_api_connection($config);
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'test_configuration', 
            'Weather API test: ' . ($test_result->{success} ? 'SUCCESS' : 'FAILED'));
        
        return $test_result;
    } catch {
        my $error = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'test_configuration', 
            "Weather API test error: $error");
        
        return {
            success => 0,
            message => "Configuration test failed: $error",
            error => $error
        };
    };

    # Return JSON response
    $c->response->content_type('application/json');
    $c->response->body(JSON->new->utf8->encode($result));
}

sub test_location :Path('/Weather/test_location') :Args(0) {
    my ( $self, $c ) = @_;

    # Initialize debug_errors array
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};

    # This endpoint handles AJAX requests for testing location configuration
    my $location_config = {
        location_method => $c->request->param('location_method'),
        location_value => $c->request->param('location_value'),
        country_code => $c->request->param('country_code') || 'US'
    };

    my $result = try {
        # Check if we have API key from the form data
        my $api_key = $c->request->param('api_key');
        my $api_service = $c->request->param('api_service');
        
        unless ($api_key && $api_service) {
            return {
                success => 0,
                message => "Location testing requires a valid API key. Please use the 'Test Weather API' button first to validate your complete configuration including location settings.",
                error => "API key validation required"
            };
        }
        
        # Set up weather API with API key for location validation
        $self->weather_api->api_key($api_key);
        $self->weather_api->api_service($api_service);
        
        my $location_result = $self->weather_api->test_location($location_config);
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'test_location', 
            'Location test: ' . ($location_result->{success} ? 'SUCCESS' : 'FAILED'));
        
        return $location_result;
    } catch {
        my $error = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'test_location', 
            "Location test error: $error");
        
        # Provide more user-friendly error messages
        my $user_message = $error;
        if ($error =~ /401 Unauthorized/) {
            $user_message = "Invalid API key. Please check your weather API key configuration.";
        } elsif ($error =~ /API key is required/) {
            $user_message = "API key is required for location testing. Please configure your weather API key first.";
        }
        
        return {
            success => 0,
            message => "Location test failed: $user_message",
            error => $error
        };
    };

    # Return JSON response
    $c->response->content_type('application/json');
    $c->response->body(JSON->new->utf8->encode($result));
}

sub lookup_postal_code :Path('/Weather/lookup_postal') :Args(0) {
    my ( $self, $c ) = @_;

    # Initialize debug_errors array
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};

    # This endpoint handles AJAX requests for postal code lookup
    my $postal_code = $c->request->param('postal_code');
    my $country_code = $c->request->param('country_code') || 'US';

    my $result = try {
        # Check if we have a current configuration with API key
        my $current_config = $self->_get_weather_configuration($c);
        
        # If no API key is configured, silently fail for auto-complete
        unless ($current_config && $current_config->{api_key}) {
            return {
                success => 0,
                message => "API key required for postal code lookup",
                error => "No API key configured"
            };
        }
        
        # Set up weather API with current config
        $self->weather_api->api_key($current_config->{api_key});
        $self->weather_api->api_service($current_config->{api_service} || 'openweathermap');
        
        my $lookup_result = $self->weather_api->lookup_postal_code($postal_code, $country_code);
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'lookup_postal_code', 
            'Postal code lookup: ' . ($lookup_result->{success} ? 'SUCCESS' : 'FAILED'));
        
        return $lookup_result;
    } catch {
        my $error = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'lookup_postal_code', 
            "Postal code lookup error: $error");
        
        return {
            success => 0,
            message => "Postal code lookup failed: $error",
            error => $error
        };
    };

    # Return JSON response
    $c->response->content_type('application/json');
    $c->response->body(JSON->new->utf8->encode($result));
}

sub save_configuration :Path('/Weather/save_configuration') :Args(0) {
    my ( $self, $c ) = @_;

    # Initialize debug_errors array
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};

    # This endpoint handles form submission for saving weather configuration
    if ($c->request->method eq 'POST') {
        return $self->_handle_configuration_save($c);
    } else {
        # Redirect to configuration page for GET requests
        $c->response->redirect($c->uri_for('/Weather/configuration'));
        return;
    }
}

# Private methods

sub _check_weather_config {
    my ( $self, $c ) = @_;
    
    # Get user and site context
    my $user_id = $c->session->{user_id};
    my $site_id = $c->session->{site_id};
    
    # If no user or site context, return unconfigured status
    unless ($user_id && $site_id) {
        return {
            api_configured => 0,
            location_set => 0,
            error => 'User session required for weather configuration'
        };
    }
    
    # Ensure weather tables exist
    $self->_ensure_weather_tables($c);
    
    my $config = try {
        return $self->weather_model->get_weather_config($user_id, $site_id);
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_check_weather_config', 
            "Error checking weather config: $_");
        return undef;
    };
    
    if ($config && $config->{api_key}) {
        return {
            api_configured => 1,
            api_service => $config->{api_service},
            location_set => $config->{location_value} ? 1 : 0,
            last_update => $config->{updated_at},
            status => 'configured'
        };
    } else {
        return {
            api_configured => 0,
            api_service => 'none',
            location_set => 0,
            last_update => undef,
            status => 'not_configured'
        };
    }
}

sub _get_sample_weather_data {
    my ( $self, $c ) = @_;
    
    # Return sample data to show what weather integration looks like
    return {
        temperature => 18,
        condition => 'Clear Sky',
        humidity => 45,
        wind_speed => 12,
        wind_direction => 'NW',
        description => 'Clear sky with light winds',
        icon => 'sunny',
        timestamp => time(),
        data_source => 'SAMPLE_DATA'
    };
}

sub _get_current_weather {
    my ( $self, $c ) = @_;
    
    # Try to get cached data first
    my $cached_data = try {
        return $self->weather_model->get_cached_weather_data('current', 30);
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_get_current_weather', 
            "Error getting cached weather data: $_");
        return undef;
    };
    
    if ($cached_data) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_get_current_weather', 
            'Using cached weather data');
        return $self->_format_weather_response($cached_data);
    }
    
    # Get fresh data from API
    my $config = try {
        return $self->weather_model->get_weather_config();
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_get_current_weather', 
            "Error getting weather config: $_");
        return undef;
    };
    
    unless ($config && $config->{api_key}) {
        # Return mock data if not configured
        return {
            temperature => 20,
            condition => 'Configuration Required',
            humidity => 0,
            wind_speed => 0,
            description => 'Weather API not configured',
            icon => 'unknown',
            timestamp => time(),
            data_source => 'MOCK_DATA',
            location => 'Unknown Location'
        };
    }
    
    my $weather_data = try {
        my $data = $self->weather_api->get_current_weather($config);
        
        # Cache the data
        $self->weather_model->cache_weather_data($config->{id}, 'current', $data);
        
        # Track API usage
        $self->weather_model->track_api_usage($config->{id}, $config->{api_service});
        
        return $data;
    } catch {
        my $error = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_get_current_weather', 
            "Error getting current weather: $error");
        
        # Try to return the most recent cached data even if expired
        my $fallback_data = $self->weather_model->get_cached_weather_data('current', 1440); # 24 hours
        if ($fallback_data) {
            $fallback_data->{data_source} = 'CACHED_FALLBACK';
            return $self->_format_weather_response($fallback_data);
        }
        
        die $error;
    };
    
    return $weather_data;
}

sub _get_forecast_data {
    my ( $self, $c ) = @_;
    
    # Try to get cached data first
    my $cached_data = try {
        return $self->weather_model->get_cached_weather_data('forecast', 60); # 1 hour cache
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_get_forecast_data', 
            "Error getting cached forecast data: $_");
        return undef;
    };
    
    if ($cached_data) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_get_forecast_data', 
            'Using cached forecast data');
        return $self->_format_forecast_response($cached_data);
    }
    
    # Get fresh data from API
    my $config = try {
        return $self->weather_model->get_weather_config();
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_get_forecast_data', 
            "Error getting weather config: $_");
        return undef;
    };
    
    unless ($config && $config->{api_key}) {
        # Return mock data if not configured
        my @forecast = ();
        my @conditions = ('Sunny', 'Partly Cloudy', 'Cloudy', 'Light Rain');
        my @icons = ('sunny', 'partly-cloudy', 'cloudy', 'light-rain');
        
        for my $day (1..5) {
            push @forecast, {
                date => DateTime->now->add(days => $day)->ymd,
                high_temp => 20 + int(rand(10)),
                low_temp => 10 + int(rand(8)),
                condition => $conditions[int(rand(4))],
                icon => $icons[int(rand(4))],
                precipitation => int(rand(30)),
            };
        }
        
        return {
            forecast => \@forecast,
            data_source => 'MOCK_DATA'
        };
    }
    
    my $forecast_data = try {
        my $data = $self->weather_api->get_forecast_weather($config);
        
        # Cache the data
        $self->weather_model->cache_weather_data($config->{id}, 'forecast', $data);
        
        # Track API usage
        $self->weather_model->track_api_usage($config->{id}, $config->{api_service});
        
        return $data;
    } catch {
        my $error = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_get_forecast_data', 
            "Error getting forecast data: $error");
        
        # Try to return the most recent cached data even if expired
        my $fallback_data = $self->weather_model->get_cached_weather_data('forecast', 1440); # 24 hours
        if ($fallback_data) {
            $fallback_data->{data_source} = 'CACHED_FALLBACK';
            return $self->_format_forecast_response($fallback_data);
        }
        
        die $error;
    };
    
    return $forecast_data;
}

sub _get_weather_configuration {
    my ( $self, $c ) = @_;
    
    # Get user and site context
    my $user_id = $c->session->{user_id};
    my $site_id = $c->session->{site_id};
    
    my $config = try {
        # Only get config if we have user and site context
        if ($user_id && $site_id) {
            return $self->weather_model->get_weather_config($user_id, $site_id);
        } else {
            return undef;
        }
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_get_weather_configuration', 
            "Error getting weather configuration: $_");
        return undef;
    };
    
    if ($config) {
        return {
            api_service => $config->{api_service} || 'openweathermap',
            api_key => $config->{api_key} || '',
            location_method => $config->{location_method} || 'zip',
            location_value => $config->{location_value} || '',
            country_code => $config->{country_code} || 'US',
            update_interval => $config->{update_interval} || 30,
            temperature_units => $config->{temperature_units} || 'metric',
            language => $config->{language} || 'en'
        };
    } else {
        # Return default configuration
        return {
            api_service => 'openweathermap',
            api_key => '',
            location_method => 'zip',
            location_value => '',
            country_code => 'US',
            update_interval => 30,
            temperature_units => 'metric',
            language => 'en'
        };
    }
}

sub _handle_configuration_save {
    my ( $self, $c ) = @_;
    
    my $config = {
        api_service => $c->request->param('api_service'),
        api_key => $c->request->param('api_key'),
        location_method => $c->request->param('location_method'),
        location_value => $c->request->param('location_value'),
        country_code => $c->request->param('country_code'),
        update_interval => $c->request->param('update_interval'),
        temperature_units => $c->request->param('temperature_units'),
        language => $c->request->param('language')
    };
    
    # Get user and site context
    my $user_id = $c->session->{user_id};
    my $site_id = $c->session->{site_id};
    
    # Check if we have required session data
    unless ($user_id && $site_id) {
        $c->stash->{error_message} = "User session required to save weather configuration";
        $c->response->redirect($c->uri_for('/Weather/configuration'));
        return;
    }
    
    # Ensure weather tables exist before saving
    $self->_ensure_weather_tables($c);
    
    my $result = try {
        my $config_id = $self->weather_model->save_weather_config($config, $user_id, $site_id);
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_handle_configuration_save', 
            "Weather configuration saved with ID: $config_id for user: $user_id, site: $site_id");
        
        # Set up weather API with the configuration for testing
        $self->weather_api->api_key($config->{api_key});
        $self->weather_api->api_service($config->{api_service});
        
        # Test the configuration
        my $test_result = $self->weather_api->test_api_connection($config);
        
        if ($test_result->{success}) {
            $c->stash->{success_message} = 'Weather configuration saved and tested successfully!';
        } else {
            $c->stash->{warning_message} = 'Configuration saved but API test failed: ' . $test_result->{message};
        }
        
        return 1;
    } catch {
        my $error = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_handle_configuration_save', 
            "Error saving weather configuration: $error");
        
        $c->stash->{error_message} = "Failed to save configuration: $error";
        return 0;
    };
    
    # Redirect back to configuration page
    $c->response->redirect($c->uri_for('/Weather/configuration'));
}

sub _format_weather_response {
    my ( $self, $data ) = @_;
    
    return {
        temperature => $data->{temperature},
        condition => $data->{condition_main},
        humidity => $data->{humidity},
        wind_speed => $data->{wind_speed},
        description => $data->{condition_description},
        icon => $data->{weather_icon},
        timestamp => time(),
        data_source => $data->{data_source} || 'DATABASE',
        location => $data->{location_name}
    };
}

sub _format_forecast_response {
    my ( $self, $data ) = @_;
    
    # This would need to be implemented based on how forecast data is stored
    # For now, return the raw data
    return $data;
}

sub _ensure_weather_tables {
    my ( $self, $c ) = @_;
    
    try {
        # Get the DBEncy model to use its table creation functionality
        my $db_model = $c->model('DBEncy');
        
        # Create weather tables if they don't exist
        my @weather_tables = ('WeatherConfig', 'WeatherData', 'WeatherProviders');
        
        foreach my $table_name (@weather_tables) {
            my $result = $db_model->create_table_from_result($table_name, $db_model->schema, $c);
            if ($result) {
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_ensure_weather_tables', 
                    "Weather table $table_name is available");
            }
        }
        
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_ensure_weather_tables', 
            "Error ensuring weather tables exist: $_");
    };
}

=head1 AUTHOR

Shanta

=head1 LICENSE

This library is free software. You can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

__PACKAGE__->meta->make_immutable;

1;