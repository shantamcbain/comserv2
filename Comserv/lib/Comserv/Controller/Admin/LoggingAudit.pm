package Comserv::Controller::Admin::LoggingAudit;

use Moose;
use namespace::autoclean;
use JSON;
use Comserv::Util::Logging;
use Comserv::Util::LoggingAudit;

BEGIN { extends 'Comserv::Controller::Base'; }

has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->instance },
);

# Resolve the shared monitoring token — MUST match HardwareMonitor::_expected_token
# byte-for-byte (NFS single source of truth). Duplicated here deliberately so this
# controller is self-contained; keep the candidate list in lock-step with
# lib/Comserv/Controller/Admin/HardwareMonitor.pm.
sub _expected_token {
    my ($self) = @_;
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

# Cron-triggered scan (no browser session). Mirrors hardware_monitor.run:
# token-guarded, runs the audit, stores findings, returns JSON.
sub run :Path('/admin/logging_audit/run') :Args(0) {
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

    my $summary = eval { Comserv::Util::LoggingAudit->new->run_scan($c) };
    if ($@) {
        my $err = "$@"; $err =~ s/\s+/ /g;
        $self->logging->log_with_details($c, 'critical', __FILE__, __LINE__,
            'logging_audit.run', "[LOG-AUDIT] scan died: $err");
        $c->response->status(500);
        $c->response->content_type('application/json');
        $c->response->body(JSON::encode_json({ ok => 0, error => $err }));
        return;
    }

    $c->response->content_type('application/json');
    $c->response->body(JSON::encode_json({
        ok          => 1,
        run_id      => $summary->{run_id},
        code_sites  => scalar(@{ $summary->{code}{sites} // [] }),
        log_error   => $summary->{log}{error} // undef,
        code_error  => $summary->{code}{error} // undef,
    }));
}

# Manual trigger from the results page ("Run scan now" button — POSTs here).
sub trigger :Path('/admin/logging_audit/trigger') :Args(0) {
    my ($self, $c) = @_;
    # Admin-only; relies on Root.pm role gate (this path is NOT in the bypass list).
    my $summary = eval { Comserv::Util::LoggingAudit->new->run_scan($c) };
    if ($@) {
        $c->flash->{error_msg} = "Scan failed: $@";
    } else {
        $c->flash->{status_msg} = "Logging audit run $summary->{run_id} complete: "
            . scalar(@{ $summary->{code}{sites} // [] }) . " code sites flagged.";
    }
    $c->response->redirect($c->uri_for('/admin/logging_audit'));
}

# Results page: show the latest scan run's findings + "Run scan now" button.
sub index :Path('/admin/logging_audit') :Args(0) {
    my ($self, $c) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
        'Loading logging audit results');

    my $findings = [];
    my $latest_run = '';
    eval {
        my $schema = $c->model('DBEncy');
        my ($last) = $schema->resultset('LoggingAudit')->search(
            {}, { order_by => { -desc => 'created_at' }, rows => 1 }
        )->single;
        $latest_run = $last ? $last->scan_run_id : '';

        if ($latest_run) {
            my $rs = $schema->resultset('LoggingAudit')->search(
                { scan_run_id => $latest_run },
                { order_by   => { -desc => 'severity' }, -asc => 'file_path' }
            );
            while (my $f = $rs->next) {
                push @$findings, {
                    severity       => $f->severity,
                    scan_type      => $f->scan_type,
                    target         => $f->target,
                    finding        => $f->finding,
                    detail         => $f->detail,
                    file_path      => $f->file_path,
                    line_no        => $f->line_no,
                    recommendation => $f->recommendation,
                    created_at     => $f->created_at,
                };
            }
        }
    };
    if ($@) {
        $c->stash(error_msg => "Could not load findings: $@");
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'index',
            "logging_audit index load failed: $@");
    }

    $c->stash(
        template     => 'admin/LoggingAudit/Index.tt',
        findings     => $findings,
        latest_run   => $latest_run,
        run_url      => $c->uri_for('/admin/logging_audit/run'),
        trigger_url  => $c->uri_for('/admin/logging_audit/trigger'),
    );
}

1;
