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

    my $status = {
        status => 'ok',
        system => $self->logging->get_system_identifier(),
        timestamp => time(),
        issues => []
    };

    # 1. Database Ping
    try {
        unless ($c->model('DBEncy')->storage->dbh->ping) {
            $status->{status} = 'critical';
            push @{$status->{issues}}, 'Primary database (MySQL) is down';
        }
    } catch {
        $status->{status} = 'critical';
        push @{$status->{issues}}, "Database connection error: $_";
    };

    # 2. Check recent CRITICAL or ERROR logs for this system
    try {
        my $system_id = $status->{system};
        my $five_minutes_ago = DateTime->now()->subtract(minutes => 5)->strftime('%Y-%m-%d %H:%M:%S');
        
        my $recent_logs_rs = $c->model('DBEncy')->resultset('SystemLog')->search({
            system_identifier => $system_id,
            level => { -in => ['ERROR', 'CRITICAL'] },
            timestamp => { '>=' => $five_minutes_ago }
        });

        if ($recent_logs_rs->count > 0) {
            # Only escalate status if it's not already critical
            $status->{status} = 'warning' if $status->{status} eq 'ok';
            push @{$status->{issues}}, "Recent critical/error logs detected for this system";
        }
    } catch {
        # If logging DB check fails, we might have a DB issue already caught, 
        # or it's a transient error. Don't let it crash the health check.
    };

    $c->response->content_type('application/json');
    $c->response->body(encode_json($status));
}

__PACKAGE__->meta->make_immutable;

1;
