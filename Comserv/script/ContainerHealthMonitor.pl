#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Comserv::Util::Logging;
use Sys::Hostname;
use Time::HiRes qw(sleep);
use DBI;

my $logger = Comserv::Util::Logging->instance();

my $check_interval = $ENV{HEALTH_CHECK_INTERVAL} || 60;
my $disk_threshold = $ENV{HEALTH_DISK_THRESHOLD} || 85;
my $mem_threshold  = $ENV{HEALTH_MEM_THRESHOLD}  || 95;

my $sys_id   = $ENV{SYSTEM_IDENTIFIER} || $logger->get_system_identifier();
my $hostname = eval { Sys::Hostname::hostname() } || 'unknown-host';
my $db_host  = $ENV{DB_HOST} || '192.168.1.198';
my $db_name  = $ENV{DB_NAME} || 'ency';

my $id_str = "[$sys_id\@$hostname]";

$logger->log_with_details(undef, 'info', __FILE__, __LINE__, 'main',
    "$id_str Container Health Monitor started. "
    . "Interval: ${check_interval}s, Disk: ${disk_threshold}%, Mem: ${mem_threshold}%");

# DB backoff state — when DB is down, increase retry interval to avoid
# hammering the network with 5-second TCP timeouts every 60 seconds.
my $db_down_since   = 0;   # epoch when DB was first found down
my $db_backoff_next = 0;   # next epoch to retry DB check
my $db_backoff_s    = 60;  # current backoff in seconds (grows up to 10 min)
my $db_was_down     = 0;   # flag so we log "back up" when it recovers

# Disk alert state — alert once when threshold crossed, then hourly reminder,
# then log recovery when usage drops back below threshold.
# Key: filesystem path, Value: hashref { alerted=>epoch, remind_next=>epoch }
my %disk_alert_state;

# Main Loop
while (1) {
    eval { check_health() };
    if ($@) {
        $logger->log_with_details(undef, 'error', __FILE__, __LINE__, 'main',
            "[$sys_id] Health check cycle failed: $@");
    }
    sleep($check_interval);
}

sub _db_credentials {
    my $user = $ENV{DB_USERNAME} || $ENV{DB_USER} || '';
    my $pass = $ENV{DB_PASSWORD} || '';
    unless ($user) {
        eval {
            require JSON;
            my @paths = (
                "$FindBin::Bin/../db_config.json",
                "/opt/comserv/db_config.json",
                glob("$ENV{HOME}/.comserv/secrets/db_config.json"),
            );
            for my $p (@paths) {
                next unless $p && -f $p;
                local $/;
                open my $fh, '<', $p or next;
                my $cfg = JSON::decode_json(<$fh>);
                close $fh;
                for my $key (keys %$cfg) {
                    my $c = $cfg->{$key};
                    next unless ref $c eq 'HASH';
                    next unless ($c->{database} // '') eq $db_name;
                    $user ||= $c->{username} // $c->{user} // '';
                    $pass ||= $c->{password} // '';
                    last if $user;
                }
                last if $user;
            }
        };
    }
    return ($user, $pass);
}

sub _db_ping {
    my ($user, $pass) = _db_credentials();
    my $port = $ENV{DB_PORT} || 3306;
    
    if ($user) {
        my $driver = 'MariaDB';
        my $driver_available = 0;
        eval { require DBD::MariaDB; $driver_available = 1; };
        if (!$driver_available) {
            eval { require DBD::mysql; $driver = 'mysql'; $driver_available = 1; };
        }
        
        if ($driver_available) {
            my $dsn = "dbi:$driver:database=$db_name;host=$db_host;port=$port";
            my $dbh = eval {
                local $SIG{ALRM} = sub { die "timeout\n" };
                alarm(4);
                my $h = DBI->connect($dsn, $user, $pass, {
                    RaiseError => 1,
                    PrintError => 0,
                    AutoCommit => 1,
                    ($driver eq 'MariaDB' ? (mariadb_connect_timeout => 2) : (mysql_connect_timeout => 2)),
                });
                alarm(0);
                return $h;
            };
            alarm(0);
            
            if ($dbh) {
                my $ping_ok = eval { $dbh->ping };
                $dbh->disconnect();
                return 1 if $ping_ok;
            }
        }
    }
    
    use IO::Socket::INET;
    my $sock = eval {
        IO::Socket::INET->new(
            PeerAddr => $db_host,
            PeerPort => $port,
            Proto    => 'tcp',
            Timeout  => 3,
        );
    };
    if ($sock) {
        close $sock;
        return 1;
    }
    return 0;
}

sub check_health {
    my $now = time();

    # --- 1. Database health (with backoff when down) ---
    if ($now >= $db_backoff_next) {
        my $db_ok = _db_ping();

        if (!defined $db_ok) {
            # No credentials available — cannot check DB, reset backoff and stay quiet
            $db_backoff_next = $now + $check_interval;
        } elsif (!$db_ok) {
            if (!$db_was_down) {
                $db_was_down  = 1;
                $db_down_since = $now;
                $db_backoff_s  = $check_interval;
                $logger->log_with_details(undef, 'error', __FILE__, __LINE__, 'check_health',
                    "$id_str Primary Database ($db_name \@ $db_host) is DOWN or unreachable. "
                    . "Will retry in ${db_backoff_s}s.");
            } else {
                my $down_min = int(($now - $db_down_since) / 60);
                # Double backoff each time, cap at 10 minutes
                $db_backoff_s = ($db_backoff_s * 2 > 600) ? 600 : $db_backoff_s * 2;
                $logger->log_with_details(undef, 'warn', __FILE__, __LINE__, 'check_health',
                    "$id_str Database still DOWN ($down_min min). Next check in ${db_backoff_s}s.");
            }
            $db_backoff_next = $now + $db_backoff_s;
        } else {
            if ($db_was_down) {
                my $down_min = int(($now - $db_down_since) / 60);
                $logger->log_with_details(undef, 'warn', __FILE__, __LINE__, 'check_health',
                    "$id_str Database RECOVERED after ${down_min} min.");
            }
            $db_was_down     = 0;
            $db_down_since   = 0;
            $db_backoff_s    = $check_interval;
            $db_backoff_next = $now + $check_interval;
        }
    }

    # --- 2. Disk space ---
    check_disk_space('/');

    # --- 3. Memory ---
    check_memory();
}

sub check_disk_space {
    my ($path) = @_;
    my $df_output = `df -P "$path" 2>/dev/null | tail -1`;
    return unless $df_output && $df_output =~ /(\d+)%/;
    my $usage = $1;
    my $now   = time();
    my $state = $disk_alert_state{$path} //= { alerted => 0, remind_next => 0 };

    if ($usage >= $disk_threshold) {
        if (!$state->{alerted}) {
            $state->{alerted}      = $now;
            $state->{remind_next}  = $now + 3600;
            $logger->log_with_details(undef, 'error', __FILE__, __LINE__, 'check_disk_space',
                "$id_str Disk usage alert on $path: ${usage}% (threshold: ${disk_threshold}%)");
        } elsif ($now >= $state->{remind_next}) {
            $state->{remind_next} = $now + 3600;
            my $alert_min = int(($now - $state->{alerted}) / 60);
            $logger->log_with_details(undef, 'error', __FILE__, __LINE__, 'check_disk_space',
                "$id_str Disk still high on $path: ${usage}% — ${alert_min} min above threshold (${disk_threshold}%)");
        }
    } elsif ($state->{alerted}) {
        my $alert_min = int(($now - $state->{alerted}) / 60);
        $logger->log_with_details(undef, 'info', __FILE__, __LINE__, 'check_disk_space',
            "$id_str Disk recovered on $path: ${usage}% — was above threshold for ${alert_min} min");
        $state->{alerted}     = 0;
        $state->{remind_next} = 0;
    }
}

sub check_memory {
    return unless -f '/proc/meminfo';
    my $meminfo = do { local $/; open my $fh, '<', '/proc/meminfo' or return; <$fh> };
    my ($total)     = $meminfo =~ /MemTotal:\s+(\d+)/;
    my ($available) = $meminfo =~ /MemAvailable:\s+(\d+)/;
    if ($total && $available) {
        my $used_pct = 100 - ($available / $total * 100);
        if ($used_pct >= $mem_threshold) {
            $logger->log_with_details(undef, 'warn', __FILE__, __LINE__, 'check_memory',
                "$id_str Memory high: " . sprintf("%.1f", $used_pct) . "% (threshold: ${mem_threshold}%)");
        }
    }
}
