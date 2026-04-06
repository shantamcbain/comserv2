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
    if ($name =~ /_temp$/) {
        return 'critical' if $val >= 80;
        return 'warn'     if $val >= 65;
        return 'info';
    }
    return 'critical' if exists $CRIT_AT{$name} && $val >= $CRIT_AT{$name};
    return 'warn'     if exists $WARN_AT{$name} && $val >= $WARN_AT{$name};
    return 'info';
}

sub _ts { strftime('%Y-%m-%d %H:%M:%S', gmtime) }

# ---------------------------------------------------------------------------
# DB — reads same secrets files as the application
# ---------------------------------------------------------------------------
sub _connect {
    my $secrets_dir = $ENV{COMSERV_SECRETS_DIR}
        || "$ENV{HOME}/.comserv/secrets/dbi";

    my $driver = 'mysql';
    my %timeout_attr = (mysql_connect_timeout => 5);
    if (eval { require DBD::MariaDB; 1 }) {
        $driver = 'MariaDB';
        %timeout_attr = (mariadb_connect_timeout => 5);
    }

    for my $name (qw(production_server zerotier_ency backup_ency local_ency)) {
        my $file = "$secrets_dir/$name.json";
        next unless -f $file;
        open my $fh, '<', $file or next;
        my $raw = do { local $/; <$fh> };
        close $fh;
        my $cfg = eval { $json_decode->($raw) } or next;
        my $c;
        if (ref($cfg) eq 'ARRAY') {
            $c = $cfg->[0];
        } elsif (ref($cfg) eq 'HASH') {
            $c = exists $cfg->{host} ? $cfg : (values %$cfg)[0];
        }
        next unless ref($c) eq 'HASH' && $c->{host} && $c->{database};
        next if $c->{host} =~ /^YOUR_/ || $c->{username} =~ /^YOUR_/;
        my $dsn = "DBI:$driver:database=$c->{database};host=$c->{host};port=" . ($c->{port}||3306);
        my $dbh = eval {
            DBI->connect($dsn, $c->{username}, $c->{password},
                { RaiseError => 1, PrintError => 0, AutoCommit => 1, %timeout_attr })
        };
        return $dbh if $dbh;
    }
    die "No database connection available\n";
}

# ---------------------------------------------------------------------------
# Metric collectors — return list of { name, value, text, unit }
# ---------------------------------------------------------------------------
my $IS_FREEBSD = ($^O eq 'freebsd');

sub _cpu {
    my ($l1, $l5, $l15, $cpus);
    if ($IS_FREEBSD) {
        my $avg = `sysctl -n vm.loadavg 2>/dev/null`; chomp $avg;
        ($l1, $l5, $l15) = ($avg =~ /\{\s*([\d.]+)\s+([\d.]+)\s+([\d.]+)/);
        $cpus = `sysctl -n hw.ncpu 2>/dev/null`; chomp $cpus; $cpus ||= 1;
    } else {
        open my $fh, '<', '/proc/loadavg' or return ();
        ($l1, $l5, $l15) = split /\s+/, <$fh>; close $fh;
        if (open my $cf, '<', '/proc/cpuinfo') {
            $cpus = scalar grep { /^processor\s*:/ } <$cf>; close $cf;
        }
    }
    $cpus ||= 1;
    return () unless defined $l1;
    my $pct = sprintf('%.1f', ($l1 / $cpus) * 100);
    return (
        { name => 'cpu_load_1m',  value => $l1,  unit => 'load' },
        { name => 'cpu_load_5m',  value => $l5,  unit => 'load' },
        { name => 'cpu_load_15m', value => $l15, unit => 'load' },
        { name => 'cpu_load_pct', value => $pct, unit => '%'    },
    );
}

sub _mem {
    if ($IS_FREEBSD) {
        my $total_bytes = `sysctl -n hw.physmem 2>/dev/null`; chomp $total_bytes;
        my $page_size   = `sysctl -n hw.pagesize 2>/dev/null`; chomp $page_size;
        my $free_pages  = `sysctl -n vm.stats.vm.v_free_count 2>/dev/null`; chomp $free_pages;
        my $inact_pages = `sysctl -n vm.stats.vm.v_inactive_count 2>/dev/null`; chomp $inact_pages;
        return () unless $total_bytes && $page_size;
        $page_size  ||= 4096; $free_pages ||= 0; $inact_pages ||= 0;
        my $avail_bytes = ($free_pages + $inact_pages) * $page_size;
        my $used_pct = sprintf('%.1f', (($total_bytes - $avail_bytes) / $total_bytes) * 100);
        return (
            { name => 'mem_total_mb', value => int($total_bytes/1024/1024), unit => 'MB' },
            { name => 'mem_used_pct', value => $used_pct, unit => '%' },
        );
    }
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
    if ($IS_FREEBSD) {
        my $boot = `sysctl -n kern.boottime 2>/dev/null`; chomp $boot;
        my ($sec) = ($boot =~ /sec\s*=\s*(\d+)/);
        return () unless $sec;
        return ({ name => 'uptime_seconds', value => int(time() - $sec), unit => 'seconds' });
    }
    open my $fh, '<', '/proc/uptime' or return ();
    my ($secs) = split /\s+/, <$fh>; close $fh;
    return ({ name => 'uptime_seconds', value => int($secs), unit => 'seconds' });
}

sub _disk {
    my @out;
    my $cmd = $^O eq 'freebsd'
        ? 'df -k 2>/dev/null'
        : 'df -Pk 2>/dev/null';
    open my $fh, '-|', $cmd or return ();
    while (<$fh>) {
        next if /^Filesystem/;
        chomp;
        my ($dev, $total_k, $used_k, $avail_k, $pct_str, $mount) = split /\s+/, $_, 6;
        next unless defined $mount;
        next if $dev  =~ /^(tmpfs|devtmpfs|udev|overlay|shm|squashfs|none|loop)/;
        next if $mount =~ m{^(/sys|/proc|/dev/pts|/run/|/snap/)};
        (my $pct = $pct_str) =~ s/%//;
        next unless looks_like_number($pct);
        (my $safe = $mount) =~ s{/}{_}g;
        $safe = 'root' unless $safe;
        my $total_mb = $total_k > 0 ? int($total_k / 1024) : undef;
        my $free_mb  = $avail_k > 0 ? int($avail_k / 1024) : 0;
        push @out,
            { name => "disk_used_pct$safe",  value => $pct+0,     unit => '%',  text => $dev },
            { name => "disk_total_mb$safe",   value => $total_mb,  unit => 'MB', text => $dev },
            { name => "disk_free_mb$safe",    value => $free_mb,   unit => 'MB', text => $dev };
    }
    close $fh;
    return @out;
}

sub _temp {
    my @out;
    if ($IS_FREEBSD) {
        for my $line (`sysctl -a 2>/dev/null`) {
            if ($line =~ /^dev\.cpu\.(\d+)\.temperature:\s*([\d.]+)C/) {
                push @out, { name => "cpu${1}_temp", value => $2+0, unit => 'C' };
            }
        }
        return @out;
    }
    my $zone = 0;
    for my $path (glob('/sys/class/thermal/thermal_zone*/temp')) {
        open my $fh, '<', $path or next;
        my $raw = <$fh>; close $fh; chomp $raw;
        next unless looks_like_number($raw) && $raw > 0;
        my $c = sprintf('%.1f', $raw / 1000);
        (my $type_path = $path) =~ s/temp$/type/;
        my $label = "cpu${zone}_temp";
        if (open my $tf, '<', $type_path) { my $t = <$tf>; chomp $t; $label = lc($t) . '_temp'; close $tf; }
        push @out, { name => $label, value => $c+0, unit => 'C' };
        $zone++;
    }
    unless (@out) {
        my $cpu_num = 0;
        for my $hwmon (sort glob('/sys/class/hwmon/hwmon*')) {
            my $name_file = "$hwmon/name";
            next unless -f $name_file;
            open my $nf, '<', $name_file or next;
            my $name = <$nf>; close $nf; chomp $name;
            next unless $name eq 'coretemp';
            my $max_raw = 0;
            for my $input_file (glob("$hwmon/temp*_input")) {
                open my $tf, '<', $input_file or next;
                my $raw = <$tf>; close $tf; chomp $raw;
                next unless looks_like_number($raw) && $raw > 0;
                $max_raw = $raw if $raw > $max_raw;
            }
            next unless $max_raw > 0;
            my $c = sprintf('%.1f', $max_raw / 1000);
            push @out, { name => "cpu${cpu_num}_max_temp", value => $c+0, unit => 'C' };
            $cpu_num++;
        }
    }
    return @out;
}

sub _ipmi {
    my @out;
    my $ipmitool = `which ipmitool 2>/dev/null`; chomp $ipmitool;
    return () unless $ipmitool && -x $ipmitool;

    for my $line (`ipmitool sdr type "Power Supply" 2>/dev/null`) {
        chomp $line; next unless $line =~ /\S/;
        my ($name, undef, $status, $entity, $desc) = split /\s*\|\s*/, $line, 5;
        next unless defined $status;
        ($name = lc($name // '')) =~ s/\s+/_/g;
        $status  =~ s/^\s+|\s+$//g if $status;
        $entity  =~ s/^\s+|\s+$//g if $entity;
        $desc    =~ s/^\s+|\s+$//g if $desc;
        my $label;
        if ($entity && $entity =~ /^(\d+)\.(\d+)$/) {
            $label = "ipmi_ps${2}_${name}";
        } else {
            $label = "ipmi_psu_$name";
        }
        push @out, { name => $label, text => ($desc || $status), unit => undef };
    }
    my $ps_num = 1;
    for my $line (`ipmitool sdr type "Current" 2>/dev/null`) {
        chomp $line; next unless $line =~ /\S/;
        my ($name, undef, $status, $entity, undef) = split /\s*\|\s*/, $line, 5;
        next unless defined $status && $status =~ /ok/i;
        my ($amps) = ($line =~ /([\d.]+)\s*Amps/i);
        next unless defined $amps;
        push @out, { name => "ipmi_ps${ps_num}_current", value => $amps+0, unit => 'A' };
        $ps_num++;
    }

    for my $sensor_name ("System Level", "Pwr Consumption", "Total Power") {
        my @lines = `ipmitool sensor get "$sensor_name" 2>/dev/null`;
        next unless @lines;
        for my $line (@lines) {
            if ($line =~ /Sensor Reading\s*:\s*([\d.]+)/) {
                push @out, { name => 'ipmi_power_consumption', value => $1+0, unit => 'Watts' };
                last;
            }
        }
        last if grep { $_->{name} eq 'ipmi_power_consumption' } @out;
    }
    for my $sensor_name ("Inlet Temp", "Ambient Temp", "System Inlet Temp") {
        my @lines = `ipmitool sensor get "$sensor_name" 2>/dev/null`;
        next unless @lines;
        for my $line (@lines) {
            if ($line =~ /Sensor Reading\s*:\s*([\d.]+)/) {
                push @out, { name => 'ipmi_inlet_temp', value => $1+0, unit => 'C' };
                last;
            }
        }
        last if grep { $_->{name} eq 'ipmi_inlet_temp' } @out;
    }
    for my $line (`ipmitool sdr type "Temperature" 2>/dev/null`) {
        chomp $line;
        my ($sname, undef, $status, undef, undef) = split /\s*\|\s*/, $line, 5;
        next unless defined $status && $status =~ /ok/i;
        next unless $sname;
        $sname =~ s/^\s+|\s+$//g;
        next if $sname =~ /inlet|ambient/i;
        my ($val) = ($line =~ /([\d.]+)\s*degrees/i);
        next unless defined $val;
        (my $label = lc($sname)) =~ s/\s+/_/g;
        $label = "ipmi_${label}_temp";
        push @out, { name => $label, value => $val+0, unit => 'C' };
    }
    return @out;
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
my $host = hostname() || 'unknown';
my $sys  = "$host:monitor";

my $dbh = eval { _connect() };
die "Cannot connect to DB: $@\n" unless $dbh;

my $sth_hw = $dbh->prepare(
    'INSERT INTO hardware_metrics
     (timestamp,system_identifier,hostname,metric_name,metric_value,metric_text,unit,level)
     VALUES (NOW(),?,?,?,?,?,?,?)'
);

my $sth_log = $dbh->prepare(
    'INSERT INTO system_log
     (timestamp,level,subroutine,message,sitename,system_identifier)
     VALUES (NOW(),?,?,?,?,?)'
);

for my $m (_cpu(), _mem(), _uptime(), _disk(), _temp(), _ipmi()) {
    my $lv = _level($m->{name}, $m->{value});
    $sth_hw->execute($sys, $host,
        $m->{name}, $m->{value}, $m->{text}, $m->{unit}, $lv);

    if ($lv eq 'warn' || $lv eq 'critical' || $lv eq 'error') {
        my $val_str = defined $m->{value} ? "$m->{value}" . ($m->{unit} ? " $m->{unit}" : '') : ($m->{text}//'');
        my $msg = "[HARDWARE][$host] $m->{name} = $val_str ($lv)";
        eval { $sth_log->execute($lv, 'hardware_monitor.pl', $msg, 'CSC', $sys) };
    }
}

$dbh->disconnect();
