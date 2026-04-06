#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";

use DBI;

my $DB_HOST = $ENV{DB_HOST} || '192.168.1.198';
my $DB_USER = $ENV{DB_USER} || 'shanta_forager';
my $DB_PASS = $ENV{DB_PASS} || 'UA=nPF8*m+T#';
my $DB_NAME = $ENV{DB_NAME} || 'ency';

print "Populating weather providers table...\n";

my $dbh = DBI->connect(
    "dbi:mysql:database=$DB_NAME;host=$DB_HOST;port=3306",
    $DB_USER, $DB_PASS,
    { RaiseError => 1, AutoCommit => 1, mysql_enable_utf8 => 1 }
) or die "Cannot connect: $DBI::errstr\n";

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

eval {
    my ($existing_count) = $dbh->selectrow_array('SELECT COUNT(*) FROM weather_providers');
    if ($existing_count > 0) {
        print "weather_providers already has $existing_count records. Skipping.\n";
        $dbh->disconnect;
        exit 0;
    }
};
if ($@) {
    print "ERROR checking table (may not exist yet): $@\n";
    print "Please run schema compare in /admin/schema_comparison first.\n";
    $dbh->disconnect;
    exit 1;
}

foreach my $p (@providers) {
    eval {
        $dbh->do(
            'INSERT INTO weather_providers
             (provider_name, api_base_url, requires_api_key, supports_current,
              supports_forecast, supports_historical, rate_limit_per_minute,
              rate_limit_per_day, documentation_url, is_active)
             VALUES (?,?,?,?,?,?,?,?,?,?)',
            undef,
            $p->{provider_name}, $p->{api_base_url}, $p->{requires_api_key},
            $p->{supports_current}, $p->{supports_forecast}, $p->{supports_historical},
            $p->{rate_limit_per_minute}, $p->{rate_limit_per_day},
            $p->{documentation_url}, $p->{is_active},
        );
        print "Created provider: $p->{provider_name}\n";
    };
    warn "ERROR inserting $p->{provider_name}: $@\n" if $@;
}

$dbh->disconnect;
print "\nDone. Go to /Weather/configuration to set your API key.\n";