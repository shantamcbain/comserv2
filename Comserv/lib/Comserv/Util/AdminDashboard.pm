package Comserv::Util::AdminDashboard;

use strict;
use warnings;
use Moose;
use namespace::autoclean -except => [qw(try catch finally)];
use Try::Tiny;
use Time::HiRes qw(time);
use Comserv::Util::Logging;

=head1 NAME

Comserv::Util::AdminDashboard - dashboard card data for /admin, with per-worker caching.

=head1 DESCRIPTION

Extracted from Comserv::Controller::Admin so the Admin controller stays thin and the
heavy per-request queries (hardware metrics, remote-server stats, git status,
helpdesk/invoices) are cached per-worker. Each Starman/Twiggy worker keeps its own
copy; that is correct for this data (site-wide / process-wide facts, not per-user).

The cache TTL defaults to 120s. Caching is the fix for the ~50s hardware_metrics
full-scan that previously ran on every /admin load (no composite index existed on
hardware_metrics(hostname, timestamp) and the query was uncached).

=cut

# ── Per-worker TTL caches ───────────────────────────────────────────────────────
# Keyed by a stable string; stores { val => $ref, at => $epoch }. Each worker is
# independent (mirrors the $_remotedb_status idiom already used in Root.pm).
my %_cache;
my $_TTL = 120;

sub _cached {
    my ($key, $generator) = @_;
    my $now = time();
    if (my $ent = $_cache{$key}) {
        return $ent->{val} if ($now - $ent->{at}) < $_TTL;
    }
    my $val = $generator->();
    $_cache{$key} = { val => $val, at => $now };
    return $val;
}

# ── Monitored servers (static config) ───────────────────────────────────────────
my @MONITORED_SERVERS = (
    { names => ['db-production', 'db-01', 'db01', '192.168.1.20'], ip => '192.168.1.20',
      label => 'DB Server 1 (192.168.1.20)', hostname_override => 'db-production',
      ssh_user => 'ubuntu', ssh_alias => 'db1',
      ingest_url => undef },
    { names => ['db-02', 'db02', '192.168.1.21'], ip => '192.168.1.21',
      label => 'DB Server 2 (192.168.1.21)', hostname_override => 'db-02',
      ssh_user => 'ubuntu', ssh_alias => 'db2',
      ingest_url => undef },
    { names => ['comservproduction1', 'comservproduction', 'prod-01', 'prod1', 'production1', '192.168.1.126'],
      ip => '192.168.1.126', label => 'Prod Catalyst 1 (192.168.1.126)',
      hostname_override => 'comservproduction1', ssh_user => 'ubuntu', ssh_alias => 'production1',
      ingest_url => 'http://127.0.0.1:5000/admin/hardware_monitor/ingest' },
    { names => ['comservproduction2', 'prod-02', 'prod2', 'production2', '192.168.1.127'],
      ip => '192.168.1.127', label => 'Prod Catalyst 2 (192.168.1.127)',
      hostname_override => 'comservproduction2', ssh_user => 'ubuntu', ssh_alias => 'production2',
      ingest_url => 'http://127.0.0.1:5000/admin/hardware_monitor/ingest' },
);

sub _monitored_server_by_ip {
    my ($ip) = @_;
    return unless defined $ip && length $ip;
    for my $srv (@MONITORED_SERVERS) {
        return $srv if $srv->{ip} eq $ip;
    }
    return;
}

sub _local_monitor_hostnames {
    my %seen;
    my @names;
    for my $n (qw(workstation workstation.local 192.168.1.199 localhost), $ENV{HW_HOSTNAME_OVERRIDE}) {
        next unless defined $n && $n ne '';
        push @names, $n unless $seen{$n}++;
    }
    for my $cmd ('hostname -s 2>/dev/null', 'hostname -f 2>/dev/null', 'hostname 2>/dev/null') {
        my $h = `$cmd`;
        chomp $h if defined $h;
        next unless $h;
        push @names, $h unless $seen{$h}++;
    }
    return \@names;
}

sub _hardware_metrics_host_search {
    my ($self, $c, $target) = @_;
    my @conds;
    my %seen;

    if ($target && ref $target eq 'HASH' && ($target->{ip} || $target->{names})) {
        my $srv = (_monitored_server_by_ip($target->{ip} // '')) || $target;
        my @names;
        for my $n (
            @{ $srv->{names} || [] },
            $srv->{ip},
            $srv->{hostname_override},
            $target->{hostname},
            $srv->{hostname},
        ) {
            next unless defined $n && $n ne '';
            push @names, $n unless $seen{$n}++;
        }
        push @conds, { hostname => { -in => \@names } } if @names;
        if ($srv->{ip}) {
            push @conds, { system_identifier => { -like => $srv->{ip} . '%' } };
        }
    } else {
        my @names = @{ $self->_local_monitor_hostnames() };
        my $discovered = $self->_discover_local_agent_hostname($c);
        push @names, $discovered if $discovered;
        my %ns;
        @names = grep { defined $_ && length $_ && !$ns{$_}++ } @names;
        push @conds, { hostname => { -in => \@names } } if @names;
    }

    return @conds ? { -or => \@conds } : undef;
}

sub _discover_local_agent_hostname {
    my ($self, $c) = @_;
    return unless $c && eval { $c->model('DBEncy') };
    my $rs = $c->model('DBEncy')->resultset('HardwareMetrics');
    my $row = eval {
        $rs->search(
            {
                system_identifier => { -like => '%:agent' },
                timestamp         => { '>=' => \"DATE_SUB(NOW(), INTERVAL 7 DAY)" },
            },
            { order_by => { -desc => 'timestamp' }, rows => 1 },
        )->single;
    };
    return $row ? $row->hostname : undef;
}

# ── Public card data methods (cached) ───────────────────────────────────────────

sub software_status {
    my ($self, $c) = @_;
    return _cached('software_status', sub { $self->_get_software_status($c) });
}

sub system_stats {
    my ($self, $c) = @_;
    return _cached('system_stats', sub { $self->_get_system_stats($c) });
}

sub remote_server_stats {
    my ($self, $c) = @_;
    # This was the ~50s full-scan on every request. Cached per-worker.
    return _cached('remote_server_stats', sub { $self->_get_remote_server_stats($c) });
}

sub recent_activity {
    my ($self, $c) = @_;
    return _cached('recent_activity', sub { $self->_get_recent_activity($c) });
}

sub system_notifications {
    my ($self, $c) = @_;
    return _cached('system_notifications', sub { $self->_get_system_notifications($c) });
}

# ── Implementations (private) ───────────────────────────────────────────────────

sub _get_software_status {
    my ($self, $c) = @_;

    my $repo_dir = $c->path_to('..')->stringify;

    my $current_branch  = '';
    my $last_commit     = '';
    my $commits_behind  = 0;
    my $has_uncommitted = 0;
    my $has_untracked   = 0;
    my @recommendations;

    eval {
        chomp($current_branch = `git -C "$repo_dir" rev-parse --abbrev-ref HEAD 2>/dev/null`);
        chomp($last_commit    = `git -C "$repo_dir" log -1 --format="%h %s" 2>/dev/null`);

        my $fetch_out = `git -C "$repo_dir" fetch origin 2>&1`;
        chomp(my $behind_raw = `git -C "$repo_dir" rev-list --count HEAD..origin/main 2>/dev/null`);
        $commits_behind = ($behind_raw =~ /^\d+$/) ? $behind_raw + 0 : 0;

        my $status_out = `git -C "$repo_dir" status --porcelain 2>/dev/null`;
        $has_uncommitted = ($status_out =~ /^[MADRCU]/m) ? 1 : 0;
        $has_untracked   = ($status_out =~ /^\?\?/m)     ? 1 : 0;

        if ($commits_behind > 0) {
            push @recommendations, {
                type    => 'warning',
                icon    => 'fas fa-exclamation-triangle',
                message => "Your branch is $commits_behind commit(s) behind origin/main.",
                action  => 'Run Git Pull to update.',
                link    => '/admin/git_pull',
            };
        }
    };

    return {
        git_status => {
            current_branch          => $current_branch  || 'Unknown',
            last_commit             => $last_commit      || 'No commits',
            commits_behind          => $commits_behind,
            has_uncommitted_changes => $has_uncommitted,
            has_untracked_files     => $has_untracked,
        },
        recommendations => \@recommendations,
    };
}

sub _get_system_stats {
    my ($self, $c) = @_;

    my $stats = {
        user_count        => 0,
        active_user_count => 0,
        file_count        => 0,
        disk_usage        => 'Unknown',
        disk_pct          => 0,
        disk_used         => '',
        disk_total        => '',
        disk_level        => 'ok',
        nfs_pct           => 0,
        nfs_used          => '',
        nfs_total         => '',
        nfs_level         => 'ok',
        uptime            => 'Unknown',
    };

    eval {
        my $schema = $c->model('DBEncy');
        $stats->{user_count}        = $schema->resultset('User')->count;
        $stats->{active_user_count} = $schema->resultset('User')->search({ status => 'active' })->count;
        $stats->{file_count}        = $schema->resultset('File')->count if $schema->resultset('File');
    };

    # Disk stats are external; prefer the DiskStats util if present.
    eval {
        if (eval { require Comserv::Util::DiskStats }) {
            my $disk = Comserv::Util::DiskStats->app_disk_stats($c);
            if ($disk) {
                $stats->{disk_usage} = $disk->{used_fmt} // 'Unknown';
                $stats->{disk_pct}    = $disk->{pct}      // 0;
                $stats->{disk_used}   = $disk->{used_fmt} // '';
                $stats->{disk_total}  = $disk->{total_fmt} // '';
                $stats->{disk_level}  = ($disk->{pct} // 0) >= 90 ? 'danger'
                                      : ($disk->{pct} // 0) >= 80 ? 'warn' : 'ok';
            }
        }
    };

    return $stats;
}

sub _get_remote_server_stats {
    my ($self, $c) = @_;
    my @servers;
    eval {
        my $rs = $c->model('DBEncy')->resultset('HardwareMetrics');
        for my $srv (@MONITORED_SERVERS) {
            my @names = @{ $srv->{names} };
            push @names, $srv->{ip} if $srv->{ip};
            my %latest;
            my @rows = $rs->search(
                {
                    -or => [
                        { hostname => { -in => \@names } },
                        { system_identifier => { -like => $srv->{ip} . '%' } },
                    ],
                    timestamp => { '>=' => \"DATE_SUB(NOW(), INTERVAL 24 HOUR)" },
                },
                { order_by => { -desc => 'timestamp' }, rows => 500 },
            )->all;
            for my $row (@rows) {
                my $mn = $row->metric_name;
                next if exists $latest{$mn};
                $latest{$mn} = {
                    value => $row->metric_value,
                    text  => $row->metric_text,
                    unit  => $row->unit,
                    level => $row->level,
                    ts    => $row->timestamp,
                };
            }
            my $reported_hostname = @rows ? $rows[0]->hostname : undef;
            my $last_seen         = @rows ? $rows[0]->timestamp : undef;
            my $fresh_count = $rs->search(
                {
                    -or => [
                        { hostname => { -in => \@names } },
                        { system_identifier => { -like => $srv->{ip} . '%' } },
                    ],
                    timestamp => { '>=' => \"DATE_SUB(NOW(), INTERVAL 2 HOUR)" },
                },
                { rows => 1 },
            )->count;
            push @servers, {
                name      => $srv->{ip},
                ip        => $srv->{ip},
                label     => $srv->{label},
                hostname  => $reported_hostname,
                metrics   => \%latest,
                last_seen => $last_seen,
                online    => scalar(@rows) ? 1 : 0,
                stale     => (scalar(@rows) && !$fresh_count) ? 1 : 0,
            };
        }
    };
    return \@servers;
}

sub _get_recent_activity {
    my ($self, $c) = @_;
    my @activity;

    eval {
        my @logins = $c->model('DBEncy::UserLogin')->search(
            {}, { order_by => { -desc => 'login_time' }, rows => 5 }
        );
        push @activity, map {
            { type => 'login', user => $_->user->username, time => $_->login_time, details => $_->ip_address }
        } @logins;
    };

    eval {
        my @changes = $c->model('DBEncy::ContentHistory')->search(
            {}, { order_by => { -desc => 'change_time' }, rows => 5 }
        );
        push @activity, map {
            { type => 'content', user => $_->user->username, time => $_->change_time,
              details => "Updated " . $_->content->title }
        } @changes;
    };

    @activity = sort { $b->{time} cmp $a->{time} } @activity;
    @activity = @activity[0..9] if @activity > 10;
    return \@activity;
}

sub _get_system_notifications {
    my ($self, $c) = @_;
    my @notifications;

    eval {
        my $pending_count = $c->model('DBEncy::User')->search({ status => 'pending' })->count();
        if ($pending_count > 0) {
            push @notifications, {
                type    => 'warning',
                message => "$pending_count pending user registration(s) require approval",
                link    => $c->uri_for('/admin/users', { filter => 'pending' }),
            };
        }
    };

    eval {
        my $disk = Comserv::Util::DiskStats->app_disk_stats($c);
        if ($disk && $disk->{pct} >= 90) {
            push @notifications, {
                type    => 'danger',
                message => "App server disk critically low ($disk->{pct}% — $disk->{used_fmt} / $disk->{total_fmt})",
                link    => $c->uri_for('/admin/hardware_monitor/disk_health'),
            };
        } elsif ($disk && $disk->{pct} >= 80) {
            push @notifications, {
                type    => 'warning',
                message => "App server disk running low ($disk->{pct}%)",
                link    => $c->uri_for('/admin/hardware_monitor/disk_health'),
            };
        }
    };

    eval {
        my $pending_count = $c->model('DBEncy::Comment')->search({ status => 'pending' })->count();
        if ($pending_count > 0) {
            push @notifications, {
                type    => 'info',
                message => "$pending_count pending comment(s) require moderation",
                link    => $c->uri_for('/admin/comments', { filter => 'pending' }),
            };
        }
    };

    eval {
        my $user_id = $c->session->{user_id};
        my $is_csc_admin = 0;
        if ($user_id) {
            my $user_obj = $c->model('DBEncy')->resultset('User')->find($user_id, { columns => ['roles'] });
            if ($user_obj) {
                my $global_roles = $user_obj->roles || '';
                $is_csc_admin = ($global_roles =~ /admin|accounting/i) ? 1 : 0;
            }
        }

        if ($is_csc_admin) {
            my $pending = $c->model('DBEncy')->resultset('Accounting::HostingAccount')->search(
                { status => 'pending' }
            )->count;
            if ($pending > 0) {
                my $msg = "$pending pending CSC hosting registration(s) require approval."
                    . " Note: new accounts without prior setup must be added manually to the"
                    . " system after payment is confirmed.";
                push @notifications, {
                    type    => 'warning',
                    message => $msg,
                    link    => 'https://computersystemconsulting.ca/membership/admin/hosting_accounts',
                };
            }

            my $cutoff = DateTime->now->subtract(hours => 48)->strftime('%Y-%m-%d %H:%M:%S');
            my @paid = $c->model('DBEncy')->resultset('Accounting::InventorySupplierInvoice')->search(
                { sitename => { '!=' => 'CSC' }, status => 'paid', updated_at => { '>=' => $cutoff } },
                { order_by => { -desc => 'updated_at' } }
            )->all;
            for my $inv (@paid) {
                push @notifications, {
                    type    => 'success',
                    message => 'Payment received: ' . $inv->sitename . ' — ' . $inv->invoice_number
                               . ' (CAD ' . $inv->total_amount . ')',
                    link    => 'https://computersystemconsulting.ca/Inventory/sales',
                };
            }
        }

        eval {
            my $site_name = $c->stash->{SiteName} || $c->session->{SiteName} || '';
            my $today_str = do { my @t = localtime; sprintf('%04d-%02d-%02d', $t[5]+1900, $t[4]+1, $t[3]) };
            my $auto_due  = $c->model('DBEncy')->resultset('Accounting::InventorySupplierInvoice')->search({
                sitename => $site_name,
                auto_pay => 1,
                status   => { '!=' => 'paid' },
                due_date => { '<=' => $today_str },
            })->count;
            if ($auto_due > 0) {
                push @notifications, {
                    type    => 'warning',
                    message => "$auto_due auto-pay invoice(s) past due — confirm the charge has posted.",
                    link    => '/Inventory/invoice/process_auto_pay',
                };
            }
        };
    };

    return \@notifications;
}

__PACKAGE__->meta->make_immutable;
1;
