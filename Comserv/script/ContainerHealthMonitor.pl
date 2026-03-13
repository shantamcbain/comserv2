#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Comserv::Util::Logging;
use Sys::Hostname;
use Time::HiRes qw(sleep);
use DBI;

# Initialize logging
my $logger = Comserv::Util::Logging->instance();

# Configuration from Environment with sensible defaults
my $check_interval = $ENV{HEALTH_CHECK_INTERVAL} || 60; # seconds
my $disk_threshold = $ENV{HEALTH_DISK_THRESHOLD} || 90; # percent
my $mem_threshold  = $ENV{HEALTH_MEM_THRESHOLD}  || 95; # percent

$logger->log_with_details(undef, 'info', __FILE__, __LINE__, 'main',
    "Container Health Monitor started on " . $logger->get_system_identifier()
    . ". Interval: ${check_interval}s, Disk: ${disk_threshold}%, Mem: ${mem_threshold}%");

# Main Loop
while (1) {
    eval { check_health() };
    if ($@) {
        $logger->log_with_details(undef, 'error', __FILE__, __LINE__, 'main',
            "Health check cycle failed: $@");
    }
    sleep($check_interval);
}

sub _db_ping {
    # Connect using the same env vars that Catalyst uses (set in docker-compose.yml).
    # This avoids the RemoteDB config lookup which uses different connection names.
    my $host   = $ENV{DB_HOST}     || '192.168.1.198';
    my $port   = $ENV{DB_PORT}     || 3306;
    my $db     = $ENV{DB_NAME}     || 'ency';
    my $user   = $ENV{DB_USERNAME} || $ENV{DB_USER} || '';
    my $pass   = $ENV{DB_PASSWORD} || '';

    # Read credentials from db_config.json if env vars aren't set
    unless ($user) {
        eval {
            require JSON;
            my @paths = (
                "$FindBin::Bin/../db_config.json",
                "/opt/comserv/db_config.json",
            );
            for my $p (@paths) {
                next unless -f $p;
                local $/;
                open my $fh, '<', $p or next;
                my $cfg = JSON::decode_json(<$fh>);
                close $fh;
                for my $key (keys %$cfg) {
                    my $c = $cfg->{$key};
                    next unless ref $c eq 'HASH';
                    next unless ($c->{database} // '') eq $db;
                    $user ||= $c->{username} // $c->{user} // '';
                    $pass ||= $c->{password} // '';
                    last if $user;
                }
                last if $user;
            }
        };
    }

    my $dsn = "dbi:MariaDB:database=$db;host=$host;port=$port";
    my $dbh = eval {
        DBI->connect($dsn, $user, $pass, {
            RaiseError => 1, PrintError => 0, AutoCommit => 1,
            mysql_connect_timeout => 5,
        });
    };
    return 0 unless $dbh;
    my $ok = eval { $dbh->ping };
    eval { $dbh->disconnect };
    return $ok ? 1 : 0;
}

sub check_health {
    # 1. Database Health — use direct DBI connect with Catalyst's env vars
    my $db_ok = _db_ping();
    if (!$db_ok) {
        $logger->log_with_details(undef, 'critical', __FILE__, __LINE__, 'check_health',
            "Primary Database (MySQL: ency) is DOWN or unreachable!");
    } else {
        $logger->log_with_details(undef, 'info', __FILE__, __LINE__, 'check_health',
            "Primary Database (MySQL: ency) is UP");
    }

    # 2. Disk Space Health
    # Check root and NFS if mounted
    check_disk_space('/');
    
    # Check common NFS mount points if they exist
    my @nfs_mounts = qw(/data/nfs /opt/comserv/logs);
    foreach my $mount (@nfs_mounts) {
        if (-d $mount) {
            check_disk_space($mount);
        }
    }

    # 3. Memory Health
    check_memory();
    
    # 4. Process Health (Optional, check if Starman is running)
    # This might be redundant if health check is running inside the same container
}

sub check_disk_space {
    my ($path) = @_;
    
    # Use df -P for POSIX compliant output format
    my $df_output = `df -P "$path" 2>/dev/null | tail -1`;
    if ($df_output && $df_output =~ /(\d+)%/) {
        my $usage = $1;
        if ($usage >= $disk_threshold) {
            $logger->log_with_details(undef, 'ERROR', __FILE__, __LINE__, 'check_disk_space', 
                "Disk usage alert on $path: ${usage}% capacity reached (Threshold: ${disk_threshold}%)");
        }
    }
}

sub check_memory {
    # Linux specific memory check via /proc/meminfo
    if (-f '/proc/meminfo') {
        my $meminfo = `cat /proc/meminfo`;
        my ($total)     = $meminfo =~ /MemTotal:\s+(\d+)/;
        my ($available) = $meminfo =~ /MemAvailable:\s+(\d+)/;
        
        if ($total && $available) {
            my $used_pct = 100 - ($available / $total * 100);
            if ($used_pct >= $mem_threshold) {
                $logger->log_with_details(undef, 'WARN', __FILE__, __LINE__, 'check_memory', 
                    "System memory usage is high: " . sprintf("%.1f", $used_pct) . "% (Threshold: ${mem_threshold}%)");
            }
        }
    }
}
