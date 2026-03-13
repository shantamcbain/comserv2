package Comserv::Controller::Admin::LogAudit;

use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;
use Comserv::Util::HealthLogger;

BEGIN { extends 'Comserv::Controller::Base'; }

has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

# GET /admin/logging/audit
# Main audit dashboard — renders instantly; heavy stats loaded async via /audit/stats
sub index :Path('/admin/logging/audit') :Args(0) {
    my ($self, $c) = @_;

    my $hours = int($c->req->param('hours') || 24);
    $hours = 24 unless $hours > 0 && $hours <= 720;

    # Local Docker containers (fast — direct docker ps)
    my $docker_health = [];
    eval { $docker_health = Comserv::Util::HealthLogger->get_docker_health() };

    # All-server Docker health from shared system_log DB (includes production)
    my $docker_health_db = [];
    eval {
        $docker_health_db = Comserv::Util::HealthLogger->get_docker_health_from_db(
            $c->model('DBEncy')
        );
    };

    $c->stash(
        template         => 'admin/Logging/LogAudit.tt',
        docker_health    => $docker_health,
        docker_health_db => $docker_health_db,
        hours            => $hours,
    );
}

# GET /admin/logging/audit/stats?hours=N
# Returns heavy audit statistics as a JSON fragment — called async by the dashboard
sub stats :Path('/admin/logging/audit/stats') :Args(0) {
    my ($self, $c) = @_;

    my $hours = int($c->req->param('hours') || 24);
    $hours = 24 unless $hours > 0 && $hours <= 720;

    my $audit      = {};
    my $alerts     = [];
    my $page_error = '';

    eval {
        my $schema = $c->model('DBEncy');
        $audit = Comserv::Util::HealthLogger->audit_stats($schema, hours => $hours);
    };
    if ($@) {
        my $err = "$@";
        $page_error = "Audit statistics unavailable: $err";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'stats',
            "audit_stats failed: $err");
        $audit = { error => $page_error };
    }

    eval {
        my $schema = $c->model('DBEncy');
        $alerts = [ $schema->resultset('HealthAlert')->search(
            { status => { -in => ['OPEN', 'ACKNOWLEDGED'] } },
            { order_by => [
                { -asc  => \"FIELD(level,'CRITICAL','HIGH','MEDIUM','LOW')" },
                { -desc => 'last_seen' }
            ]}
        )->all ];
    };
    if ($@) {
        my $err = "$@";
        $page_error ||= "Health alerts unavailable: $err";
        $alerts = [];
    }

    # Render the fragment directly via TT with WRAPPER disabled —
    # [% META wrapper = '' %] alone does not override the configured WRAPPER.
    my $body = '';
    eval {
        my $vars = {
            %{ $c->stash },
            c          => $c,
            audit      => $audit,
            alerts     => $alerts,
            hours      => $hours,
            page_error => $page_error,
        };
        $c->view('TT')->template->process(
            'admin/Logging/LogAuditStats.tt',
            $vars,
            \$body,
            WRAPPER => '',
        ) or die $c->view('TT')->template->error;
    };
    if ($@) {
        my $err = "$@";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'stats',
            "stats render failed: $err");
        $body = '<div class="error">Error rendering audit stats: ' . $err . '</div>';
    }
    $c->res->content_type('text/html; charset=UTF-8');
    $c->res->body($body);
}

# POST /admin/logging/audit/prune
# Execute pruning with optional custom retention values
sub prune :Path('/admin/logging/audit/prune') :Args(0) {
    my ($self, $c) = @_;
    return $c->res->redirect($c->uri_for('/admin/logging/audit')) unless $c->req->method eq 'POST';

    my %opts = (
        debug_days    => int($c->req->param('debug_days')    || 1),
        info_days     => int($c->req->param('info_days')     || 2),
        warn_days     => int($c->req->param('warn_days')     || 7),
        error_days    => int($c->req->param('error_days')    || 30),
        critical_days => int($c->req->param('critical_days') || 90),
        max_records   => int($c->req->param('max_records')   || 10000),
    );

    my $deleted = 0;
    my $error   = '';
    eval {
        my $schema = $c->model('DBEncy');
        $deleted = Comserv::Util::HealthLogger->prune_old_records($schema, %opts);
    };
    $error = "$@" if $@;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'prune',
        "Manual prune executed: deleted=$deleted error=" . ($error || 'none'));

    if ($error) {
        $c->flash->{error_msg}   = "Prune failed: $error";
    } else {
        $c->flash->{success_msg} = "Pruned $deleted records from system_log.";
    }
    $c->res->redirect($c->uri_for('/admin/logging/audit'));
}

# POST /admin/logging/audit/alert_action
# Acknowledge or resolve a health_alert record
sub alert_action :Path('/admin/logging/audit/alert_action') :Args(0) {
    my ($self, $c) = @_;
    return $c->res->redirect($c->uri_for('/admin/logging/audit')) unless $c->req->method eq 'POST';

    my $alert_id = int($c->req->param('alert_id') || 0);
    my $action   = $c->req->param('action') || '';
    my $notes    = $c->req->param('notes')  || '';

    my %new_status = (acknowledge => 'ACKNOWLEDGED', resolve => 'RESOLVED');
    my $status = $new_status{$action};

    if ($alert_id && $status) {
        eval {
            my $schema = $c->model('DBEncy');
            my $alert  = $schema->resultset('HealthAlert')->find($alert_id);
            if ($alert) {
                my %upd = ( status => $status, notes => $notes );
                $upd{resolved_at} = \'NOW()' if $status eq 'RESOLVED';
                $alert->update(\%upd);
                $c->flash->{success_msg} = "Alert #$alert_id marked as $status.";
            }
        };
        $c->flash->{error_msg} = "Error updating alert: $@" if $@;
    }
    $c->res->redirect($c->uri_for('/admin/logging/audit'));
}

__PACKAGE__->meta->make_immutable;
1;
