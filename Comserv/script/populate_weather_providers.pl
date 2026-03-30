#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Comserv::Model::DBEncy;
use Try::Tiny;

print "Populating weather providers table...\n";

# Initialize the database model
my $db_model = Comserv::Model::DBEncy->new;
my $schema = $db_model->schema;

# Weather providers data
my @providers = (
    {
        provider_name => 'OpenWeatherMap',
        api_base_url => 'https://api.openweathermap.org/data/2.5',
        requires_api_key => 1,
        supports_current => 1,
        supports_forecast => 1,
        supports_historical => 0,
        rate_limit_per_minute => 60,
        rate_limit_per_day => 1000,
        documentation_url => 'https://openweathermap.org/api',
        is_active => 1,
    },
    {
        provider_name => 'WeatherAPI',
        api_base_url => 'https://api.weatherapi.com/v1',
        requires_api_key => 1,
        supports_current => 1,
        supports_forecast => 1,
        supports_historical => 1,
        rate_limit_per_minute => 100,
        rate_limit_per_day => 1000000,
        documentation_url => 'https://www.weatherapi.com/docs/',
        is_active => 1,
    },
    {
        provider_name => 'AccuWeather',
        api_base_url => 'http://dataservice.accuweather.com',
        requires_api_key => 1,
        supports_current => 1,
        supports_forecast => 1,
        supports_historical => 0,
        rate_limit_per_minute => 50,
        rate_limit_per_day => 50,
        documentation_url => 'https://developer.accuweather.com/apis',
        is_active => 0, # Not implemented yet
    }
);

try {
    # Check if table exists and has data
    my $existing_count = $schema->resultset('WeatherProviders')->count;
    
    if ($existing_count > 0) {
        print "Weather providers table already has $existing_count records. Skipping population.\n";
        print "Use --force flag to repopulate (not implemented in this script).\n";
        exit 0;
    }
    
    # Insert providers
    foreach my $provider_data (@providers) {
        my $provider = $schema->resultset('WeatherProviders')->create($provider_data);
        print "Created provider: " . $provider->provider_name . " (ID: " . $provider->id . ")\n";
    }
    
    print "\nSuccessfully populated weather providers table with " . scalar(@providers) . " providers.\n";
    
} catch {
    my $error = $_;
    if ($error =~ /doesn't exist/) {
        print "ERROR: WeatherProviders table doesn't exist yet.\n";
        print "Please create the weather tables first using the admin schema comparison tool.\n";
        print "Navigate to: /admin/schema_comparison\n";
        print "Then create tables for: WeatherProviders, WeatherConfig, WeatherData\n";
    } else {
        print "ERROR: Failed to populate weather providers: $error\n";
    }
    exit 1;
};

print "\nWeather providers population completed successfully!\n";
print "\nYou can now:\n";
print "1. Go to /Weather/configuration to set up your weather API\n";
print "2. Test your API configuration\n";
print "3. Start using weather features\n";