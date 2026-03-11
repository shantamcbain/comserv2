#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Comserv::Util::Logging;
use Comserv::Model::RemoteDB;
use Sys::Hostname;
use Time::HiRes qw(sleep);

# Initialize logging and remote DB
my $logger = Comserv::Util::Logging->instance();
my $remote_db = Comserv::Model::RemoteDB->new();

# Configuration from Environment with sensible defaults
my $check_interval = $ENV{HEALTH_CHECK_INTERVAL} || 60; # seconds
my $disk_threshold = $ENV{HEALTH_DISK_THRESHOLD} || 90; # percent
my $mem_threshold  = $ENV{HEALTH_MEM_THRESHOLD}  || 95; # percent

$logger->log_with_details(undef, 'INFO', __FILE__, __LINE__, 'main', 
    "Container Health Monitor started on " . $logger->get_system_identifier() . ". Interval: ${check_interval}s, Disk Threshold: ${disk_threshold}%, Mem Threshold: ${mem_threshold}%");

# Main Loop
while (1) {
    eval {
        check_health();
    };
    if ($@) {
        $logger->log_with_details(undef, 'ERROR', __FILE__, __LINE__, 'main', 
            "Health check cycle failed with error: $@");
    }
    sleep($check_interval);
}

sub check_health {
    # 1. Database Health (MySQL)
    # We check 'ency' as it is the primary database
    my $db_ok = eval { $remote_db->test_connection('ency') };
    if (!$db_ok) {
        $logger->log_with_details(undef, 'CRITICAL', __FILE__, __LINE__, 'check_health', 
            "Primary Database (MySQL: ency) is DOWN or unreachable!");
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
