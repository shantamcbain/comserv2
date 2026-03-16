#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../local/lib/perl5";

use POSIX       qw(strftime);
use File::Spec;
use JSON::XS    ();
use DBI         ();
use Net::SMTP   ();
use Sys::Hostname qw(hostname);
use Scalar::Util qw(looks_like_number);

# ---------------------------------------------------------------------------
# Configuration — alert thresholds and notification address
# ---------------------------------------------------------------------------
my %THRESHOLD = (
    cpu_load_pct   => { warn => 70,  crit => 90  },
    mem_used_pct   => { warn => 80,  crit => 92  },
    disk_used_pct  => { warn => 80,  crit => 90  },
    swap_used_pct  => { warn => 60,  crit => 85  },
);

my $ALERT_TO   = 'helpdesk@computersystemconsulting.ca';
my $ALERT_FROM = 'helpdesk@computersystemconsulting.ca';
my $SMTP_HOST  = $ENV{SMTP_HOST} || '192.168.1.128';
my $SMTP_PORT  = $ENV{SMTP_PORT} || 25;

my $SECRETS_DIR = $ENV{COMSERV_SECRETS_DIR}
    || "$ENV{HOME}/.comserv/secrets/dbi";

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
sub _timestamp { strftime('%Y-%m-%d %H:%M:%S', localtime) }

sub _system_identifier {
    my $host = hostname() || 'unknown';
    return "$host:monitor";
}

sub _log {
    my ($level, $sub, $msg) = @_;
    my $ts   = _timestamp();
    my $sys  = _system_identifier();
    print STDERR "[$ts] [$sys] [script/hardware_monitor.pl] $sub - $msg\n";
}

# ---------------------------------------------------------------------------
# DB connection — reads the same secrets files as RemoteDB.pm
# ---------------------------------------------------------------------------
sub _load_connection {
    my @candidates = qw(production_server local_ency zerotier_ency backup_ency);
    for my $name (@candidates) {
        my $file = "$SECRETS_DIR/$name.json";
        next unless -f $file;
        open my $fh, '<', $file or next;
        my $raw = do { local $/; <$fh> };
        close $fh;
        my $cfg = eval { JSON::XS::decode_json($raw) } or next;
        my $conn = ref($cfg) eq 'ARRAY' ? $cfg->[0] : $cfg;
        next unless $conn->{host} && $conn->{database};

        my $dsn = "DBI:mysql:database=$conn->{database};host=$conn->{host};port=" . ($conn->{port} || 3306);
        my $dbh = eval {
            DBI->connect($dsn, $conn->{username}, $conn->{password}, {
                RaiseError            => 1,
                PrintError            => 0,
                AutoCommit            => 1,
                mysql_connect_timeout => 5,
            });
        };
        if ($dbh) {
            _log('info', '_load_connection', "Connected via $name ($conn->{host})");
            return $dbh;
        }
        _log('warn', '_load_connection', "Failed $name: $@");
    }
    return undef;
}

# ---------------------------------------------------------------------------
# Metric collection
# ---------------------------------------------------------------------------
sub collect_cpu_load {
    my @metrics;
    open my $fh, '<', '/proc/loadavg' or return @metrics;
    my $line = <$fh>;
    close $fh;
    my ($l1, $l5, $l15, $procs) = split /\s+/, $line;

    my $cpus = 1;
    if (open my $cf, '<', '/proc/cpuinfo') {
        $cpus = scalar grep { /^processor\s*:/ } <$cf>;
        close $cf;
    }
    $cpus ||= 1;

    my $pct1  = sprintf('%.1f', ($l1  / $cpus) * 100);
    my $pct5  = sprintf('%.1f', ($l5  / $cpus) * 100);
    my $pct15 = sprintf('%.1f', ($l15 / $cpus) * 100);

    my $level = $pct1 >= $THRESHOLD{cpu_load_pct}{crit} ? 'critical'
              : $pct1 >= $THRESHOLD{cpu_load_pct}{warn}  ? 'warn'
              :                                             'info';

    push @metrics,
        { name => 'cpu_load_1m',   value => $l1,   unit => 'load',     level => $level,
          text => undef, message => "1m load $l1 (${pct1}% of ${cpus} CPUs)" },
        { name => 'cpu_load_5m',   value => $l5,   unit => 'load',     level => 'info',
          text => undef, message => "5m load $l5" },
        { name => 'cpu_load_15m',  value => $l15,  unit => 'load',     level => 'info',
          text => undef, message => "15m load $l15" },
        { name => 'cpu_load_pct',  value => $pct1, unit => '%',        level => $level,
          text => undef, message => "${pct1}% CPU utilisation (1m)" };
    return @metrics;
}

sub collect_memory {
    my @metrics;
    my %m;
    open my $fh, '<', '/proc/meminfo' or return @metrics;
    while (<$fh>) {
        $m{$1} = $2 if /^(\w+):\s+(\d+)/;
    }
    close $fh;

    my $total    = $m{MemTotal}  || 1;
    my $avail    = $m{MemAvailable} || $m{MemFree} || 0;
    my $used     = $total - $avail;
    my $used_pct = sprintf('%.1f', ($used / $total) * 100);

    my $swap_total = $m{SwapTotal} || 0;
    my $swap_free  = $m{SwapFree}  || 0;
    my $swap_used  = $swap_total - $swap_free;
    my $swap_pct   = $swap_total > 0
        ? sprintf('%.1f', ($swap_used / $swap_total) * 100) : 0;

    my $level = $used_pct >= $THRESHOLD{mem_used_pct}{crit} ? 'critical'
              : $used_pct >= $THRESHOLD{mem_used_pct}{warn}  ? 'warn'
              :                                                 'info';
    my $slevel = $swap_pct >= $THRESHOLD{swap_used_pct}{crit} ? 'critical'
               : $swap_pct >= $THRESHOLD{swap_used_pct}{warn}  ? 'warn'
               :                                                   'info';

    push @metrics,
        { name => 'mem_total_mb',  value => int($total/1024),  unit => 'MB', level => 'info',
          text => undef, message => "Total RAM: " . int($total/1024) . " MB" },
        { name => 'mem_used_mb',   value => int($used/1024),   unit => 'MB', level => $level,
          text => undef, message => "Used: " . int($used/1024) . " MB (${used_pct}%)" },
        { name => 'mem_used_pct',  value => $used_pct,         unit => '%',  level => $level,
          text => undef, message => "${used_pct}% memory used" },
        { name => 'swap_used_pct', value => $swap_pct,         unit => '%',  level => $slevel,
          text => undef, message => "${swap_pct}% swap used" };
    return @metrics;
}

sub collect_uptime {
    my @metrics;
    open my $fh, '<', '/proc/uptime' or return @metrics;
    my ($secs) = split /\s+/, <$fh>;
    close $fh;

    my $days  = int($secs / 86400);
    my $hours = int(($secs % 86400) / 3600);
    my $mins  = int(($secs % 3600) / 60);

    my $rebooted = $secs < 600;
    my $level = $rebooted ? 'warn' : 'info';
    my $msg   = "Up ${days}d ${hours}h ${mins}m";
    $msg .= ' — RECENT REBOOT' if $rebooted;

    push @metrics,
        { name => 'uptime_seconds', value => $secs,  unit => 'seconds', level => $level,
          text => undef, message => $msg };
    return @metrics;
}

sub collect_disk {
    my @metrics;
    open my $fh, '-|', 'df -Pl --output=source,pcent,target 2>/dev/null' or return @metrics;
    while (<$fh>) {
        next if /^Filesystem/;
        chomp;
        my ($dev, $pct_str, $mount) = split /\s+/, $_, 3;
        next unless defined $mount;
        next if $dev =~ /^(tmpfs|devtmpfs|udev|overlay|shm)/;
        (my $pct = $pct_str) =~ s/%//;
        next unless looks_like_number($pct);

        my $level = $pct >= $THRESHOLD{disk_used_pct}{crit} ? 'critical'
                  : $pct >= $THRESHOLD{disk_used_pct}{warn}  ? 'warn'
                  :                                             'info';

        (my $safe_mount = $mount) =~ s{/}{_}g;
        $safe_mount = 'root' if $safe_mount eq '_';
        push @metrics, {
            name    => "disk_used_pct_$safe_mount",
            value   => $pct,
            unit    => '%',
            level   => $level,
            text    => $dev,
            message => "Disk $mount: ${pct}% used ($dev)",
        };
    }
    close $fh;
    return @metrics;
}

# Dell PowerEdge 710 — ipmitool IPMI power-supply and sensor data
sub collect_ipmi {
    my @metrics;

    # Check if ipmitool is available
    my $which = `which ipmitool 2>/dev/null`;
    chomp $which;
    return @metrics unless $which && -x $which;

    # Power supply status
    my @psu_lines = `ipmitool sdr type "Power Supply" 2>/dev/null`;
    foreach my $line (@psu_lines) {
        chomp $line;
        next unless $line =~ /\S/;
        # Format: "PSU1 Status       | 03h | ok  | 10.1 |  Presence Detected"
        my ($name, undef, $status) = split /\s*\|\s*/, $line, 4;
        next unless defined $status;
        $name   =~ s/\s+$//;
        $status =~ s/^\s+//;
        my $level = ($status =~ /ok/i) ? 'info'
                  : ($status =~ /nc|nr/i) ? 'warn'
                  :                         'critical';
        push @metrics, {
            name    => 'ipmi_psu_' . lc($name =~ s/\s+/_/gr),
            value   => undef,
            unit    => undef,
            level   => $level,
            text    => $status,
            message => "IPMI $name: $status",
        };
    }

    # Power consumption (watts)
    my @pwr = `ipmitool sensor get "Pwr Consumption" 2>/dev/null`;
    foreach my $line (@pwr) {
        if ($line =~ /Sensor Reading\s*:\s*([\d.]+)\s*(\S*)/) {
            my ($val, $unit) = ($1, $2 || 'Watts');
            push @metrics, {
                name    => 'ipmi_power_consumption',
                value   => $val,
                unit    => $unit,
                level   => 'info',
                text    => undef,
                message => "Power consumption: $val $unit",
            };
        }
    }

    # Inlet temperature
    my @temp = `ipmitool sensor get "Inlet Temp" 2>/dev/null`;
    foreach my $line (@temp) {
        if ($line =~ /Sensor Reading\s*:\s*([\d.]+)\s*(\S*)/) {
            my ($val, $unit) = ($1, $2 || 'degrees C');
            my $level = $val >= 40 ? 'critical'
                      : $val >= 35 ? 'warn'
                      :              'info';
            push @metrics, {
                name    => 'ipmi_inlet_temp',
                value   => $val,
                unit    => $unit,
                level   => $level,
                text    => undef,
                message => "Inlet temperature: $val $unit",
            };
        }
    }

    return @metrics;
}

# ---------------------------------------------------------------------------
# DB write helpers
# ---------------------------------------------------------------------------
sub _insert_metric {
    my ($dbh, $sys, $host, $ts, $m) = @_;
    eval {
        $dbh->do(
            'INSERT INTO hardware_metrics
             (timestamp, system_identifier, hostname, metric_name,
              metric_value, metric_text, unit, level, message)
             VALUES (?,?,?,?,?,?,?,?,?)',
            undef,
            $ts, $sys, $host,
            $m->{name}, $m->{value}, $m->{text},
            $m->{unit}, $m->{level}, $m->{message},
        );
    };
    if ($@) {
        _log('error', '_insert_metric', "DB insert failed for $m->{name}: $@");
    }
}

sub _insert_system_log {
    my ($dbh, $sys, $ts, $level, $sub, $msg) = @_;
    eval {
        $dbh->do(
            'INSERT INTO system_log
             (timestamp, level, file, line, subroutine, message,
              sitename, system_identifier)
             VALUES (?,?,?,?,?,?,?,?)',
            undef,
            $ts, $level,
            'script/hardware_monitor.pl', 0, $sub,
            $msg, 'CSC', $sys,
        );
    };
    if ($@) {
        _log('error', '_insert_system_log', "system_log insert failed: $@");
    }
}

# ---------------------------------------------------------------------------
# Email alert
# ---------------------------------------------------------------------------
sub _send_alert {
    my ($sys, $subject, $body) = @_;

    my $smtp = eval {
        Net::SMTP->new($SMTP_HOST,
            Port    => $SMTP_PORT,
            Timeout => 10,
        );
    };
    unless ($smtp) {
        _log('error', '_send_alert', "Cannot connect to SMTP $SMTP_HOST:$SMTP_PORT — $@");
        return;
    }

    $smtp->mail($ALERT_FROM);
    $smtp->to($ALERT_TO);
    $smtp->data();
    $smtp->datasend("From: $ALERT_FROM\n");
    $smtp->datasend("To: $ALERT_TO\n");
    $smtp->datasend("Subject: [$sys] Hardware Alert: $subject\n");
    $smtp->datasend("Content-Type: text/plain; charset=UTF-8\n");
    $smtp->datasend("\n");
    $smtp->datasend($body);
    $smtp->dataend();
    $smtp->quit();
    _log('info', '_send_alert', "Alert sent: $subject");
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
sub main {
    my $ts   = _timestamp();
    my $sys  = _system_identifier();
    my $host = hostname() || 'unknown';

    _log('info', 'main', "Hardware monitor run starting on $host");

    my $dbh = _load_connection();
    unless ($dbh) {
        _log('critical', 'main', "No DB connection available — metrics not recorded");
        _send_alert($sys, 'DB connection failed',
            "[$ts] [$sys] hardware_monitor.pl could not connect to any database.\n"
            . "Metrics collection skipped.\n");
        exit 1;
    }

    my @all_metrics = (
        collect_uptime(),
        collect_cpu_load(),
        collect_memory(),
        collect_disk(),
        collect_ipmi(),
    );

    my @alerts;
    for my $m (@all_metrics) {
        _insert_metric($dbh, $sys, $host, $ts, $m);

        if ($m->{level} eq 'critical' || $m->{level} eq 'error') {
            _insert_system_log($dbh, $sys, $ts, $m->{level}, 'hardware_monitor', $m->{message});
            push @alerts, $m;
        } elsif ($m->{level} eq 'warn') {
            _insert_system_log($dbh, $sys, $ts, 'warn', 'hardware_monitor', $m->{message});
        }

        _log($m->{level}, 'collect', $m->{message}) if $m->{level} ne 'info';
    }

    if (@alerts) {
        my $subject = join(', ', map { $_->{name} } @alerts);
        my $body    = "Hardware alert on $host at $ts\n\n";
        for my $a (@alerts) {
            $body .= uc($a->{level}) . " - $a->{name}: $a->{message}\n";
        }
        $body .= "\nSystem: $sys\n";
        _send_alert($sys, $subject, $body);
    }

    $dbh->disconnect();
    _log('info', 'main', "Hardware monitor run complete — " . scalar(@all_metrics) . " metrics recorded");
}

main();
