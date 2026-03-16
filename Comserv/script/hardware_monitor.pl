#!/usr/bin/env perl
use strict;
use warnings;

use POSIX         qw(strftime);
use DBI           ();
use Sys::Hostname qw(hostname);
use Scalar::Util  qw(looks_like_number);

my $json_decode;
BEGIN {
    if (eval { require JSON::XS; 1 }) {
        $json_decode = sub { JSON::XS::decode_json($_[0]) };
    } else {
        require JSON::PP;
        $json_decode = sub { JSON::PP::decode_json($_[0]) };
    }
}

# ---------------------------------------------------------------------------
# Thresholds — determine the level stored in hardware_metrics.level
# The application's HealthLogger reads system_log for warn/error/critical
# and sends email alerts. This script only writes to hardware_metrics.
# ---------------------------------------------------------------------------
my %WARN_AT = (
    cpu_load_pct  => 70,  mem_used_pct  => 80,
    swap_used_pct => 60,  disk_used_pct => 80,
    ipmi_inlet_temp => 35,
);
my %CRIT_AT = (
    cpu_load_pct  => 90,  mem_used_pct  => 92,
    swap_used_pct => 85,  disk_used_pct => 90,
    ipmi_inlet_temp => 40,
);

sub _level {
    my ($name, $val) = @_;
    return 'info' unless defined $val && looks_like_number($val);
    return 'critical' if exists $CRIT_AT{$name} && $val >= $CRIT_AT{$name};
    return 'warn'     if exists $WARN_AT{$name} && $val >= $WARN_AT{$name};
    return 'info';
}

sub _ts { strftime('%Y-%m-%d %H:%M:%S', localtime) }

# ---------------------------------------------------------------------------
# DB — reads same secrets files as the application
# ---------------------------------------------------------------------------
sub _connect {
    my $secrets_dir = $ENV{COMSERV_SECRETS_DIR}
        || "$ENV{HOME}/.comserv/secrets/dbi";

    for my $name (qw(production_server local_ency zerotier_ency backup_ency)) {
        my $file = "$secrets_dir/$name.json";
        next unless -f $file;
        open my $fh, '<', $file or next;
        my $raw = do { local $/; <$fh> };
        close $fh;
        my $cfg = eval { $json_decode->($raw) } or next;
        my $c   = ref($cfg) eq 'ARRAY' ? $cfg->[0] : $cfg;
        next unless $c->{host} && $c->{database};
        my $dsn = "DBI:mysql:database=$c->{database};host=$c->{host};port=" . ($c->{port}||3306);
        my $dbh = eval {
            DBI->connect($dsn, $c->{username}, $c->{password},
                { RaiseError => 1, PrintError => 0, AutoCommit => 1,
                  mysql_connect_timeout => 5 })
        };
        return $dbh if $dbh;
    }
    die "No database connection available\n";
}

# ---------------------------------------------------------------------------
# Metric collectors — return list of { name, value, text, unit }
# ---------------------------------------------------------------------------
sub _cpu {
    open my $fh, '<', '/proc/loadavg' or return ();
    my ($l1, $l5, $l15) = split /\s+/, <$fh>;
    close $fh;
    my $cpus = 1;
    if (open my $cf, '<', '/proc/cpuinfo') {
        $cpus = scalar grep { /^processor\s*:/ } <$cf>;
        close $cf;
    }
    $cpus ||= 1;
    my $pct = sprintf('%.1f', ($l1 / $cpus) * 100);
    return (
        { name => 'cpu_load_1m',  value => $l1,  unit => 'load' },
        { name => 'cpu_load_5m',  value => $l5,  unit => 'load' },
        { name => 'cpu_load_15m', value => $l15, unit => 'load' },
        { name => 'cpu_load_pct', value => $pct, unit => '%'    },
    );
}

sub _mem {
    my %m;
    open my $fh, '<', '/proc/meminfo' or return ();
    while (<$fh>) { $m{$1} = $2 if /^(\w+):\s+(\d+)/ }
    close $fh;
    my $total = $m{MemTotal} || 1;
    my $avail = $m{MemAvailable} || $m{MemFree} || 0;
    my $used_pct  = sprintf('%.1f', (($total - $avail) / $total) * 100);
    my $st = $m{SwapTotal} || 0;
    my $swap_pct  = $st > 0
        ? sprintf('%.1f', (($st - ($m{SwapFree}||0)) / $st) * 100) : 0;
    return (
        { name => 'mem_total_mb',  value => int($total/1024), unit => 'MB' },
        { name => 'mem_used_pct',  value => $used_pct,        unit => '%'  },
        { name => 'swap_used_pct', value => $swap_pct,        unit => '%'  },
    );
}

sub _uptime {
    open my $fh, '<', '/proc/uptime' or return ();
    my ($secs) = split /\s+/, <$fh>;
    close $fh;
    return ({ name => 'uptime_seconds', value => int($secs), unit => 'seconds' });
}

sub _disk {
    my @out;
    open my $fh, '-|', 'df -Pl --output=source,pcent,target 2>/dev/null' or return ();
    while (<$fh>) {
        next if /^Filesystem/;
        chomp;
        my ($dev, $pct_str, $mount) = split /\s+/, $_, 3;
        next unless defined $mount;
        next if $dev =~ /^(tmpfs|devtmpfs|udev|overlay|shm)/;
        (my $pct = $pct_str) =~ s/%//;
        next unless looks_like_number($pct);
        (my $safe = $mount) =~ s{/}{_}g;
        $safe = 'root' unless $safe;
        push @out, { name => "disk_used_pct$safe", value => $pct+0, unit => '%', text => $dev };
    }
    close $fh;
    return @out;
}

sub _ipmi {
    my @out;
    my $ipmitool = `which ipmitool 2>/dev/null`; chomp $ipmitool;
    return () unless $ipmitool && -x $ipmitool;

    for my $line (`ipmitool sdr type "Power Supply" 2>/dev/null`) {
        chomp $line; next unless $line =~ /\S/;
        my ($name, undef, $status) = split /\s*\|\s*/, $line, 4;
        next unless defined $status;
        ($name = lc $name) =~ s/\s+/_/g;
        $status =~ s/^\s+|\s+$//g;
        push @out, { name => "ipmi_psu_$name", text => $status, unit => undef };
    }
    for my $line (`ipmitool sensor get "Pwr Consumption" 2>/dev/null`) {
        push @out, { name => 'ipmi_power_consumption', value => $1+0, unit => 'Watts' }
            if $line =~ /Sensor Reading\s*:\s*([\d.]+)/;
    }
    for my $line (`ipmitool sensor get "Inlet Temp" 2>/dev/null`) {
        push @out, { name => 'ipmi_inlet_temp', value => $1+0, unit => 'C' }
            if $line =~ /Sensor Reading\s*:\s*([\d.]+)/;
    }
    return @out;
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
my $ts   = _ts();
my $host = hostname() || 'unknown';
my $sys  = "$host:monitor";

my $dbh = eval { _connect() };
die "Cannot connect to DB: $@\n" unless $dbh;

my $sth = $dbh->prepare(
    'INSERT INTO hardware_metrics
     (timestamp,system_identifier,hostname,metric_name,metric_value,metric_text,unit,level)
     VALUES (?,?,?,?,?,?,?,?)'
);

for my $m (_cpu(), _mem(), _uptime(), _disk(), _ipmi()) {
    my $lv = _level($m->{name}, $m->{value});
    $sth->execute($ts, $sys, $host,
        $m->{name}, $m->{value}, $m->{text}, $m->{unit}, $lv);
}

$dbh->disconnect();
