package Comserv::Controller::Health;
use Moose;
use namespace::autoclean;
use POSIX qw(strftime);
use Comserv::Util::HealthLogger;

BEGIN { extends 'Catalyst::Controller'; }

=head1 NAME

Comserv::Controller::Health - Health check and server health status endpoints

=head1 DESCRIPTION

Provides health check endpoints for Docker container health checks and
detailed health status for CSC admin monitoring.

=cut

# /health  -- lightweight liveness check used by Docker HEALTHCHECK
sub index :Path('') :Args(0) {
    my ($self, $c) = @_;
    $c->response->body('OK');
    $c->response->status(200);
}

# /health/status  -- basic status with Perl/Catalyst info (JSON)
sub status :Local :Args(0) {
    my ($self, $c) = @_;

    my %status = (
        timestamp        => scalar(localtime),
        perl_version     => $],
        catalyst_version => $Catalyst::VERSION // 'unknown',
        pid              => $$,
    );

    $c->response->content_type('application/json');
    $c->response->body(
        Comserv->json->encode(\%status)
    );
}

# /health/app_health  -- detailed server health summary from application_log
# Returns JSON with health score, status (OK/WARN/CRITICAL), and issue summary.
# Intended for CSC admin dashboards and monitoring scripts.
sub app_health :Local :Args(0) {
    my ($self, $c) = @_;

    my $minutes = $c->req->param('minutes') // 30;
    $minutes = 30 unless $minutes =~ /^\d+$/ && $minutes > 0 && $minutes <= 1440;

    my $health;
    eval {
        my $schema = $c->model('DBEncy');
        $health = Comserv::Util::HealthLogger->compute_health_score($schema, $minutes);
    };
    if ($@) {
        $health = {
            score   => 0,
            status  => 'UNKNOWN',
            summary => ["Health check failed: $@"],
        };
    }

    $health->{timestamp}   = strftime('%Y-%m-%d %H:%M:%S', localtime);
    $health->{window_min}  = $minutes;
    $health->{app_instance} = Comserv::Util::HealthLogger::_get_app_instance();

    my $http_status = $health->{status} eq 'OK'       ? 200
                    : $health->{status} eq 'WARN'      ? 200
                    : $health->{status} eq 'CRITICAL'  ? 503
                    :                                    200;

    $c->response->status($http_status);
    $c->response->content_type('application/json');
    $c->response->body(
        Comserv->json->encode($health)
    );
}

# /health/recent_errors  -- JSON list of recent error events (for admin UI)
sub recent_errors :Local :Args(0) {
    my ($self, $c) = @_;

    my $limit   = $c->req->param('limit')   // 50;
    my $minutes = $c->req->param('minutes') // 60;
    $limit   = 50  unless $limit   =~ /^\d+$/ && $limit   > 0 && $limit   <= 500;
    $minutes = 60  unless $minutes =~ /^\d+$/ && $minutes > 0 && $minutes <= 1440;

    my @rows;
    eval {
        my $cutoff = strftime('%Y-%m-%d %H:%M:%S',
            localtime(time() - $minutes * 60));

        my $rs = $c->model('DBEncy')->resultset('SystemLog')->search({
            message   => { -like => '[HEALTH]%' },
            level     => { -in   => ['ERROR', 'CRITICAL', 'WARN'] },
            timestamp => { '>='  => $cutoff },
        }, {
            order_by => { -desc => 'id' },
            rows     => $limit,
        });

        while (my $rec = $rs->next) {
            my ($cat, $inst) = ('GENERAL', 'unknown');
            if ($rec->message =~ /^\[HEALTH\]\[([^\]]+)\]\[([^\]]+)\]/) {
                $cat  = $1;
                $inst = $2;
            }
            push @rows, {
                id                => $rec->id,
                app_instance      => $rec->system_identifier // $inst,
                log_level         => $rec->level,
                category          => $cat,
                message           => $rec->message,
                sitename          => $rec->sitename // '',
                username          => $rec->username // '',
                timestamp         => $rec->timestamp . '',
                subroutine        => $rec->subroutine // '',
                system_identifier => $rec->system_identifier // '',
            };
        }
    };
    if ($@) {
        $c->response->status(500);
        $c->response->content_type('application/json');
        $c->response->body(Comserv->json->encode({ error => "Failed to fetch errors: $@" }));
        return;
    }

    $c->response->content_type('application/json');
    $c->response->body(Comserv->json->encode({
        count      => scalar(@rows),
        window_min => $minutes,
        events     => \@rows,
    }));
}

=head1 AUTHOR

Comserv Development Team

=head1 LICENSE

This library is free software. You can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

__PACKAGE__->meta->make_immutable;

1;
