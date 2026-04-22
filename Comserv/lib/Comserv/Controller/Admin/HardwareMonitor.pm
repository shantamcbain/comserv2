package Comserv::Controller::Admin::HardwareMonitor;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;
use Comserv::Util::AdminAuth;
use Comserv::Util::EmailNotification;
use JSON ();
use Scalar::Util qw(looks_like_number);
use List::Util ();
use POSIX qw(strftime mktime);

BEGIN { extends 'Comserv::Controller::Base'; }

has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

my @GRAPH_METRICS = qw(
    cpu_load_pct mem_used_pct swap_used_pct
    ipmi_power_consumption ipmi_inlet_temp
    ipmi_ps1_current ipmi_ps2_current
);
my $TEMP_METRIC_RE = qr/_temp$/;
my $DISK_METRIC_RE = qr/^disk_/;

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

sub _metric_level {
    my ($name, $val) = @_;
    return 'info' unless defined $val && looks_like_number($val);
    if ($name =~ /_temp$/) {
        return 'critical' if $val >= 80;
        return 'warn'     if $val >= 65;
        return 'info';
    }
    my $base = $name;
    $base =~ s/_[^_]+$// if $name =~ /^disk_used_pct_/;
    $base = 'disk_used_pct' if $name =~ /^disk_used_pct/;
    return 'critical' if exists $CRIT_AT{$base} && $val >= $CRIT_AT{$base};
    return 'warn'     if exists $WARN_AT{$base} && $val >= $WARN_AT{$base};
    return 'info';
}

sub index :Path('/admin/hardware_monitor') :Args(0) {
    my ($self, $c) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
        'Loading hardware monitor dashboard');

    my $filter_host   = $c->req->param('filter_host')   // '';
    my $filter_metric = $c->req->param('filter_metric')  // '';
    my $filter_level  = $c->req->param('filter_level')   // '';
    my $filter_hours  = $c->req->param('filter_hours')   || 2;

    my @metrics;
    my @hosts;
    my @metric_names;
    my %chart_data;
    my $db_error = '';

    eval {
        my $rs = $c->model('DBEncy')->resultset('HardwareMetrics');

        my %search = ();
        $search{hostname}    = $filter_host   if $filter_host;
        $search{metric_name} = $filter_metric if $filter_metric;
        $search{level}       = $filter_level  if $filter_level;
        $search{timestamp}   = { '>=' => \"DATE_SUB(NOW(), INTERVAL $filter_hours HOUR)" }
            if $filter_hours;

        # Table: most recent rows in window (newest first), no arbitrary row cap
        my @rows = $rs->search(
            \%search,
            { order_by => { -desc => 'timestamp' } }
        );
        @metrics = map { {
            id                => $_->id,
            timestamp         => $_->timestamp,
            system_identifier => $_->system_identifier,
            hostname          => $_->hostname,
            metric_name       => $_->metric_name,
            metric_value      => $_->metric_value,
            metric_text       => $_->metric_text,
            unit              => $_->unit,
            level             => $_->level,
            message           => $_->message,
        } } @rows;

        # Chart data: separate unlimited query for graphable metrics only
        my @disk_pct_metrics = $rs->search(
            { metric_name => { -like => 'disk_used_pct%' }, %search },
            { columns => ['metric_name'], distinct => 1 }
        )->get_column('metric_name')->all;

        my @graph_metric_names = (@GRAPH_METRICS, @disk_pct_metrics, $rs->search(
            { metric_name => { -like => '%_temp' }, %search },
            { columns => ['metric_name'], distinct => 1 }
        )->get_column('metric_name')->all);

        my %graph_search = (%search, metric_name => { -in => \@graph_metric_names });
        my @chart_rows = $rs->search(
            \%graph_search,
            { order_by => { -asc => 'timestamp' } }
        );

        my %_seen_slot;
        for my $row (@chart_rows) {
            my $mn = $row->metric_name;
            next unless defined $row->metric_value;
            my $ts = $row->timestamp;
            if ($ts =~ /^(\d{4}-\d{2}-\d{2} \d{2}):(\d{2})/) {
                my $slot_min = int($2 / 5) * 5;
                $ts = sprintf('%s:%02d:00', $1, $slot_min);
            }
            my $slot_key = "$mn|" . $row->hostname . "|$ts";
            next if $_seen_slot{$slot_key}++;
            push @{ $chart_data{$mn}{ $row->hostname } },
                [ $ts, $row->metric_value + 0 ];
        }
        for my $mn (keys %chart_data) {
            for my $h (keys %{ $chart_data{$mn} }) {
                $chart_data{$mn}{$h} = [ sort { $a->[0] cmp $b->[0] } @{ $chart_data{$mn}{$h} } ];
            }
        }

        my @host_rs = $rs->search(
            {},
            { columns => ['hostname'], distinct => 1, order_by => 'hostname' }
        );
        @hosts = map { $_->hostname } @host_rs;

        my @name_rs = $rs->search(
            {},
            { columns => ['metric_name'], distinct => 1, order_by => 'metric_name' }
        );
        @metric_names = map { $_->metric_name } @name_rs;
    };
    if ($@) {
        $db_error = "$@";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'index',
            "hardware_metrics query failed: $db_error");
    }

    my %latest;
    for my $m (@metrics) {
        my $key = "$m->{hostname}|$m->{metric_name}";
        $latest{$key} //= $m;
    }

    my %LEVEL_RANK = (info => 0, warn => 1, error => 2, critical => 3);

    my %ipmi_cards;
    my %disk_by_host;   # hostname => [ { mount, pct, device, total_mb, free_mb, level } ]
    my @other_latest;
    for my $key (sort keys %latest) {
        my $m = $latest{$key};
        if ($m->{metric_name} =~ /^ipmi_/) {
            $ipmi_cards{ $m->{hostname} }{ $m->{metric_name} } = $m;
        } elsif ($m->{metric_name} =~ /^disk_used_pct(.*)/) {
            my $mount = $1;
            $mount =~ s{^_}{/};
            $mount =~ s{_}{/}g;
            $mount = '/' unless $mount;
            # Skip virtual/system mount points (efivars, sysfs, etc.)
            next if $mount =~ m{^(/sys|/proc|/run/|/dev/pts|/snap/)};
            my $total_key = "disk_total_mb$1";
            my $free_key  = "disk_free_mb$1";
            push @{ $disk_by_host{ $m->{hostname} } }, {
                mount    => $mount,
                pct      => $m->{metric_value},
                device   => $m->{metric_text} // '',
                total_mb => ($latest{"$m->{hostname}|$total_key"}{metric_value} // undef),
                free_mb  => ($latest{"$m->{hostname}|$free_key"}{metric_value}  // undef),
                level    => $m->{level},
                timestamp=> $m->{timestamp},
            };
        } else {
            push @other_latest, $m;
        }
    }

    my @disk_hosts;
    for my $host (sort keys %disk_by_host) {
        my @mounts = sort { $a->{mount} cmp $b->{mount} } @{ $disk_by_host{$host} };
        my $worst  = 'info';
        for my $d (@mounts) {
            $worst = $d->{level} if ($LEVEL_RANK{$d->{level}//''} // 0) > ($LEVEL_RANK{$worst} // 0);
        }
        push @disk_hosts, { hostname => $host, mounts => \@mounts, worst_level => $worst };
    }

    my @power_cards_sorted;
    for my $host (sort keys %ipmi_cards) {
        my $pw    = $ipmi_cards{$host};
        my $worst = 'info';
        for my $mn (keys %$pw) {
            my $lv = $pw->{$mn}{level} // 'info';
            $worst = $lv if ($LEVEL_RANK{$lv}//0) > ($LEVEL_RANK{$worst}//0);
        }
        push @power_cards_sorted, {
            hostname               => $host,
            worst_level            => $worst,
            ipmi_power_consumption => $pw->{ipmi_power_consumption},
            ipmi_ps1_current       => $pw->{ipmi_ps1_current},
            ipmi_ps2_current       => $pw->{ipmi_ps2_current},
            ipmi_ps1_status        => $pw->{ipmi_ps1_status},
            ipmi_ps2_status        => $pw->{ipmi_ps2_status},
            ipmi_ps_redundancy     => $pw->{ipmi_psu_ps_redundancy},
            ipmi_inlet_temp        => $pw->{ipmi_inlet_temp},
        };
    }

    # Build set of NFS/network client mount points so we can exclude them from charts
    my %net_mounts;
    if (open my $dfh, '-|', 'df', '-PT') {
        while (my $line = <$dfh>) {
            chomp $line;
            next if $line =~ /^Filesystem/;
            my ($fs, $type, undef, undef, undef, undef, $mnt) = split /\s+/, $line;
            if ($type && $mnt && $type =~ /^(nfs|nfs4|cifs|smbfs|sshfs|fuse\.sshfs|davfs|glusterfs)$/) {
                $net_mounts{$mnt} = 1;
            }
        }
        close $dfh;
    }
    my $is_net_mount = sub {
        my $metric = shift;
        (my $mnt = $metric) =~ s/^disk_used_pct//;
        $mnt =~ s{^_}{/}; $mnt =~ s{_}{/}g;
        return $net_mounts{$mnt} ? 1 : 0;
    };

    my %in_order   = map { $_ => 1 } @GRAPH_METRICS;
    my @ordered    = grep { exists $chart_data{$_} } @GRAPH_METRICS;
    push @ordered, grep {
        /^disk_used_pct/ && !$in_order{$_} && exists $chart_data{$_} && do {
            (my $mnt = $_) =~ s/^disk_used_pct//;
            $mnt =~ s{^_}{/}; $mnt =~ s{_}{/}g;
            $mnt !~ m{^(/sys|/proc|/run/|/dev/pts|/snap/)} && !$net_mounts{$mnt};
        }
    } sort keys %chart_data;
    push @ordered, grep { /$TEMP_METRIC_RE/ && !$in_order{$_} } sort keys %chart_data;
    my $chart_json = JSON::encode_json([ map { { metric => $_, hosts => $chart_data{$_} } } @ordered ]);

    # Separate disk chart JSON for the Drive Space section
    my @disk_ordered = grep {
        /^disk_used_pct/ && exists $chart_data{$_} && do {
            (my $mnt = $_) =~ s/^disk_used_pct//;
            $mnt =~ s{^_}{/}; $mnt =~ s{_}{/}g;
            $mnt !~ m{^(/sys|/proc|/run/|/dev/pts|/snap/)};
        }
    } sort keys %chart_data;
    my $disk_chart_json = JSON::encode_json([ map { { metric => $_, hosts => $chart_data{$_} } } @disk_ordered ]);

    $c->stash(
        template        => 'admin/HardwareMonitor/index.tt',
        metrics         => \@metrics,
        latest          => \@other_latest,
        disk_hosts      => \@disk_hosts,
        power_cards     => \@power_cards_sorted,
        hosts           => \@hosts,
        metric_names    => \@metric_names,
        graph_metrics   => \@GRAPH_METRICS,
        chart_data_json => $chart_json,
        disk_chart_json => $disk_chart_json,
        filter_host     => $filter_host,
        filter_metric   => $filter_metric,
        filter_level    => $filter_level,
        filter_hours    => $filter_hours,
        db_error        => $db_error,
        ingest_token    => ($ENV{HW_INGEST_TOKEN} // 'changeme'),
        ingest_url      => _ingest_url($c),
    );
}

sub _ingest_url {
    my ($c) = @_;
    # Use HW_INGEST_BASE_URL env var if set (recommended for production)
    return "$ENV{HW_INGEST_BASE_URL}/admin/hardware_monitor/ingest"
        if $ENV{HW_INGEST_BASE_URL};

    # Detect the server's own LAN IP so remote machines can reach it
    my $lan_ip = do {
        my $ip = '';
        # Try to find the IP on the same subnet as the NFS server / LAN
        eval {
            require Socket;
            my $sock;
            if (Socket::inet_aton('192.168.1.1')) {
                socket($sock, Socket::PF_INET(), Socket::SOCK_DGRAM(), 0);
                connect($sock, Socket::pack_sockaddr_in(80, Socket::inet_aton('192.168.1.1')));
                $ip = Socket::inet_ntoa((Socket::unpack_sockaddr_in(getsockname($sock)))[1]);
                close $sock;
            }
        };
        $ip || '127.0.0.1';
    };

    my $port = $c->req->uri->port // 3001;
    return "http://${lan_ip}:${port}/admin/hardware_monitor/ingest";
}

# ---------------------------------------------------------------------------
# GET/POST /admin/hardware_monitor/disk_diagnose
# Drill into any host/mount to find what's consuming disk space.
# For localhost: runs du directly. For remote: uses SSH.
# POST actions: delete, move_to_nfs, compress
# ---------------------------------------------------------------------------
my %LOCAL_HOSTS = map { $_ => 1 } qw(
    workstation workstation.local workstation.computersystemconsulting.ca
    localhost 127.0.0.1 192.168.1.199
);
my $NFS_BASE = '/data/nfs';

sub disk_diagnose :Path('/admin/hardware_monitor/disk_diagnose') :Args(0) {
    my ($self, $c) = @_;

    $c->stash(template => 'admin/HardwareMonitor/disk_diagnose.tt');

    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->get_admin_type($c) ne 'none') {
        $c->response->redirect($c->uri_for('/'));
        return;
    }

    my $hostname = $c->req->param('hostname') // 'workstation';
    my $path     = $c->req->param('path')     // '/';
    my $action   = $c->req->param('action')   // '';

    $hostname =~ s/[^A-Za-z0-9._\-]//g;
    $path =~ s/\.\.//g;
    $path =~ s/[\x00-\x1f\x7f]//g;
    $path = '/' unless $path =~ m{^/};
    $path =~ s{/+}{/}g;

    my $is_local = $LOCAL_HOSTS{ lc($hostname) } // 0;
    my @entries;
    my $error;
    my $action_result;
    my $ssh_hint;

    my $TIMEOUT = 20;  # seconds before giving up on du

    my $run_cmd = sub {
        my (@cmd) = @_;
        if ($is_local) {
            require IPC::Open3;
            my ($in, $out, $err_fh);
            open $err_fh, '>', '/dev/null';
            my $pid = eval { IPC::Open3::open3($in, $out, $err_fh, @cmd) };
            if ($@ || !$pid) {
                open my $fh, '-|', @cmd or return (undef, "Cannot run: $cmd[0]: $!");
                my @lines = <$fh>;
                close $fh;
                return (\@lines, undef);
            }
            my @lines;
            my $timed_out = 0;
            eval {
                local $SIG{ALRM} = sub { $timed_out = 1; kill 'TERM', $pid; die "timeout\n" };
                alarm($TIMEOUT);
                @lines = <$out>;
                alarm(0);
            };
            alarm(0);
            waitpid($pid, 0);
            return (\@lines, $timed_out ? "Scan timed out after ${TIMEOUT}s — directory may be very large" : undef);
        } else {
            my $ssh_user = $ENV{HW_SSH_USER} // 'root';
            my @ssh = ('ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5',
                       '-o', 'StrictHostKeyChecking=no', "$ssh_user\@$hostname", @cmd);
            open my $fh, '-|', @ssh or return (undef, "SSH failed: $!");
            my @lines = <$fh>;
            close $fh;
            if ($? != 0 && !@lines) {
                my $cmd_str = join(' ', @cmd);
                return (undef, "SSH to $hostname failed. Run manually: ssh $ssh_user\@$hostname $cmd_str");
            }
            return (\@lines, undef);
        }
    };

    if ($action && $c->req->method eq 'POST') {
        my $target = $c->req->param('target') // '';
        $target =~ s/\.\.//g;
        $target =~ s/[\x00-\x1f\x7f]//g;

        my $_db_orphan_path = sub {
            my $deleted_path = shift;
            eval {
                my $schema = $c->model('DBEncy');
                my $rs = $schema->resultset('File')->search([
                    { file_path => { 'like', "$deleted_path%" } },
                    { nfs_path  => { 'like', "$deleted_path%" } },
                ]);
                my $count = 0;
                while (my $rec = $rs->next) {
                    $rec->update({ file_status => 'orphaned' });
                    $count++;
                }
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'disk_diagnose_delete',
                    "Marked $count DB record(s) orphaned after delete of '$deleted_path'") if $count;
            };
        };

        my $_do_delete = sub {
            my $t = shift;
            return "Skipped: empty path" unless length $t;
            return "Skipped: invalid path '$t'" unless $t =~ m{^/} && $t ne '/';
            my $result;
            if ($is_local) {
                require File::Path;
                if (-f $t) {
                    my $ok = unlink $t;
                    $result = $ok ? "Deleted: $t" : "Delete failed: $t: $!";
                } else {
                    eval { File::Path::remove_tree($t, { safe => 0 }) };
                    $result = $@ ? "Delete failed: $t: $@" : "Deleted: $t";
                }
            } else {
                my ($out, $err) = $run_cmd->('rm', '-rf', '--', $t);
                $result = $err // "Deleted on $hostname: $t";
            }
            $_db_orphan_path->($t) if $result =~ /^Deleted/;
            return $result;
        };

        if ($action eq 'delete' && $target && $target =~ m{^/} && $target ne '/') {
            $action_result = $_do_delete->($target);
        } elsif ($action eq 'delete_selected') {
            my @targets = $c->req->param('target');
            my @results;
            for my $t (@targets) {
                $t =~ s/\.\.//g;
                $t =~ s/[\x00-\x1f\x7f]//g;
                push @results, $_do_delete->($t);
            }
            $action_result = @results ? join('; ', @results) : 'No items selected.';
        } elsif ($action eq 'move_to_nfs' && $target && $target =~ m{^/}) {
            my $dest_name = (split '/', $target)[-1];
            my $dest      = "$NFS_BASE/archive/$dest_name";
            if ($is_local) {
                require File::Path;
                File::Path::make_path("$NFS_BASE/archive");
                my $ret = system('mv', '--', $target, $dest);
                $action_result = $ret == 0 ? "Moved to NFS: $dest" : "Move failed (exit $ret)";
            } else {
                my ($out, $err) = $run_cmd->('mv', '--', $target, $dest);
                $action_result = $err // "Moved on $hostname: $target -> $dest";
            }
        } elsif ($action eq 'compress' && $target && $target =~ m{^/} && $target ne '/') {
            my $archive = "$target.tar.gz";
            if ($is_local) {
                my $ret = system('tar', '-czf', $archive, '--remove-files', '--', $target);
                $action_result = $ret == 0 ? "Compressed to: $archive" : "Compress failed (exit $ret)";
            } else {
                my ($out, $err) = $run_cmd->('tar', '-czf', $archive, '--remove-files', '--', $target);
                $action_result = $err // "Compressed on $hostname: $archive";
            }
        }
    }

    my %NET_FS = map { $_ => 1 } qw(nfs nfs4 cifs smbfs sshfs fuse.sshfs davfs glusterfs);

    # Build a map of mount_point -> fstype for local host so we can tag/skip network mounts
    my %mount_fstype;
    if ($is_local) {
        if (open my $dfh, '-|', 'df', '-PT') {
            while (my $dfl = <$dfh>) {
                chomp $dfl;
                next if $dfl =~ /^Filesystem/;
                my ($fs, $type, undef, undef, undef, undef, $mnt) = split /\s+/, $dfl;
                $mount_fstype{$mnt} = $type if defined $mnt && defined $type;
            }
            close $dfh;
        }
    }

    my $to_bytes = sub {
        my $s = shift // '0';
        my %mul = (K=>1024, M=>1024**2, G=>1024**3, T=>1024**4, P=>1024**5);
        $s =~ /^([\d.]+)([KMGTP]?)/i;
        return ($1 // 0) * ($mul{uc($2||'B')} // 1);
    };

    my $calc_sizes = $c->req->param('calc_sizes') ? 1 : 0;

    if ($is_local) {
        (my $path_clean = $path) =~ s{/+}{/}g;
        my @children = sort glob("$path_clean/*"), glob("$path_clean/.*");
        @children = grep { my $n = (split '/', $_)[-1]; $n ne '.' && $n ne '..' } @children;
        for my $entry_path (@children) {
            $entry_path =~ s{/+}{/}g;
            my $name   = (split '/', $entry_path)[-1];
            my $is_dir = -d $entry_path;
            my $fstype = $mount_fstype{$entry_path} // '';
            my $is_net = $NET_FS{$fstype} ? 1 : 0;
            my ($size, $bytes);
            if ($is_dir) {
                if ($calc_sizes && !$is_net) {
                    my ($lines2, undef) = $run_cmd->('du', '-shx', '--', $entry_path);
                    if ($lines2 && @$lines2) {
                        ($size) = ($lines2->[0] =~ /^(\S+)/);
                        $bytes = $to_bytes->($size);
                    }
                }
                $size  //= '?';
                $bytes //= -1;
            } else {
                $bytes = (stat $entry_path)[7] // 0;
                $size  = $bytes >= 1073741824 ? sprintf('%.1fG', $bytes/1073741824)
                       : $bytes >= 1048576    ? sprintf('%.1fM', $bytes/1048576)
                       : $bytes >= 1024       ? sprintf('%.1fK', $bytes/1024)
                       : "${bytes}B";
            }
            push @entries, {
                size     => $size,
                bytes    => $is_net ? 0 : $bytes,
                raw_size => $bytes,
                path     => $entry_path,
                name     => $name,
                is_dir   => $is_dir,
                fstype   => $fstype || 'local',
                is_net   => $is_net,
            };
        }
        @entries = sort {
            ($b->{is_dir} // 0) <=> ($a->{is_dir} // 0)
            || ($b->{bytes} // 0) <=> ($a->{bytes} // 0)
        } @entries;
    } else {
        my $ssh_user = $ENV{HW_SSH_USER} // 'root';
        if (open my $fh, '-|', 'ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5',
                '-o', 'StrictHostKeyChecking=no', "$ssh_user\@$hostname",
                "du -shx -- $path/* 2>/dev/null") {
            my @lines_arr = <$fh>;
            close $fh;
            if ($? != 0 && !@lines_arr) {
                $error = "SSH to $hostname failed. Ensure SSH keys are configured for $ssh_user\@$hostname.";
                $ssh_hint = "ssh root\@$hostname du -sh $path/*";
            } else {
                for my $line (@lines_arr) {
                    chomp $line;
                    next unless $line =~ /^(\S+)\s+(.+)$/;
                    my ($size, $entry_path) = ($1, $2);
                    my $name = (split '/', $entry_path)[-1];
                    push @entries, {
                        size => $size, bytes => $to_bytes->($size),
                        raw_size => $to_bytes->($size),
                        path => $entry_path, name => $name,
                        is_dir => 1, fstype => 'remote', is_net => 0,
                    };
                }
                @entries = sort { $b->{bytes} <=> $a->{bytes} } @entries;
            }
        } else {
            $error = "Cannot open SSH to $hostname: $!";
        }
    }

    my @crumb_parts;
    my @segments = grep { length } split '/', $path;
    my $crumb_acc = '';
    for my $seg (@segments) {
        $crumb_acc .= "/$seg";
        push @crumb_parts, { label => $seg, path => $crumb_acc };
    }

    $c->stash(
        template      => 'admin/HardwareMonitor/disk_diagnose.tt',
        hostname      => $hostname,
        path          => $path,
        is_local      => $is_local,
        entries       => \@entries,
        crumb_parts   => \@crumb_parts,
        error         => $error,
        ssh_hint      => $ssh_hint,
        action_result => $action_result,
        nfs_base      => $NFS_BASE,
        calc_sizes    => $calc_sizes,
    );
}

# ---------------------------------------------------------------------------
# POST /admin/hardware_monitor/ingest
# Remote device agents POST JSON metrics here.
# Auth: X-Ingest-Token header (or ?token= param) must match HW_INGEST_TOKEN.
# Body: { "hostname": "myserver", "metrics": [ {"name":"disk_used_pct_root","value":42,"unit":"%","text":"/dev/sda1"} ] }
# ---------------------------------------------------------------------------
sub ingest :Path('/admin/hardware_monitor/ingest') :Args(0) {
    my ($self, $c) = @_;

    unless ($c->req->method eq 'POST') {
        $c->response->status(405);
        $c->response->content_type('application/json');
        $c->response->body(JSON::encode_json({ ok => 0, error => 'POST required' }));
        return;
    }

    my $expected = $ENV{HW_INGEST_TOKEN} // 'changeme';
    my $provided  = $c->req->header('X-Ingest-Token')
                 // $c->req->param('token')
                 // '';
    unless ($provided eq $expected) {
        $c->response->status(403);
        $c->response->content_type('application/json');
        $c->response->body(JSON::encode_json({ ok => 0, error => 'Invalid token' }));
        return;
    }

    my $body = eval { JSON::decode_json($c->req->body_data // $c->req->body // '{}') };
    if ($@ || !ref $body) {
        $c->response->status(400);
        $c->response->content_type('application/json');
        $c->response->body(JSON::encode_json({ ok => 0, error => 'Invalid JSON' }));
        return;
    }

    my $hostname = $body->{hostname} // $c->req->address // 'unknown';
    $hostname =~ s/[^A-Za-z0-9._-]//g;
    my $sys_id   = "$hostname:agent";
    my $metrics  = $body->{metrics} // [];
    my $count    = 0;

    eval {
        my $rs = $c->model('DBEncy')->resultset('HardwareMetrics');
        for my $m (@$metrics) {
            next unless ref($m) eq 'HASH' && $m->{name};
            my $name  = $m->{name};  $name =~ s/[^A-Za-z0-9_.:-]//g;
            my $val   = $m->{value};
            my $text  = $m->{text};
            my $unit  = $m->{unit};
            my $level = $self->_metric_level($name, $val);
            $rs->create({
                timestamp         => \'NOW()',
                system_identifier => $sys_id,
                hostname          => $hostname,
                metric_name       => $name,
                metric_value      => (defined $val && looks_like_number($val) ? $val+0 : undef),
                metric_text       => $text,
                unit              => $unit,
                level             => $level,
            });
            $count++;
        }
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'ingest',
            "ingest failed for $hostname: $@");
        $c->response->status(500);
        $c->response->content_type('application/json');
        $c->response->body(JSON::encode_json({ ok => 0, error => "DB error: $@" }));
        return;
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'ingest',
        "Ingested $count metrics from $hostname");

    $self->_check_disk_alerts($c, $hostname, $body->{metrics} // []);

    $c->response->content_type('application/json');
    $c->response->body(JSON::encode_json({ ok => 1, count => $count, hostname => $hostname }));
}

sub _check_disk_alerts {
    my ($self, $c, $hostname, $metrics) = @_;

    my $schema = eval { $c->model('DBEncy') };
    return unless $schema;

    my $alert_rs = eval { $schema->resultset('HealthAlert') };
    return unless $alert_rs;

    my $email_util = Comserv::Util::EmailNotification->new();
    my $admin_email = 'helpdesk@computersystemconsulting.ca';

    for my $m (@$metrics) {
        next unless ref($m) eq 'HASH';
        my $name  = $m->{name} // '';
        next unless $name =~ /^disk_used_pct/;
        my $val   = $m->{value} // 0;
        next unless looks_like_number($val);

        my $level = _metric_level($name, $val);
        next unless $level eq 'warn' || $level eq 'critical';

        my $mount_text = $m->{text} // $name;
        my $db_level   = uc($level eq 'critical' ? 'CRITICAL' : 'HIGH');
        my $category   = 'DISK_SPACE';
        my $description = sprintf(
            "Disk usage on %s mount %s is at %.1f%% (%s)",
            $hostname, $mount_text, $val, $db_level
        );

        eval {
            my $existing = $alert_rs->search({
                category          => $category,
                system_identifier => "$hostname:$name",
                status            => 'OPEN',
            }, { order_by => { -desc => 'last_seen' }, rows => 1 })->single;

            my $now_str = strftime('%Y-%m-%d %H:%M:%S', localtime);

            if ($existing) {
                my $last_seen_epoch = do {
                    my $ls = $existing->last_seen // '';
                    $ls =~ /(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})/;
                    $1 ? mktime($6,$5,$4,$3,$2-1,$1-1900) : 0;
                };
                $existing->update({
                    last_seen        => $now_str,
                    level            => $db_level,
                    description      => $description,
                    occurrence_count => $existing->occurrence_count + 1,
                });
                if ($level eq 'critical' && (time() - $last_seen_epoch) > 14400) {
                    $email_util->send_error_notification($c, $admin_email,
                        "CRITICAL: Disk space on $hostname",
                        "$description\n\nCheck /admin/hardware_monitor/disk_health for cleanup options.");
                }
            } else {
                $alert_rs->create({
                    first_seen        => $now_str,
                    last_seen         => $now_str,
                    level             => $db_level,
                    category          => $category,
                    description       => $description,
                    occurrence_count  => 1,
                    status            => 'OPEN',
                    system_identifier => "$hostname:$name",
                });
                $email_util->send_error_notification($c, $admin_email,
                    "$db_level: Disk space alert on $hostname",
                    "$description\n\nView details: /admin/hardware_monitor/disk_diagnose?hostname=$hostname\nCleanup options: /admin/hardware_monitor/disk_health");
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'ingest',
                    "Disk alert created: $description");
            }
        };
        if ($@) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, '_check_disk_alerts',
                "Alert check failed for $hostname $name: $@");
        }
    }
}

sub drive_detail :Path('/admin/hardware_monitor/drive_detail') :Args(0) {
    my ($self, $c) = @_;

    $c->stash(template => 'admin/HardwareMonitor/DriveDetail.tt');

    my $host  = $c->req->param('host')  // '';
    my $mount = $c->req->param('mount') // '/';
    $mount =~ s{\.\.}{}g;
    $mount = '/' unless length $mount;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'drive_detail',
        "Drive detail requested: host=$host mount=$mount");

    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->get_admin_type($c) ne 'none') {
        $c->flash->{error_msg} = 'Access denied.';
        $c->response->redirect($c->uri_for('/'));
        return;
    }

    my %disk_info;
    eval {
        my $rs = $c->model('DBEncy')->resultset('HardwareMetrics');
        my $base = $mount;
        $base =~ s{^/}{};
        $base =~ s{/}{_}g;
        $base = '_' . $base if $base;
        my $metric_key = "disk_used_pct$base";

        my $latest_pct = $rs->search(
            { hostname => $host, metric_name => $metric_key },
            { order_by => { -desc => 'timestamp' }, rows => 1 }
        )->single;

        my $total_key = "disk_total_mb$base";
        my $free_key  = "disk_free_mb$base";
        my $latest_total = $rs->search(
            { hostname => $host, metric_name => $total_key },
            { order_by => { -desc => 'timestamp' }, rows => 1 }
        )->single;
        my $latest_free = $rs->search(
            { hostname => $host, metric_name => $free_key },
            { order_by => { -desc => 'timestamp' }, rows => 1 }
        )->single;

        $disk_info{pct}      = $latest_pct   ? $latest_pct->metric_value   : undef;
        $disk_info{total_mb} = $latest_total ? $latest_total->metric_value  : undef;
        $disk_info{free_mb}  = $latest_free  ? $latest_free->metric_value   : undef;
        if (defined $disk_info{total_mb} && defined $disk_info{free_mb}) {
            $disk_info{used_mb} = $disk_info{total_mb} - $disk_info{free_mb};
        }
    };
    my $err = "$@" if $@;
    if ($err) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'drive_detail',
            "Could not fetch disk metrics from DB: $err");
    }

    my @dir_sizes;
    my $local_mount = $mount;
    if (-d $local_mount) {
        eval {
            my $du_out = qx{du -d 1 -m \Q$local_mount\E 2>/dev/null};
            for my $line (split /\n/, $du_out) {
                next unless $line =~ /^(\d+)\s+(.+)$/;
                my ($mb, $path) = ($1, $2);
                next if $path eq $local_mount;
                my $name = $path;
                $name =~ s{^\Q$local_mount\E/?}{};
                push @dir_sizes, {
                    path    => $path,
                    name    => $name,
                    mb      => $mb,
                    is_dir  => (-d $path) ? 1 : 0,
                };
            }
            @dir_sizes = sort { $b->{mb} <=> $a->{mb} } @dir_sizes;
        };
        my $du_err = "$@" if $@;
        if ($du_err) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'drive_detail',
                "du failed on $local_mount: $du_err");
        }
    }

    my @files_in_root;
    if (-d $local_mount) {
        eval {
            opendir(my $dh, $local_mount);
            while (my $e = readdir($dh)) {
                next if $e =~ /^\./;
                my $full = "$local_mount/$e";
                my $size = -d $full ? undef : (-s $full // 0);
                push @files_in_root, {
                    name    => $e,
                    path    => $full,
                    is_dir  => (-d $full) ? 1 : 0,
                    size    => $size,
                    size_kb => defined $size ? int($size / 1024) : undef,
                };
            }
            closedir($dh);
            @files_in_root = sort { ($b->{is_dir} <=> $a->{is_dir}) || ($a->{name} cmp $b->{name}) } @files_in_root;
        };
    }

    my $can_browse = -d $local_mount ? 1 : 0;

    $c->stash(
        host         => $host,
        mount        => $mount,
        disk_info    => \%disk_info,
        dir_sizes    => \@dir_sizes,
        files        => \@files_in_root,
        can_browse   => $can_browse,
        file_browser_url => $c->uri_for('/file/admin_browser', { dir_path => $local_mount }),
    );
    $c->forward($c->view('TT'));
}

sub disk_health :Path('/admin/hardware_monitor/disk_health') :Args(0) {
    my ($self, $c) = @_;

    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->get_admin_type($c) ne 'none') {
        $c->flash->{error_msg} = 'Access denied.';
        $c->response->redirect($c->uri_for('/'));
        return;
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'disk_health',
        'Disk health page accessed');

    my $schema = $c->model('DBEncy');
    my %data;

    # ── 1. Open disk-space health alerts ─────────────────────────────
    my @open_alerts;
    eval {
        @open_alerts = $schema->resultset('HealthAlert')->search(
            { category => 'DISK_SPACE', status => 'OPEN' },
            { order_by => { -desc => 'last_seen' } }
        )->all;
    };

    # ── 2. Local df snapshot ─────────────────────────────────────────
    my @df_rows;
    eval {
        my $df_out = `df -h --output=source,target,size,used,avail,pcent 2>/dev/null || df -h 2>/dev/null`;
        for my $line (split /\n/, $df_out) {
            next if $line =~ /^Filesystem|^tmpfs|^udev|^overlay|^shm/i;
            my @f = split /\s+/, $line;
            next unless @f >= 6;
            my ($dev, $mount, $size, $used, $avail, $pct) = @f[0..5];
            $pct =~ s/%//;
            my $level = $pct >= 90 ? 'critical' : $pct >= 80 ? 'warn' : 'ok';
            push @df_rows, {
                device => $dev, mount => $mount,
                size   => $size, used => $used, avail => $avail,
                pct    => $pct,  level => $level,
            };
        }
    };

    # ── 3. NFS disk usage ─────────────────────────────────────────────
    my $nfs_root = '/data/nfs';
    $nfs_root = $ENV{NFS_ROOT} if $ENV{NFS_ROOT};
    my %nfs_usage;
    if (-d $nfs_root) {
        eval {
            my $out = `df -h --output=size,used,avail,pcent \Q$nfs_root\E 2>/dev/null | tail -1`;
            if ($out =~ /(\S+)\s+(\S+)\s+(\S+)\s+(\d+)%/) {
                $nfs_usage{size} = $1; $nfs_usage{used} = $2;
                $nfs_usage{avail} = $3; $nfs_usage{pct} = $4;
                $nfs_usage{level} = $4 >= 90 ? 'critical' : $4 >= 80 ? 'warn' : 'ok';
            }
        };
    }

    # ── 4. Duplicate files ────────────────────────────────────────────
    my ($dup_count, $dup_size_mb) = (0, 0);
    eval {
        my @dups = $schema->resultset('File')->search(
            { is_duplicate => 1 },
            { columns => ['file_size'] }
        )->all;
        $dup_count = scalar @dups;
        $dup_size_mb = int(
            (List::Util::sum(map { $_->file_size // 0 } @dups) // 0) / 1_048_576
        );
    };

    # ── 5. Orphaned DB records ────────────────────────────────────────
    my $orphaned_count = 0;
    eval {
        $orphaned_count = $schema->resultset('File')->search(
            { file_status => 'orphaned' }
        )->count;
    };

    # ── 6. Application log sizes ──────────────────────────────────────
    my @log_files;
    my $log_dir = $c->config->{home} . '/logs';
    if (-d $log_dir) {
        opendir(my $dh, $log_dir);
        while (my $f = readdir $dh) {
            next if $f =~ /^\./;
            my $path = "$log_dir/$f";
            next unless -f $path;
            my $sz = (stat $path)[7] // 0;
            push @log_files, {
                name    => $f,
                path    => $path,
                size_mb => sprintf('%.1f', $sz / 1_048_576),
            };
        }
        closedir $dh;
        @log_files = sort { $b->{size_mb} <=> $a->{size_mb} } @log_files;
    }

    # ── 7. Docker disk usage ──────────────────────────────────────────
    my $docker_df = '';
    eval { $docker_df = `docker system df 2>/dev/null` // ''; };

    # ── 8. Acknowledge alert action ───────────────────────────────────
    if ($c->req->method eq 'POST') {
        my $action   = $c->req->param('action')   // '';
        my $alert_id = $c->req->param('alert_id') // '';

        if ($action eq 'acknowledge' && $alert_id =~ /^\d+$/) {
            eval {
                my $alert = $schema->resultset('HealthAlert')->find($alert_id);
                if ($alert) {
                    $alert->update({ status => 'ACKNOWLEDGED' });
                    $c->flash->{success_msg} = "Alert #$alert_id acknowledged.";
                }
            };
        } elsif ($action eq 'resolve' && $alert_id =~ /^\d+$/) {
            eval {
                my $alert = $schema->resultset('HealthAlert')->find($alert_id);
                if ($alert) {
                    $alert->update({
                        status      => 'RESOLVED',
                        resolved_at => strftime('%Y-%m-%d %H:%M:%S', localtime),
                    });
                    $c->flash->{success_msg} = "Alert #$alert_id resolved.";
                }
            };
        } elsif ($action eq 'purge_orphaned') {
            eval {
                my $n = $schema->resultset('File')->search({ file_status => 'orphaned' })->delete;
                $c->flash->{success_msg} = "Purged $n orphaned database records.";
            };
        }
        $c->response->redirect($c->uri_for('/admin/hardware_monitor/disk_health'));
        return;
    }

    $c->stash(
        open_alerts    => \@open_alerts,
        df_rows        => \@df_rows,
        nfs_root       => $nfs_root,
        nfs_usage      => \%nfs_usage,
        dup_count      => $dup_count,
        dup_size_mb    => $dup_size_mb,
        orphaned_count => $orphaned_count,
        log_files      => \@log_files,
        docker_df      => $docker_df,
        template       => 'admin/HardwareMonitor/DiskHealth.tt',
    );
    $c->forward($c->view('TT'));
}

__PACKAGE__->meta->make_immutable;
1;
