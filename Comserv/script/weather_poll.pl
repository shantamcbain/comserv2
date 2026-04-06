#!/usr/bin/env perl
#
# weather_poll.pl — Background weather data poller
#
# Fetches current weather from the configured API and stores it in weather_data.
# Uses a file lock so only ONE instance runs at a time across all app servers.
#
# Recommended cron entry (every 30 minutes):
#   */30 * * * * cd /path/to/Comserv && perl script/weather_poll.pl >> /var/log/weather_poll.log 2>&1
#
# Or run as a daemon loop:
#   while true; do perl script/weather_poll.pl; sleep 1800; done

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use lib "$Bin/../local/lib/perl5";

use Fcntl qw(:flock);
use POSIX qw(strftime);
use JSON;
use LWP::UserAgent;
use URI::Escape;
use Comserv::Model::RemoteDB;
use Comserv::Model::Schema::Ency;

my $LOCK_FILE  = '/tmp/weather_poll.lock';
my $LOG_PREFIX = sub { strftime('[%Y-%m-%d %H:%M:%S]', localtime) . ' weather_poll: ' };

sub log_msg { print $LOG_PREFIX->() . $_[0] . "\n" }

open(my $lock_fh, '>', $LOCK_FILE) or die "Cannot open lock file $LOCK_FILE: $!";
unless (flock($lock_fh, LOCK_EX | LOCK_NB)) {
    log_msg("Another instance is running — skipping.");
    exit 0;
}

log_msg("Starting weather poll.");

my $schema = eval {
    my $remote_db = Comserv::Model::RemoteDB->new();
    my $conn_info  = $remote_db->get_connection_info('ency')
        or die "No ency connection available\n";
    my $conn    = $conn_info->{config};
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
    Comserv::Model::Schema::Ency->connect($dsn, $conn->{username}, $conn->{password}, \%opts);
};
if ($@) {
    log_msg("DB connect failed: $@");
    exit 1;
}

my @configs = eval {
    $schema->resultset('WeatherConfig')->search({ is_active => '1' })->all;
};
if ($@) {
    log_msg("Error reading weather_config: $@");
    exit 1;
}

unless (@configs) {
    log_msg("No active weather configs found — nothing to do.");
    exit 0;
}

my $ua = LWP::UserAgent->new(timeout => 15, agent => 'Comserv-WeatherPoll/1.0');

for my $config (@configs) {
    my $config_id  = $config->id;
    my $api_key    = $config->api_key    or next;
    my $service    = lc($config->api_service || 'openweathermap');
    my $location   = $config->location_value or next;
    my $units      = $config->temperature_units || 'metric';
    my $country    = $config->country_code || '';
    my $method     = $config->location_method || 'city';

    log_msg("Config $config_id: $service, location=$location");

    my $url;
    if ($service eq 'openweathermap') {
        my $loc_param = ($method eq 'city')
            ? "q=" . uri_escape($location) . ($country ? ",$country" : '')
            : "q=" . uri_escape($location);
        $url = "https://api.openweathermap.org/data/2.5/weather?$loc_param&appid=$api_key&units=$units";
    } else {
        log_msg("Unsupported service '$service' — skipping config $config_id.");
        next;
    }

    my $resp = $ua->get($url);
    unless ($resp->is_success) {
        log_msg("API error for config $config_id: " . $resp->status_line);
        next;
    }

    my $data = eval { JSON->new->utf8->decode($resp->content) };
    if ($@ || !$data) {
        log_msg("JSON parse error for config $config_id: $@");
        next;
    }

    if ($data->{cod} && $data->{cod} != 200) {
        log_msg("API returned error for config $config_id: " . ($data->{message} || $data->{cod}));
        next;
    }

    my $sunrise = $data->{sys}{sunrise}
        ? do { my @t = localtime($data->{sys}{sunrise}); sprintf('%02d:%02d:%02d', @t[2,1,0]) } : undef;
    my $sunset  = $data->{sys}{sunset}
        ? do { my @t = localtime($data->{sys}{sunset});  sprintf('%02d:%02d:%02d', @t[2,1,0]) } : undef;

    my %row = (
        config_id             => $config_id,
        data_type             => 'current',
        temperature           => $data->{main}{temp},
        feels_like            => $data->{main}{feels_like},
        humidity              => $data->{main}{humidity},
        pressure              => $data->{main}{pressure},
        wind_speed            => $data->{wind}{speed},
        wind_direction        => $data->{wind}{deg},
        wind_gust             => $data->{wind}{gust},
        visibility            => $data->{visibility} ? $data->{visibility} / 1000 : undef,
        condition_main        => $data->{weather}[0]{main},
        condition_description => $data->{weather}[0]{description},
        weather_icon          => $data->{weather}[0]{icon},
        cloudiness            => $data->{clouds}{all},
        location_name         => $data->{name},
        sunrise               => $sunrise,
        sunset                => $sunset,
        raw_data              => $resp->content,
    );
    delete $row{$_} for grep { !defined $row{$_} } keys %row;

    eval {
        $schema->resultset('WeatherData')->update_or_create(
            \%row,
            { key => 'idx_config_type' }
        );
    };
    if ($@) {
        log_msg("DB write error for config $config_id: $@");
        next;
    }

    log_msg("Stored weather for config $config_id: $row{temperature}°C, $row{condition_description}");

    my %hist = (
        config_id             => $config_id,
        temperature           => $row{temperature},
        feels_like            => $row{feels_like},
        humidity              => $row{humidity},
        pressure              => $row{pressure},
        wind_speed            => $row{wind_speed},
        cloudiness            => $row{cloudiness},
        condition_main        => $row{condition_main},
        condition_description => $row{condition_description},
        weather_icon          => $row{weather_icon},
        location_name         => $row{location_name},
    );
    delete $hist{$_} for grep { !defined $hist{$_} } keys %hist;

    eval {
        $schema->resultset('WeatherHistory')->create(\%hist);
    };
    if ($@) {
        log_msg("History write skipped for config $config_id (table may not exist yet): $@");
    } else {
        log_msg("History row inserted for config $config_id.");
    }
}

flock($lock_fh, LOCK_UN);
close($lock_fh);
log_msg("Poll complete.");
exit 0;
