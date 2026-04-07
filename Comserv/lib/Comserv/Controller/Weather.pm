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

    # If configured, get real current weather data + history for chart
    my ($current_weather, $history_data, $weather_config);
    if ($config_status->{api_configured}) {
        $current_weather = try {
            $self->_get_current_weather($c);
        } catch {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'index',
                "Error getting current weather for index: $_");
            undef;
        };

        # If DB returned mock/no data, fall back to session-cached weather
        if (!$current_weather || ($current_weather->{data_source} && $current_weather->{data_source} eq 'MOCK_DATA')) {
            if ($c->session->{last_weather}) {
                $current_weather = $c->session->{last_weather};
                $current_weather->{data_source} = 'SESSION_CACHE';
            } else {
                $current_weather = undef;
            }
        } else {
            # Cache good data in session for fallback
            $c->session->{last_weather} = $current_weather;
        }

        $weather_config = try {
            $self->weather_model->get_weather_config($c);
        } catch { undef };

        if ($weather_config) {
            $history_data = try {
                $self->weather_model->get_weather_history($c, $weather_config->{id}, 48);
            } catch { [] };
        }
    }

    # Stash data for template
    $c->stash(
        config_status   => $config_status,
        current_weather => $current_weather,
        weather_config  => $weather_config,
        history_data    => $history_data || [],
        template        => 'Weather/index.tt'
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

    my $forecast_data  = $self->_get_forecast_data($c);
    my $weather_config = try { $self->weather_model->get_weather_config($c) } catch { undef };

    $c->stash(
        forecast_data  => $forecast_data,
        weather_config => $weather_config,
        template       => 'Weather/forecast.tt'
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
    my $providers = $self->weather_model->get_weather_providers($c);

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
    
    my $user_id = $c->session->{user_id};
    my $site_id = $c->session->{site_id};

    my $config = try {
        return $self->weather_model->get_weather_config($c, $user_id, $site_id);
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_check_weather_config',
            "Error checking weather config: $_");
        return undef;
    };

    if ($config && $config->{api_key}) {
        $c->session->{weather_api_service}    = $config->{api_service};
        $c->session->{weather_api_configured} = 1;
        return {
            api_configured => 1,
            api_service    => $config->{api_service},
            location_set   => $config->{location_value} ? 1 : 0,
            last_update    => $config->{updated_at},
            status         => 'configured'
        };
    }

    if ($c->session->{weather_api_configured}) {
        return {
            api_configured => 1,
            api_service    => $c->session->{weather_api_service} || 'openweathermap',
            location_set   => 1,
            last_update    => undef,
            status         => 'configured'
        };
    }

    return {
        api_configured => 0,
        api_service    => 'none',
        location_set   => 0,
        last_update    => undef,
        status         => 'not_configured'
    };
}

sub poll_now :Path('/Weather/poll') :Args(0) {
    my ($self, $c) = @_;

    my @roles = @{$c->session->{roles} || []};
    unless (grep { /^admin$/i } @roles) {
        $c->flash->{error_msg} = 'Admin access required to run weather poll.';
        $c->response->redirect($c->uri_for('/Weather'));
        return;
    }

    my $config = try {
        $self->weather_model->get_weather_config($c);
    } catch { undef };

    unless ($config && $config->{api_key}) {
        $c->flash->{error_msg} = 'Weather is not configured. Please set up the API key first.';
        $c->response->redirect($c->uri_for('/Weather/configuration'));
        return;
    }

    my $result = try {
        $self->weather_api->api_key($config->{api_key});
        $self->weather_api->api_service($config->{api_service} || 'openweathermap');
        my $data = $self->weather_api->get_current_weather($config);
        $self->weather_model->cache_weather_data($c, $config->{id}, 'current', $data);
        $self->weather_model->record_weather_history($c, $config->{id}, $data);
        $c->session->{last_weather} = $self->_format_weather_response($data);
        return $data;
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'poll_now',
            "Manual poll failed: $_");
        return undef;
    };

    if ($result) {
        $c->flash->{success_msg} = 'Weather data updated: '
            . sprintf('%.1f', $result->{temperature} // 0) . '°C, '
            . ($result->{condition_description} || $result->{condition_main} || 'n/a')
            . ' at ' . ($result->{location_name} || $config->{location_value} || '?');
    } else {
        $c->flash->{error_msg} = 'Weather poll failed. Check API key and location settings.';
    }

    $c->response->redirect($c->uri_for('/Weather'));
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
        return $self->weather_model->get_cached_weather_data($c, 'current', 30);
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

    # Cache is stale or empty — return older data if available (cron poller updates the cache)
    my $stale_data = try {
        $self->weather_model->get_cached_weather_data($c, 'current', 1440);
    } catch { undef };

    if ($stale_data) {
        $stale_data->{data_source} = 'CACHED_FALLBACK';
        return $self->_format_weather_response($stale_data);
    }

    # No data at all — return mock placeholder
    return {
        temperature => undef,
        condition   => 'No Data',
        humidity    => undef,
        wind_speed  => undef,
        description => 'Run the weather poller to fetch live data',
        icon        => undef,
        timestamp   => time(),
        data_source => 'MOCK_DATA',
        location    => 'Unknown Location'
    };
}

sub _get_forecast_data {
    my ( $self, $c ) = @_;
    
    # Try to get cached data first
    my $cached_data = try {
        return $self->weather_model->get_cached_weather_data($c, 'forecast', 60); # 1 hour cache
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

    # Cache is stale — fall back to older data (cron poller refreshes the cache)
    my $stale_data = try {
        $self->weather_model->get_cached_weather_data($c, 'forecast', 1440);
    } catch { undef };

    if ($stale_data) {
        $stale_data->{data_source} = 'CACHED_FALLBACK';
        return $self->_format_forecast_response($stale_data);
    }

    return { forecast => [], data_source => 'NO_DATA' };
}

sub _get_weather_configuration {
    my ( $self, $c ) = @_;
    
    # Get user and site context
    my $user_id = $c->session->{user_id};
    my $site_id = $c->session->{site_id};
    
    my $config = try {
        return $self->weather_model->get_weather_config($c, $user_id, $site_id);
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
        my $config_id = $self->weather_model->save_weather_config($c, $config, $user_id, $site_id);
        
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
    my ($self, $db_row) = @_;

    my $raw_json = $db_row->{raw_data} or return { forecast => [], data_source => 'NO_DATA' };

    my $owm;
    eval { $owm = JSON->new->utf8->decode($raw_json) };
    return { forecast => [], data_source => 'PARSE_ERROR' } if $@ || !$owm;

    my $items = $owm->{list} or return { forecast => [], data_source => 'NO_LIST' };

    my %days;
    for my $item (@$items) {
        my $dt   = DateTime->from_epoch(epoch => $item->{dt}, time_zone => 'UTC');
        my $date = $dt->ymd;
        $days{$date} ||= { temps => [], precip => 0, icon => undef, condition => undef, dt => $item->{dt} };
        push @{$days{$date}{temps}}, $item->{main}{temp};
        $days{$date}{precip} += ($item->{rain}{'3h'} || $item->{snow}{'3h'} || 0);
        if ($dt->hour == 12 || !$days{$date}{icon}) {
            $days{$date}{icon}      = $item->{weather}[0]{icon};
            $days{$date}{condition} = $item->{weather}[0]{description};
        }
    }

    my @day_names = qw(Sun Mon Tue Wed Thu Fri Sat);
    my @mon_names = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);

    my @daily;
    for my $date (sort keys %days) {
        my @temps = @{$days{$date}{temps}};
        my ($y, $m, $d) = split /-/, $date;
        my $dt_obj = eval { DateTime->new(year => $y, month => $m, day => $d, time_zone => 'UTC') };
        my $label  = $dt_obj
            ? $day_names[$dt_obj->day_of_week % 7] . ', ' . $mon_names[$m - 1] . ' ' . int($d)
            : $date;
        push @daily, {
            date          => $date,
            date_label    => $label,
            dt            => $days{$date}{dt},
            high_temp     => (sort { $b <=> $a } @temps)[0],
            low_temp      => (sort { $a <=> $b } @temps)[0],
            condition     => ucfirst($days{$date}{condition} || 'Unknown'),
            icon          => $days{$date}{icon} || '01d',
            precipitation => sprintf('%.1f', $days{$date}{precip}),
        };
    }

    return {
        forecast      => \@daily,
        location_name => $owm->{city}{name} || $db_row->{location_name},
        data_source   => $db_row->{data_source} || 'DATABASE',
    };
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