package Comserv::Controller::Admin::HardwareMonitor;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;
use Comserv::Util::AdminAuth;
use Comserv::Util::EmailNotification;
use Comserv::Util::DiskStats;
use Comserv::Util::HardwareAgent;
use JSON ();
use Scalar::Util qw(looks_like_number);
use List::Util ();
use POSIX qw(strftime mktime);

BEGIN { extends 'Comserv::Controller::Base'; }

has 'logging' => (
    is      => 'ro',
    lazy    => 1,
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

# How long (seconds) before a missing monitoring heartbeat is treated as a
# missed window. Cron fires every 5 min, so 600s (~2 missed cycles) trips it.
our $MONITOR_TIMEOUT = 600;

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
        ingest_token    => $self->_expected_token,
        ingest_url      => _ingest_url($c),
    );
}

# ─────────────────────────────────────────────────────────────────────────────
# MONITORING RE-ARCHITECTURE (2026-08-12)
# The external script no longer touches the DB directly — it only curls this
# `run` endpoint every 5 min. The APP owns the monitoring: it collects local
# hardware metrics, verifies the CURRENT DB is live, runs a self test, and
# records a heartbeat. Because the app already knows which DB is current
# (SYSTEM_IDENTIFIER / Docker Swarm), the "which DB is current" blind spot that
# plagued the standalone script is gone. Any failure here is logged critical via
# log_with_details → error audit → [Error] todo + daily-priorities + admin email.
# ─────────────────────────────────────────────────────────────────────────────

# Resolve the shared monitoring token. The token MUST be byte-identical on every
# cron host AND every app container, or healthy nodes get falsely reported down.
# Single source of truth is the NFS-backed token file (same file every host and
# container mounts), then a host-local copy, then the compose env var, then the
# changeme placeholder. deploy.sh creates the NFS file once and copies the same
# value into each server's /usr/local/etc/comserv copy + compose, so they always
# agree. Reading the file here keeps the container's token in lock-step with the
# cron host even if env is unset.
sub _expected_token {
    my ($self) = @_;
    # The token MUST be byte-identical on every cron host AND every container, or
    # healthy nodes get falsely reported down. Scan candidate sources in priority
    # order; the NFS share is the single source of truth (every host + container
    # mounts the same export, possibly at a different local path). If a pinned env
    # token was set it still wins, then the NFS/host files, then changeme.
    my @candidates = (
        $ENV{HW_INGEST_TOKEN} // '',
        '/data/nfs/comserv_secrets/hw_ingest_token',
        '/mnt/nfs_data/comserv_secrets/hw_ingest_token',
        '/usr/local/etc/comserv/hw_ingest_token',
        "$ENV{COMSERV_HOST_NFS_PATH}/comserv_secrets/hw_ingest_token",
    );
    for my $path (@candidates) {
        next unless defined $path && length $path;
        my $t = $path;
        if (-f $path) {
            if (open(my $fh, '<', $path)) {
                $t = <$fh>;
                close $fh;
            } else {
                next;
            }
        }
        next unless defined $t;
        $t =~ s/\s+$//;
        return $t if length $t && $t ne 'changeme';
    }
    return $ENV{HW_INGEST_TOKEN} // 'changeme';
}

sub run :Path('/admin/hardware_monitor/run') :Args(0) {
    my ($self, $c) = @_;

    # Accept external (cron/script) calls without a browser session: the trigger
    # script sends X-Ingest-Token. Same token as the ingest/report endpoints.
    my $expected = $self->_expected_token;
    my $provided  = $c->req->header('X-Ingest-Token')
                 // $c->req->param('token')
                 // '';
    unless ($provided eq $expected) {
        $c->response->status(403);
        $c->response->content_type('application/json');
        $c->response->body(JSON::encode_json({ ok => 0, error => 'Invalid token' }));
        return;
    }

    # Canonical, deterministic node identity shared by `run` (writes heartbeat)
    # and `watchdog` (queries it). get_system_identifier() appends a volatile
    # runtime tag (" (Standalone)"/" (Docker)") and the listening port, which is
    # detected non-deterministically per request in the dev server — so `run`
    # and `watchdog` would compute DIFFERENT keys and the watchdog could never
    # find its own heartbeat. Normalize both to the bare host identity.
    my ($sys_id, $hostname) = $self->_node_identity($c);

    my $dbh_ok   = 0;
    my $self_test = 'ok';
    my $err      = '';

    eval {
        my $schema = $c->model('DBEncy');
        my $dbh    = $schema->storage->dbh;

        # 0. Probe the handle first. With mariadb_auto_reconnect => 1 (set in the
        # model connect_info) a ping against a stale/dropped handle transparently
        # re-establishes the connection. We temporarily DISABLE auto-reconnect for
        # the probe so we can DETECT (and log) a stale handle rather than silently
        # papering over it — visibility into how often the DB drops the connection
        # matters for diagnosis. If the handle was dead we log a WARNING (not
        # critical: auto-reconnect repairs it on the next statement) and then let
        # the live 'SELECT 1' below reconnect it for real. If the DB is truly
        # unreachable the probe returns false and we fall through to the critical
        # failure path below.
        my $driver_name = eval { $dbh->{Driver}->{Name} } // 'MariaDB';
        my $reconnect_key = $driver_name eq 'mysql' ? 'mysql_auto_reconnect' : 'mariadb_auto_reconnect';
        my $prev_reconnect = eval { $dbh->{$reconnect_key} };
        eval { $dbh->{$reconnect_key} = 0 } if defined $prev_reconnect;
        my $probe = eval { $dbh->ping };
        eval { $dbh->{$reconnect_key} = $prev_reconnect } if defined $prev_reconnect;
        if (!defined $probe || !$probe) {
            # Handle was dead. Log it (warning) so the audit records the drop; the
            # live query below will auto-reconnect. If it can't, we hit the critical
            # failure path and log_with_details there.
            eval {
                $self->logging->log_with_details($c, 'warning', __FILE__, __LINE__,
                    'hardware_monitor.run',
                    "[MONITOR-RUN] node=$hostname db_handle_stale=1 (auto-reconnect will repair)");
            };
            die "db handle dead (ping failed)";
        }

        # 1. Verify the CURRENT DB is genuinely live with a trivial query.
        my $live = $dbh->selectrow_array('SELECT 1');
        $dbh_ok = ($live && $live == 1) ? 1 : 0;

        # 2. Self test — exercise a real read the app depends on. A mid-session
        #    connection drop (transient network blip between the SELECT 1 above
        #    and this query) raises "Lost connection ... during query"; mariadb
        #    auto-reconnect only repairs the NEXT statement, not the one in
        #    flight. Force a fresh handle and retry the self-test exactly once so
        #    a sub-second blip self-heals within the same monitor cycle instead
        #    of raising CRITICAL and opening a spurious todo. (Pattern mirrors
        #    Comserv::Util::LoggingAudit code-scan reconnect.)
        my $self_test_ok = eval {
            $schema->resultset('SystemLog')->search({}, { rows => 1 })->count;
            1;
        };
        unless ($self_test_ok) {
            my $first_err = "$@";
            eval { $schema->storage->disconnect };
            my $dbh2 = eval { $schema->storage->dbh };
            if ($dbh2) {
                $self_test_ok = eval {
                    $schema->resultset('SystemLog')->search({}, { rows => 1 })->count;
                    1;
                };
            }
            die $first_err unless $self_test_ok;   # retry failed -> outer eval logs real cause
        }
        $self_test = 'ok';
    };
    if ($@) {
        # Stringify: DBIx::Class throws a *blessed* exception object. Embedding the
        # raw object in the log message / JSON body breaks JSON::XS (no TO_JSON) and
        # trips the global error handler. Force a plain string here.
        $err = "$@";
        $err =~ s/\s+/ /g;
        $dbh_ok = 0;
        $self_test = 'failed';
    }

    # Record heartbeat + DB-liveness + self-test as hardware_metrics rows so the
    # watchdog (and the dashboard) can see the last good cycle per node.
    my $rs = eval { $c->model('DBEncy')->resultset('HardwareMetrics') };
    if ($rs) {
        my @rows = (
            { name => 'monitor_heartbeat', value => time(), unit => 'epoch',
              level => $dbh_ok ? 'info' : 'critical',
              text  => "db_live=$dbh_ok self_test=$self_test" },
            { name => 'db_live', value => $dbh_ok ? 1 : 0, unit => 'bool',
              level => $dbh_ok ? 'info' : 'critical' },
            { name => 'self_test', value => ($self_test eq 'ok' ? 1 : 0), unit => 'bool',
              level => ($self_test eq 'ok') ? 'info' : 'critical' },
        );
        for my $r (@rows) {
            eval { $rs->create({
                timestamp          => \'NOW()',
                system_identifier => $sys_id,
                hostname          => $hostname,
                metric_name       => $r->{name},
                metric_value      => $r->{value},
                metric_text       => $r->{text},
                unit              => $r->{unit},
                level             => $r->{level},
            }) };
        }
        # Also refresh local hardware metrics (CPU/mem/disk) when DB is live.
        if ($dbh_ok) {
            eval { Comserv::Util::HardwareAgent->collect_and_store($c) };
        }
    }

    # 3. Failure path — surface to the audit exactly like any in-app error.
    unless ($dbh_ok && $self_test eq 'ok') {
        $self->logging->log_with_details($c, 'critical', __FILE__, __LINE__,
            'hardware_monitor.run',
            "[MONITOR-RUN] node=$hostname db_live=$dbh_ok self_test=$self_test"
            . ($err ? " err=$err" : ''));
        $c->response->status(503);
        $c->response->content_type('application/json');
        $c->response->body(JSON::encode_json({
            ok => 0, db_live => $dbh_ok, self_test => $self_test, error => $err // '' }));
        return;
    }

    $c->response->content_type('application/json');
    $c->response->body(JSON::encode_json({ ok => 1, node => $hostname, db_live => 1, self_test => 'ok' }));
}

# Watchdog: did THIS node's monitor run recently? Missed window = container/DB down.
# Returns JSON { ok, last_run, age_sec, missed }. Designed to be polled (e.g. by
# the external script or a dashboard) and to log a critical if the window lapsed.
sub watchdog :Path('/admin/hardware_monitor/watchdog') :Args(0) {
    my ($self, $c) = @_;

    # Token-guarded so an external poller (no browser session) can call it.
    my $expected = $self->_expected_token;
    my $provided  = $c->req->header('X-Ingest-Token')
                 // $c->req->param('token')
                 // '';
    unless ($provided eq $expected) {
        $c->response->status(403);
        $c->response->content_type('application/json');
        $c->response->body(JSON::encode_json({ ok => 0, error => 'Invalid token' }));
        return;
    }

    my ($sys_id, $hostname) = $self->_node_identity($c);

    # Match on system_identifier ONLY. `run` writes system_identifier as the
    # canonical node key via _node_identity(); the separate `hostname` column is
    # derived with sanitization that diverges between endpoints, so requiring an
    # exact hostname match makes the watchdog unable to find its own heartbeat.
    my ($last) = eval {
        $c->model('DBEncy')->resultset('HardwareMetrics')->search(
            { system_identifier => $sys_id, metric_name => 'monitor_heartbeat' },
            { order_by => { -desc => 'timestamp' }, rows => 1 },
        )->single;
    };
    my $now = time();
    my $last_epoch = $last ? ($last->metric_value // 0) : 0;
    my $age = $last_epoch ? ($now - $last_epoch) : (10**9);
    my $missed = ($age > $MONITOR_TIMEOUT) ? 1 : 0;

    if ($missed) {
        $self->logging->log_with_details($c, 'critical', __FILE__, __LINE__,
            'hardware_monitor.watchdog',
            "[MONITOR-WATCHDOG] node=$hostname missed monitoring window (age=${age}s, timeout=$MONITOR_TIMEOUT)");
    }

    $c->response->content_type('application/json');
    $c->response->body(JSON::encode_json({
        ok => ($missed ? 0 : 1), node => $hostname,
        last_run => $last_epoch, age_sec => $age, timeout => $MONITOR_TIMEOUT, missed => $missed,
    }));
}

# Canonical, deterministic node identity shared by `run` (writes the heartbeat)
# and `watchdog` (queries it). get_system_identifier() appends a volatile runtime
# tag (" (Standalone)"/" (Docker)") and the listening port, which is detected
# non-deterministically per request in the dev server — so `run` and `watchdog`
# would otherwise compute DIFFERENT keys and the watchdog could never find the
# heartbeat row `run` wrote. We normalize both to the bare host identity here so
# the two endpoints always agree.
sub _node_identity {
    my ($self, $c) = @_;

    my $sys_id = Comserv::Util::Logging->get_system_identifier();
    # Strip volatile " (Standalone)"/" (Docker)" runtime tag.
    $sys_id =~ s/\s*\([^)]*\)//g;
    # Strip trailing ":port" if present.
    $sys_id =~ s/:\d+$//;
    $sys_id =~ s/[^A-Za-z0-9._-]//g;

    my $hostname = $ENV{HW_HOSTNAME_OVERRIDE} || $sys_id || `hostname -s 2>/dev/null` || 'unknown';
    chomp $hostname;
    $hostname =~ s/[^A-Za-z0-9._-]//g;

    return ($sys_id, $hostname);
}

# External reporter: a watcher on node X reports it could NOT reach node Y's
# container. That indicates node Y's container (or its host) is down. The app
# logs it critical (→ audit + admin email) so the outage is visible centrally.
sub report_down :Path('/admin/hardware_monitor/report_down') :Args(0) {
    my ($self, $c) = @_;

    my $expected = $self->_expected_token;
    my $provided  = $c->req->header('X-Ingest-Token')
                 // $c->req->param('token')
                 // '';
    unless ($provided eq $expected) {
        $c->response->status(403);
        $c->response->content_type('application/json');
        $c->response->body(JSON::encode_json({ ok => 0, error => 'Invalid token' }));
        return;
    }

    my $node = $c->req->param('node') // '';
    $node =~ s/[^A-Za-z0-9._:-]//g;
    my $detail = $c->req->param('detail') // '';
    $detail =~ s/[^[:print:]]//g;

    unless ($node) {
        $c->response->status(400);
        $c->response->content_type('application/json');
        $c->response->body(JSON::encode_json({ ok => 0, error => 'node required' }));
        return;
    }

    $self->logging->log_with_details($c, 'critical', __FILE__, __LINE__,
        'hardware_monitor.report_down',
        "[MONITOR-DOWN] node=$node unreachable from watcher "
        . "host=" . (`hostname -s 2>/dev/null` // 'unknown') . " detail=$detail");

    $c->response->content_type('application/json');
    $c->response->body(JSON::encode_json({ ok => 1, reported => $node }));
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
    comservproduction1 comservproduction2 192.168.1.126 192.168.1.127
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

    my $timeout_bin = (-x '/usr/bin/timeout') ? '/usr/bin/timeout'
                    : (-x '/bin/timeout')     ? '/bin/timeout'
                    : '';

    my $run_cmd = sub {
        my (@cmd) = @_;
        if ($is_local) {
            my @exec = $timeout_bin ? ($timeout_bin, $TIMEOUT, @cmd) : @cmd;
            my $shell_cmd = join(' ', map { quotemeta($_) } @exec) . ' 2>/dev/null';
            open my $fh, '-|', $shell_cmd
                or return (undef, "Cannot run: $cmd[0]: $!");
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

    my $expected = $self->_expected_token;
    my $provided  = $c->req->header('X-Ingest-Token')
                 // $c->req->param('token')
                 // '';
    unless ($provided eq $expected) {
        $c->response->status(403);
        $c->response->content_type('application/json');
        $c->response->body(JSON::encode_json({ ok => 0, error => 'Invalid token' }));
        return;
    }

    my $body;
    if (ref($c->req->body_data) eq 'HASH') {
        $body = $c->req->body_data;
    } else {
        my $raw_json = '{}';
        if (my $body_fh = $c->req->body) {
            if (ref($body_fh) && $body_fh->can('getline')) {
                local $/;
                $raw_json = <$body_fh>;
                $body_fh->seek(0, 0) if $body_fh->can('seek');
            } elsif (!ref($body_fh)) {
                $raw_json = $body_fh;
            }
        }
        $body = eval { JSON::decode_json($raw_json) };
    }
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

    # Alert/email failures must not fail ingest (device_agent expects 200 + JSON).
    eval { $self->_check_disk_alerts($c, $hostname, $body->{metrics} // []); };
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'ingest',
            "disk alert check failed (metrics stored): $@");
    }

    $c->response->content_type('application/json');
    $c->response->body(JSON::encode_json({ ok => 1, count => $count, hostname => $hostname }));
}

# External (standalone) reporting channel for the hardware_monitor.pl cron script.
# The standalone script cannot write system_log when its DB connect FAILS (no handle),
# so it POSTs the failure here. This writes a critical log_with_details entry, which the
# error audit picks up into a [Error] todo + daily-priorities, and the admin error email.
# Reuses the same ingest token guard — no new secret.
sub report_error :Path('/admin/hardware_monitor/report_error') :Args(0) {
    my ($self, $c) = @_;

    unless ($c->req->method eq 'POST') {
        $c->response->status(405);
        $c->response->content_type('application/json');
        $c->response->body(JSON::encode_json({ ok => 0, error => 'POST required' }));
        return;
    }

    my $expected = $self->_expected_token;
    my $provided  = $c->req->header('X-Ingest-Token')
                 // $c->req->param('token')
                 // '';
    unless ($provided eq $expected) {
        $c->response->status(403);
        $c->response->content_type('application/json');
        $c->response->body(JSON::encode_json({ ok => 0, error => 'Invalid token' }));
        return;
    }

    my $body;
    if (ref($c->req->body_data) eq 'HASH') {
        $body = $c->req->body_data;
    } else {
        my $raw_json = '{}';
        if (my $body_fh = $c->req->body) {
            if (ref($body_fh) && $body_fh->can('getline')) {
                local $/;
                $raw_json = <$body_fh>;
                $body_fh->seek(0, 0) if $body_fh->can('seek');
            } elsif (!ref($body_fh)) {
                $raw_json = $body_fh;
            }
        }
        $body = eval { JSON::decode_json($raw_json) };
    }
    if ($@ || !ref $body) {
        $c->response->status(400);
        $c->response->content_type('application/json');
        $c->response->body(JSON::encode_json({ ok => 0, error => 'Invalid JSON' }));
        return;
    }

    my $hostname = $body->{hostname} // $c->req->address // 'unknown';
    $hostname =~ s/[^A-Za-z0-9._-]//g;
    my $sys_id   = "$hostname:monitor";
    my $reason   = $body->{reason} // 'unknown failure';
    $reason      =~ s/[^\x20-\x7e]//g;  # strip control chars
    my $detail   = $body->{detail} // '';
    $detail      =~ s/[^\x20-\x7e]//g;

    $self->logging->log_with_details($c, 'critical', __FILE__, __LINE__, 'hardware_monitor.pl',
        "[MONITOR-FAIL] host=$hostname reason=$reason" . ($detail ? " detail=$detail" : ''));

    $c->response->content_type('application/json');
    $c->response->body(JSON::encode_json({ ok => 1, logged => 1, hostname => $hostname }));
}

# Ingest test payloads (e.g. hostname=testhost) store metrics but must not email admins.
sub _ingest_hostname_sends_alerts {
    my ($self, $hostname) = @_;
    return 0 if !$hostname;
    return 0 if $hostname =~ /^(?:test(?:host)?|unknown)$/i;
    if (my $extra = $ENV{HW_ALERT_HOSTNAMES}) {
        my %ok = map { lc($_) => 1 } grep { $_ ne '' } split /,\s*/, $extra;
        return 1 if $ok{ lc $hostname };
    }
    return 1 if $LOCAL_HOSTS{$hostname};
    my $short = (split /\./, $hostname)[0];
    return 1 if $short && $LOCAL_HOSTS{$short};
    return 0;
}

sub _check_disk_alerts {
    my ($self, $c, $hostname, $metrics) = @_;

    return unless $self->_ingest_hostname_sends_alerts($hostname);

    my $schema = eval { $c->model('DBEncy') };
    return unless $schema;

    my $alert_rs = eval { $schema->resultset('HealthAlert') };
    return unless $alert_rs;

    my $email_util = Comserv::Util::EmailNotification->new(logging => $self->logging);
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

    # ── 3. NFS disk usage (real NFS mount only — not local bind mounts) ─
    my $nfs_root = $ENV{NFS_DATA_PATH} // $ENV{NFS_ROOT} // '/data/nfs';
    my %nfs_usage;
    eval {
        my $nfs = Comserv::Util::DiskStats->separated_nfs_stats($c);
        if ($nfs && $nfs->{pct} && !$nfs->{blended} && !$nfs->{same_device}) {
            $nfs_root = $nfs->{path} // $nfs_root;
            $nfs_usage{size}  = $nfs->{total_fmt};
            $nfs_usage{used}  = $nfs->{used_fmt};
            $nfs_usage{avail} = $nfs->{avail_fmt};
            $nfs_usage{pct}   = $nfs->{pct};
            $nfs_usage{level} = $nfs->{level};
            $nfs_usage{source} = $nfs->{source} if $nfs->{source};
        } elsif ($nfs && ($nfs->{blended} || $nfs->{same_device})) {
            $nfs_usage{not_separate} = 1;
        }
    };

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
