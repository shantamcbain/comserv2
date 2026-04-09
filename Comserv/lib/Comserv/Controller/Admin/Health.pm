package Comserv::Controller::Admin::Health;
use Moose;
use namespace::autoclean;
use JSON;
use Try::Tiny;

BEGIN { extends 'Comserv::Controller::Base'; }

has 'logging' => (
    is => 'ro',
    default => sub { require Comserv::Util::Logging; Comserv::Util::Logging->instance }
);

sub check :Path('/admin/health/check') :Args(0) {
    my ($self, $c) = @_;

    # Restrict to admins
    unless ($c->stash->{is_admin}) {
        $c->response->status(403);
        $c->response->body(encode_json({ error => 'Unauthorized access' }));
        return;
    }

    my $local_system = $self->logging->get_system_identifier();
    my $status = {
        status         => 'ok',
        system         => $local_system,
        timestamp      => time(),
        issues         => [],     # local server issues (DB ping etc.)
        server_alerts  => [],     # per-server alerts from ALL systems in system_log
    };

    # 1. Database Ping (local check)
    try {
        unless ($c->model('DBEncy')->storage->dbh->ping) {
            $status->{status} = 'critical';
            push @{$status->{issues}}, 'Primary database (MySQL) is down';
        }
    } catch {
        $status->{status} = 'critical';
        push @{$status->{issues}}, "Database connection error: $_";
    };

    # 2. Check ALL systems in system_log for recent ERROR/CRITICAL entries.
    #    This covers every server that writes to the shared DB — production,
    #    dev containers, worktrees — so any port on the workstation sees every alert.
    try {
        my $schema = $c->model('DBEncy');
        my $ten_minutes_ago = DateTime->now()->subtract(minutes => 10)->strftime('%Y-%m-%d %H:%M:%S');

        # Group by system_identifier so we get one alert entry per server
        my $rs = $schema->resultset('SystemLog')->search(
            {
                level     => { -in => ['ERROR', 'CRITICAL'] },
                timestamp => { '>=' => $ten_minutes_ago },
            },
            {
                select   => [ 'system_identifier',
                              { max => 'level',     -as => 'worst_level' },
                              { count => 'id',      -as => 'error_count' },
                              { max => 'timestamp', -as => 'latest_ts'   } ],
                as       => [qw( system_identifier worst_level error_count latest_ts )],
                group_by => ['system_identifier'],
                order_by => { -desc => 'latest_ts' },
            }
        );

        while (my $row = $rs->next) {
            my $sys   = $row->get_column('system_identifier') // 'unknown';
            my $cnt   = $row->get_column('error_count')       // 0;
            my $worst = $row->get_column('worst_level')       // 'ERROR';
            my $ts    = $row->get_column('latest_ts')         // '';

            my $server_status = ($worst eq 'CRITICAL') ? 'critical' : 'warning';

            # Escalate the overall banner status
            if ($server_status eq 'critical') {
                $status->{status} = 'critical';
            } elsif ($status->{status} eq 'ok') {
                $status->{status} = 'warning';
            }

            push @{$status->{server_alerts}}, {
                system  => $sys,
                level   => $server_status,
                count   => int($cnt),
                latest  => $ts,
                message => "$cnt error(s) in the last 10 minutes",
            };
        }
    } catch {
        # Transient DB error — don't crash the health poll
    };

    $c->response->content_type('application/json');
    $c->response->body(encode_json($status));
}

__PACKAGE__->meta->make_immutable;

1;
