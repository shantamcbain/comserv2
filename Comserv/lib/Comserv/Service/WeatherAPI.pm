package Comserv::Service::WeatherAPI;
use Moose;
use namespace::autoclean;
use LWP::UserAgent;
use JSON;
use URI::Escape;
use DateTime;
use Try::Tiny;
use Comserv::Util::Logging;

=head1 NAME

Comserv::Service::WeatherAPI - Weather API Integration Service

=head1 DESCRIPTION

This service handles integration with various weather API providers including:
- OpenWeatherMap
- WeatherAPI.com
- AccuWeather

=head1 ATTRIBUTES

=cut

has 'ua' => (
    is => 'ro',
    isa => 'LWP::UserAgent',
    lazy => 1,
    default => sub {
        my $ua = LWP::UserAgent->new(
            timeout => 30,
            agent => 'Comserv-Weather/1.0'
        );
        return $ua;
    }
);

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

has 'api_key' => (
    is => 'rw',
    isa => 'Str',
    predicate => 'has_api_key'
);

has 'api_service' => (
    is => 'rw',
    isa => 'Str',
    default => 'openweathermap'
);

=head1 METHODS

=head2 get_current_weather

Retrieves current weather data from the configured API provider

=cut

sub get_current_weather {
    my ($self, $config) = @_;
    
    return $self->_handle_api_request($config, 'current');
}

=head2 get_forecast_weather

Retrieves weather forecast data from the configured API provider

=cut

sub get_forecast_weather {
    my ($self, $config) = @_;
    
    return $self->_handle_api_request($config, 'forecast');
}

=head2 test_api_connection

Tests the API connection with the provided configuration

=cut

sub test_api_connection {
    my ($self, $config) = @_;
    
    try {
        my $result = $self->get_current_weather($config);
        return {
            success => 1,
            message => 'API connection successful',
            data => $result
        };
    } catch {
        return {
            success => 0,
            message => "API connection failed: $_",
            error => $_
        };
    };
}

=head2 test_location

Tests location configuration using geocoding API

=cut

sub test_location {
    my ($self, $location_config) = @_;
    
    unless ($self->has_api_key) {
        return {
            success => 0,
            message => "API key is required for location validation",
            error => "No API key configured"
        };
    }
    
    try {
        # Use OpenWeatherMap's geocoding API for location validation
        my $location_data = $self->_validate_location_openweather($location_config);
        
        # Check if this is a postal code not found case
        if (ref($location_data) eq 'HASH' && $location_data->{postal_code_not_found}) {
            return $location_data;  # Return the special response with suggestions
        }
        
        return {
            success => 1,
            message => 'Location validation successful',
            data => $location_data
        };
    } catch {
        return {
            success => 0,
            message => "Location validation failed: $_",
            error => $_
        };
    };
}

=head2 lookup_postal_code

Looks up location information for a postal code

=cut

sub lookup_postal_code {
    my ($self, $postal_code, $country_code) = @_;
    
    try {
        my $location_data = $self->_lookup_postal_code_openweather($postal_code, $country_code);
        
        return {
            success => 1,
            message => 'Postal code lookup successful',
            data => $location_data
        };
    } catch {
        return {
            success => 0,
            message => "Postal code lookup failed: $_",
            error => $_
        };
    };
}

=head2 _handle_api_request

Internal method to handle API requests based on provider

=cut

sub _handle_api_request {
    my ($self, $config, $request_type) = @_;
    
    my $provider = lc($config->{api_service} || 'openweathermap');
    
    if ($provider eq 'openweathermap') {
        return $self->_openweathermap_request($config, $request_type);
    } elsif ($provider eq 'weatherapi') {
        return $self->_weatherapi_request($config, $request_type);
    } elsif ($provider eq 'accuweather') {
        return $self->_accuweather_request($config, $request_type);
    } else {
        die "Unsupported weather provider: $provider";
    }
}

=head2 _openweathermap_request

Handle OpenWeatherMap API requests

=cut

sub _openweathermap_request {
    my ($self, $config, $request_type) = @_;
    
    my $api_key = $config->{api_key} or die "API key is required";
    my $location = $self->_format_location_for_openweather($config);
    my $units = $config->{temperature_units} || 'metric';
    my $lang = $config->{language} || 'en';
    
    my $base_url = 'https://api.openweathermap.org/data/2.5';
    my $url;
    
    if ($request_type eq 'current') {
        $url = "$base_url/weather?$location&appid=$api_key&units=$units&lang=$lang";
    } elsif ($request_type eq 'forecast') {
        $url = "$base_url/forecast?$location&appid=$api_key&units=$units&lang=$lang";
    } else {
        die "Unsupported request type: $request_type";
    }
    
    # Debug logging to see the URL being requested
    $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_openweathermap_request', 
        "API URL: $url");
    
    my $response = $self->ua->get($url);
    
    unless ($response->is_success) {
        # Enhanced error logging to help debug location issues
        $self->logging->log_with_details(undef, 'error', __FILE__, __LINE__, '_openweathermap_request', 
            "API request failed - URL: $url, Status: " . $response->status_line . ", Response: " . $response->content);
        die "API request failed: " . $response->status_line . " - " . $response->content;
    }
    
    my $data = decode_json($response->content);
    
    if ($request_type eq 'current') {
        return $self->_normalize_openweather_current($data);
    } else {
        return $self->_normalize_openweather_forecast($data);
    }
}

=head2 _weatherapi_request

Handle WeatherAPI.com requests

=cut

sub _weatherapi_request {
    my ($self, $config, $request_type) = @_;
    
    my $api_key = $config->{api_key} or die "API key is required";
    my $location = $self->_format_location_for_weatherapi($config);
    my $lang = $config->{language} || 'en';
    
    my $base_url = 'https://api.weatherapi.com/v1';
    my $url;
    
    if ($request_type eq 'current') {
        $url = "$base_url/current.json?key=$api_key&q=$location&lang=$lang";
    } elsif ($request_type eq 'forecast') {
        $url = "$base_url/forecast.json?key=$api_key&q=$location&days=5&lang=$lang";
    } else {
        die "Unsupported request type: $request_type";
    }
    
    my $response = $self->ua->get($url);
    
    unless ($response->is_success) {
        die "API request failed: " . $response->status_line . " - " . $response->content;
    }
    
    my $data = decode_json($response->content);
    
    if ($request_type eq 'current') {
        return $self->_normalize_weatherapi_current($data);
    } else {
        return $self->_normalize_weatherapi_forecast($data);
    }
}

=head2 _accuweather_request

Handle AccuWeather API requests

=cut

sub _accuweather_request {
    my ($self, $config, $request_type) = @_;
    
    # AccuWeather requires location key lookup first
    die "AccuWeather integration not yet implemented";
}

=head2 Location formatting methods

=cut

sub _format_location_for_openweather {
    my ($self, $config) = @_;
    
    my $method = $config->{location_method} || 'zip';
    my $value = $config->{location_value} or die "Location value is required";
    my $country = $config->{country_code} || 'US';
    
    # Debug logging
    $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_format_location_for_openweather', 
        "Location formatting - Method: $method, Value: $value, Country: $country");
    
    my $location_string;
    if ($method eq 'zip') {
        $location_string = "zip=$value,$country";
    } elsif ($method eq 'city') {
        $location_string = "q=" . uri_escape($value) . ",$country";
    } elsif ($method eq 'coordinates') {
        my ($lat, $lon) = split(',', $value);
        $location_string = "lat=$lat&lon=$lon";
    } else {
        die "Unsupported location method: $method";
    }
    
    # Debug the final location string
    $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_format_location_for_openweather', 
        "Final location string: $location_string");
    
    return $location_string;
}

sub _format_location_for_weatherapi {
    my ($self, $config) = @_;
    
    my $method = $config->{location_method} || 'zip';
    my $value = $config->{location_value} or die "Location value is required";
    my $country = $config->{country_code} || 'US';
    
    if ($method eq 'zip') {
        return uri_escape("$value,$country");
    } elsif ($method eq 'city') {
        return uri_escape("$value,$country");
    } elsif ($method eq 'coordinates') {
        return uri_escape($value);  # lat,lon format
    } else {
        die "Unsupported location method: $method";
    }
}



=head2 Location validation and lookup methods

=cut

sub _validate_location_openweather {
    my ($self, $location_config) = @_;
    
    my $method = $location_config->{location_method} || 'zip';
    my $value = $location_config->{location_value} or die "Location value is required";
    my $country = $location_config->{country_code} || 'US';
    
    # Basic validation
    if ($method eq 'zip' && (!$value || $value =~ /^\s*$/)) {
        die "Postal code cannot be empty";
    }
    if (!$country || length($country) != 2) {
        die "Country code must be a valid 2-letter ISO code";
    }
    
    # Use OpenWeatherMap's geocoding API
    my $base_url = 'https://api.openweathermap.org/geo/1.0';
    my $api_key = $self->api_key or die "API key is required for location validation";
    
    # Debug logging for API key (masked for security)
    my $masked_key = substr($api_key, 0, 8) . '...' . substr($api_key, -4);
    $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_validate_location_openweather', 
        "Using API key: $masked_key, Method: $method, Value: $value, Country: $country");
    
    my $url;
    
    if ($method eq 'zip') {
        # Clean up postal code - remove extra spaces and ensure proper format
        my $clean_zip = $value;
        $clean_zip =~ s/^\s+|\s+$//g;  # trim whitespace
        $url = "$base_url/zip?zip=$clean_zip,$country&appid=$api_key";
    } elsif ($method eq 'city') {
        my $city_query = uri_escape($value);
        $url = "$base_url/direct?q=$city_query,$country&limit=1&appid=$api_key";
    } elsif ($method eq 'coordinates') {
        my ($lat, $lon) = split(',', $value);
        $url = "$base_url/reverse?lat=$lat&lon=$lon&limit=1&appid=$api_key";
    } else {
        die "Unsupported location method: $method";
    }
    
    # Debug logging for location validation
    $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_validate_location_openweather', 
        "Location validation URL: $url");
    
    my $response = $self->ua->get($url);
    
    unless ($response->is_success) {
        # Enhanced error logging for location validation
        $self->logging->log_with_details(undef, 'error', __FILE__, __LINE__, '_validate_location_openweather', 
            "Location validation failed - URL: $url, Status: " . $response->status_line . ", Response: " . $response->content);
        
        # Handle 404 errors for postal codes
        if ($response->code == 404 && $method eq 'zip') {
            # Postal code not found - this is common for rural areas
            $self->logging->log_with_details(undef, 'warn', __FILE__, __LINE__, '_validate_location_openweather', 
                "Postal code '$value' not found in OpenWeatherMap database for country '$country'");
            
            return {
                success => 0,
                postal_code_not_found => 1,
                message => "Postal code '$value' not found in OpenWeatherMap's database. This is common for rural areas. Please try one of these alternatives:\n1. Use your city name instead of postal code\n2. Use coordinates (latitude,longitude) if you know them\n3. Try a nearby larger city's postal code",
                suggested_method => 'city',
                postal_code => $value,
                country_code => $country
            };
        }
        
        # Provide helpful error messages for other error types
        my $error_msg = $response->status_line;
        if ($response->code == 404) {
            if ($method eq 'city') {
                $error_msg = "City '$value' not found for country '$country'. Please check the city name spelling.";
            }
        } elsif ($response->code == 401) {
            $error_msg = "Invalid API key. Please check your OpenWeatherMap API key configuration.";
        }
        
        die "Location validation request failed: $error_msg";
    }
    
    my $data = decode_json($response->content);
    
    # Handle different response formats
    if ($method eq 'zip') {
        return {
            city_name => $data->{name},
            country_code => $data->{country},
            latitude => $data->{lat},
            longitude => $data->{lon},
            state => $data->{state} || '',
            zip_code => $value
        };
    } elsif ($method eq 'city' || $method eq 'coordinates') {
        if (ref($data) eq 'ARRAY' && @$data > 0) {
            my $location = $data->[0];
            return {
                city_name => $location->{name},
                country_code => $location->{country},
                latitude => $location->{lat},
                longitude => $location->{lon},
                state => $location->{state} || ''
            };
        } else {
            die "No location data found";
        }
    }
}

sub _lookup_postal_code_openweather {
    my ($self, $postal_code, $country_code) = @_;
    
    # Use OpenWeatherMap's geocoding API for postal code lookup
    my $api_key = $self->api_key or die "API key is required for postal code lookup";
    my $url = "https://api.openweathermap.org/geo/1.0/zip?zip=$postal_code,$country_code&appid=$api_key";
    
    my $response = $self->ua->get($url);
    
    unless ($response->is_success) {
        die "Postal code lookup request failed: " . $response->status_line;
    }
    
    my $data = decode_json($response->content);
    
    return {
        city_name => $data->{name},
        country_code => $data->{country},
        latitude => $data->{lat},
        longitude => $data->{lon},
        state => $data->{state} || '',
        zip_code => $postal_code
    };
}

=head2 Data normalization methods

=cut

sub _normalize_openweather_current {
    my ($self, $data) = @_;
    
    return {
        temperature => $data->{main}->{temp},
        feels_like => $data->{main}->{feels_like},
        humidity => $data->{main}->{humidity},
        pressure => $data->{main}->{pressure},
        wind_speed => $data->{wind}->{speed},
        wind_direction => $data->{wind}->{deg},
        wind_gust => $data->{wind}->{gust},
        visibility => $data->{visibility} ? $data->{visibility} / 1000 : undef, # Convert to km
        condition_main => $data->{weather}->[0]->{main},
        condition_description => $data->{weather}->[0]->{description},
        weather_icon => $data->{weather}->[0]->{icon},
        cloudiness => $data->{clouds}->{all},
        sunrise => $data->{sys}->{sunrise} ? DateTime->from_epoch(epoch => $data->{sys}->{sunrise})->hms : undef,
        sunset => $data->{sys}->{sunset} ? DateTime->from_epoch(epoch => $data->{sys}->{sunset})->hms : undef,
        location_name => $data->{name},
        timestamp => time(),
        data_source => 'openweathermap',
        raw_data => $data
    };
}

sub _normalize_openweather_forecast {
    my ($self, $data) = @_;
    
    my @forecast_items = ();
    
    foreach my $item (@{$data->{list}}) {
        push @forecast_items, {
            forecast_date => DateTime->from_epoch(epoch => $item->{dt})->ymd,
            forecast_time => DateTime->from_epoch(epoch => $item->{dt})->hms,
            temperature => $item->{main}->{temp},
            feels_like => $item->{main}->{feels_like},
            humidity => $item->{main}->{humidity},
            pressure => $item->{main}->{pressure},
            wind_speed => $item->{wind}->{speed},
            wind_direction => $item->{wind}->{deg},
            condition_main => $item->{weather}->[0]->{main},
            condition_description => $item->{weather}->[0]->{description},
            weather_icon => $item->{weather}->[0]->{icon},
            cloudiness => $item->{clouds}->{all},
            precipitation => $item->{rain}->{'3h'} || $item->{snow}->{'3h'} || 0,
        };
    }
    
    return {
        forecast => \@forecast_items,
        location_name => $data->{city}->{name},
        data_source => 'openweathermap',
        raw_data => $data
    };
}

sub _normalize_weatherapi_current {
    my ($self, $data) = @_;
    
    my $current = $data->{current};
    my $location = $data->{location};
    
    return {
        temperature => $current->{temp_c},
        feels_like => $current->{feelslike_c},
        humidity => $current->{humidity},
        pressure => $current->{pressure_mb},
        wind_speed => $current->{wind_kph} / 3.6, # Convert to m/s
        wind_direction => $current->{wind_degree},
        wind_gust => $current->{gust_kph} ? $current->{gust_kph} / 3.6 : undef,
        visibility => $current->{vis_km},
        uv_index => $current->{uv},
        condition_main => $current->{condition}->{text},
        condition_description => $current->{condition}->{text},
        weather_icon => $current->{condition}->{icon},
        cloudiness => $current->{cloud},
        location_name => $location->{name},
        timestamp => time(),
        data_source => 'weatherapi',
        raw_data => $data
    };
}

sub _normalize_weatherapi_forecast {
    my ($self, $data) = @_;
    
    my @forecast_items = ();
    
    foreach my $day (@{$data->{forecast}->{forecastday}}) {
        my $day_data = $day->{day};
        push @forecast_items, {
            forecast_date => $day->{date},
            temperature => $day_data->{avgtemp_c},
            humidity => $day_data->{avghumidity},
            wind_speed => $day_data->{maxwind_kph} / 3.6, # Convert to m/s
            condition_main => $day_data->{condition}->{text},
            condition_description => $day_data->{condition}->{text},
            weather_icon => $day_data->{condition}->{icon},
            precipitation => $day_data->{totalprecip_mm},
            uv_index => $day_data->{uv},
        };
    }
    
    return {
        forecast => \@forecast_items,
        location_name => $data->{location}->{name},
        data_source => 'weatherapi',
        raw_data => $data
    };
}

__PACKAGE__->meta->make_immutable;

1;

=head1 AUTHOR

Shanta

=head1 LICENSE

This library is free software. You can redistribute it and/or modify
it under the same terms as Perl itself.

=cut