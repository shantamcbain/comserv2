package Comserv::Controller::Admin::HardwareMonitor;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;
use JSON ();
use Scalar::Util qw(looks_like_number);

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

    my %in_order   = map { $_ => 1 } @GRAPH_METRICS;
    my @ordered    = grep { exists $chart_data{$_} } @GRAPH_METRICS;
    push @ordered, grep {
        /^disk_used_pct/ && !$in_order{$_} && exists $chart_data{$_} && do {
            (my $mnt = $_) =~ s/^disk_used_pct//;
            $mnt =~ s{^_}{/}; $mnt =~ s{_}{/}g;
            $mnt !~ m{^(/sys|/proc|/run/|/dev/pts|/snap/)};
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
my $NFS_BASE = '/home/shanta/nfs';

sub disk_diagnose :Path('/admin/hardware_monitor/disk_diagnose') :Args(0) {
    my ($self, $c) = @_;

    # Set template FIRST so it renders even if something below fails
    $c->stash(template => 'admin/HardwareMonitor/disk_diagnose.tt');

    my $role = $c->session->{role} // '';
    unless ($role eq 'admin' || $role eq 'superadmin') {
        $c->response->redirect($c->uri_for('/'));
        return;
    }

    my $hostname = $c->req->param('hostname') // 'workstation';
    my $path     = $c->req->param('path')     // '/';
    my $action   = $c->req->param('action')   // '';

    # Sanitise
    $hostname =~ s/[^A-Za-z0-9._\-]//g;
    $path =~ s/[^A-Za-z0-9_.\/\-]//g;
    $path = '/' unless $path =~ m{^/};
    $path =~ s{/+}{/}g;

    my $is_local = $LOCAL_HOSTS{ lc($hostname) } // 0;
    my @entries;
    my $error;
    my $action_result;
    my $ssh_hint;

    # Helper: run a command locally or via SSH, return output lines
    my $run_cmd = sub {
        my (@cmd) = @_;
        if ($is_local) {
            open my $fh, '-|', @cmd or return (undef, "Cannot run: $cmd[0]: $!");
            my @lines = <$fh>;
            close $fh;
            return (\@lines, undef);
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

    # POST actions
    if ($action && $c->req->method eq 'POST') {
        my $target = $c->req->param('target') // '';
        $target =~ s/[^A-Za-z0-9_.\/\-]//g;

        if ($action eq 'delete' && $target && $target =~ m{^/} && $target ne '/') {
            if ($is_local) {
                require File::Path;
                eval { File::Path::remove_tree($target, { safe => 0 }) };
                $action_result = $@ ? "Delete failed: $@" : "Deleted: $target";
            } else {
                my ($out, $err) = $run_cmd->('rm', '-rf', '--', $target);
                $action_result = $err // "Deleted on $hostname: $target";
            }
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
                $action_result = $err // "Moved on $hostname: $target → $dest";
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

    # Run du on current path
    # For local: expand glob here. For remote: let the shell expand via sh -c.
    my ($lines, $err);
    if ($is_local) {
        my @children = glob("$path/*");
        ($lines, $err) = @children
            ? $run_cmd->('du', '-shx', '--', @children)
            : ([], undef);
    } else {
        my $ssh_user = $ENV{HW_SSH_USER} // 'root';
        if (open my $fh, '-|', 'ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5',
                '-o', 'StrictHostKeyChecking=no', "$ssh_user\@$hostname",
                "du -shx -- $path/* 2>/dev/null") {
            my @lines_arr = <$fh>;
            close $fh;
            if ($? != 0 && !@lines_arr) {
                $err = "SSH to $hostname failed. Ensure SSH keys are configured for $ssh_user\@$hostname.";
            } else {
                $lines = \@lines_arr;
            }
        } else {
            $err = "Cannot open SSH to $hostname: $!";
        }
    }
    if ($err) {
        $error    = $err;
        $ssh_hint = !$is_local ? "ssh root\@$hostname du -sh $path/*" : undef;
    } else {
        my $to_bytes = sub {
            my $s = shift // '0';
            my %mul = (K=>1024, M=>1024**2, G=>1024**3, T=>1024**4, P=>1024**5);
            $s =~ /^([\d.]+)([KMGTP]?)/i;
            return ($1 // 0) * ($mul{uc($2||'B')} // 1);
        };
        for my $line (@{ $lines // [] }) {
            chomp $line;
            next unless $line =~ /^(\S+)\s+(.+)$/;
            my ($size, $entry_path) = ($1, $2);
            my $name = (split '/', $entry_path)[-1];
            my $is_dir = $is_local ? (-d $entry_path) : 1;
            push @entries, {
                size     => $size,
                bytes    => $to_bytes->($size),
                path     => $entry_path,
                name     => $name,
                is_dir   => $is_dir,
            };
        }
        @entries = sort { $b->{bytes} <=> $a->{bytes} } @entries;
    }

    # Build breadcrumb parts
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
    $c->response->content_type('application/json');
    $c->response->body(JSON::encode_json({ ok => 1, count => $count, hostname => $hostname }));
}

__PACKAGE__->meta->make_immutable;
1;
