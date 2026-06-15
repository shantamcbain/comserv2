package Comserv::Util::HardwareAgent;
use strict;
use warnings;
use Scalar::Util qw(looks_like_number);

# Collect local metrics (like script/device_agent.sh) and store in hardware_metrics.
# Called from admin dashboard (throttled) so this server always reports even without cron.

sub report_if_due {
    my ($class, $c, $min_interval_sec) = @_;
    $min_interval_sec //= 300;
    return 0 unless $c && eval { $c->model('DBEncy') };

    my $cache = $ENV{COMSERV_HW_AGENT_CACHE} || '/tmp/comserv_hw_agent_last';
    if (-f $cache) {
        my $age = time - (stat($cache))[9];
        return 0 if $age < $min_interval_sec;
    }

    my $count = $class->collect_and_store($c);
    eval { open my $fh, '>', $cache; print $fh time; close $fh };
    return $count;
}

sub collect_and_store {
    my ($class, $c) = @_;
    my $hostname = $ENV{HW_HOSTNAME_OVERRIDE}
                || $ENV{SYSTEM_IDENTIFIER}
                || _short_hostname();
    $hostname =~ s/[^A-Za-z0-9._-]//g;
    return 0 unless $hostname;

    my @metrics = $class->_collect_metrics();
    return 0 unless @metrics;

    my $rs = $c->model('DBEncy')->resultset('HardwareMetrics');
    my $sys_id = "$hostname:agent";
    my $count  = 0;

    for my $m (@metrics) {
        next unless $m->{name};
        my $val = $m->{value};
        eval {
            $rs->create({
                timestamp         => \'NOW()',
                system_identifier => $sys_id,
                hostname          => $hostname,
                metric_name       => $m->{name},
                metric_value      => (defined $val && looks_like_number($val) ? $val + 0 : undef),
                metric_text       => $m->{text},
                unit              => $m->{unit},
                level             => _metric_level($m->{name}, $val),
            });
            $count++;
        };
    }
    return $count;
}

sub _collect_metrics {
    my ($class) = @_;
    my @out;

    my $df = `df -Pk 2>/dev/null` || '';
    for my $line (split /\n/, $df) {
        next if $line =~ /^Filesystem/i;
        my @f = split /\s+/, $line;
        next unless @f >= 6;
        my ($dev, $total_k, $used_k, $avail_k, $pct_str, $mount) = @f[0..5];
        next unless $mount;
        next if $dev =~ /^(tmpfs|devtmpfs|udev|overlay|shm|squashfs|none|loop)/i;
        next if $mount =~ m{^/(sys|proc|dev/pts|run/|snap/)};
        $pct_str =~ s/%//;
        next unless $pct_str =~ /^\d+$/;
        my $safe = $mount;
        $safe =~ s{/}{_}g;
        $safe = 'root' if $safe eq '_' || $safe eq '';
        my $total_mb = int($total_k / 1024);
        my $free_mb  = int($avail_k / 1024);
        push @out,
            { name => "disk_used_pct$safe", value => $pct_str + 0, unit => '%',  text => $dev },
            { name => "disk_total_mb$safe",  value => $total_mb,     unit => 'MB', text => $dev },
            { name => "disk_free_mb$safe",   value => $free_mb,      unit => 'MB', text => $dev };
    }

    if (open my $lf, '<', '/proc/loadavg') {
        my $line = <$lf>;
        close $lf;
        if ($line =~ /^(\S+)\s+(\S+)\s+(\S+)/) {
            my ($l1, $l5, $l15) = ($1, $2, $3);
            my $cpus = 1;
            if (open my $ci, '<', '/proc/cpuinfo') {
                $cpus = grep { /^processor/ } <$ci>;
                close $ci;
            }
            $cpus = 1 unless $cpus > 0;
            my $pct = sprintf('%.1f', ($l1 / $cpus) * 100);
            push @out,
                { name => 'cpu_load_1m',  value => $l1 + 0,  unit => 'load' },
                { name => 'cpu_load_pct', value => $pct + 0, unit => '%' };
        }
    }

    if (open my $mi, '<', '/proc/meminfo') {
        my %mem;
        while (<$mi>) {
            $mem{$1} = $2 if /^(\w+):\s+(\d+)/;
        }
        close $mi;
        if ($mem{MemTotal} && $mem{MemTotal} > 0) {
            my $avail = $mem{MemAvailable} // $mem{MemFree} // 0;
            my $pct = sprintf('%.1f', (($mem{MemTotal} - $avail) / $mem{MemTotal}) * 100);
            push @out, { name => 'mem_used_pct', value => $pct + 0, unit => '%' };
        }
    }

    return @out;
}

sub _short_hostname {
    my $h = `hostname -s 2>/dev/null` || `hostname 2>/dev/null` || 'localhost';
    chomp $h;
    return $h || 'localhost';
}

sub _metric_level {
    my ($name, $val) = @_;
    return 'info' unless defined $val && looks_like_number($val);
    $val += 0;
    if ($name =~ /^disk_used_pct/) {
        return $val >= 90 ? 'critical' : $val >= 80 ? 'warn' : 'ok';
    }
    if ($name eq 'mem_used_pct' || $name eq 'cpu_load_pct') {
        return $val >= 90 ? 'critical' : $val >= 80 ? 'warn' : 'ok';
    }
    return 'info';
}

1;