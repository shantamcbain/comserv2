package Comserv::Util::HealthLogger;

use strict;
use warnings;
use Exporter 'import';
use JSON;
use Time::Piece;
use FindBin;
use File::Spec;
use Carp qw(carp croak);

our @EXPORT_OK = qw(
    log_health_event
    compute_health_score
    evaluate_records
    record_docker_health_snapshot
    sync_remote_docker_hosts
    get_docker_health
    get_docker_health_from_db
    get_active_servers_from_db
    audit_stats
    prune_old_records
);

# Get a logger instance (avoid circular dependency)
my $logging;
eval {
    require Comserv::Util::Logging;
    $logging = Comserv::Util::Logging->new;
};
$logging ||= bless({}, 'Comserv::Util::Logging');

# Cache for schema to avoid repeated lookups
my $_standalone_schema;

# Early exit guard (used inside functions)
sub _disabled { ($ENV{COMSERV_NO_HEALTH_LOG} // '') eq '1' }

sub _schema {
    my ($c) = @_;

    if (!$c || !eval { $c->can('model') }) {
        return _get_standalone_schema();
    }

    my $s = eval { $c->model('DBEncy') };
    return $s if $s;

    return _get_standalone_schema();
}

sub _get_standalone_schema {
    eval {
        require Comserv;
        my $app = Comserv->new;
        $_standalone_schema = $app->model('DBEncy');
    };
    if ($@ || !$_standalone_schema) {
        my $err = $@ || 'unknown error';
        $logging->log_with_details(undef, 'error', __FILE__, __LINE__,
            'HealthLogger::_schema',
            "Failed to obtain DBEncy schema: $err"
        );
        return undef;
    }
    return $_standalone_schema;
}

sub log_health_event {
    my ($c, $level, $event_type, $message, $metadata) = @_;
    return if _disabled();

    my $schema = _schema($c);
    return unless $schema;

    eval {
        $schema->resultset('HealthAlert')->create({
            level       => $level || 'info',
            event_type  => $event_type || 'general',
            message     => $message || '',
            metadata    => $metadata ? encode_json($metadata) : undef,
            created_at  => DateTime->now,
        });
    };
    if ($@) {
        $logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'HealthLogger::log_health_event', "Failed to log health event: $@");
    }
}

sub compute_health_score {
    my ($schema, $minutes) = @_;
    return { status => 'OK', score => 100 } if _disabled();
    # ... rest of implementation would go here ...
    return { status => 'OK', score => 100 };
}

sub evaluate_records {
    my ($schema, $minutes) = @_;
    return [] if _disabled();
    return [];
}

sub record_docker_health_snapshot { return if _disabled(); }
sub sync_remote_docker_hosts    { return if _disabled(); }
sub get_docker_health           { return {} if _disabled(); }
sub get_docker_health_from_db   { return {} if _disabled(); }
sub get_active_servers_from_db  { return [] if _disabled(); }
sub audit_stats                 { return {} if _disabled(); }
sub prune_old_records           { return 0  if _disabled(); }

sub _get_app_instance {
    return $ENV{HOSTNAME} || 'unknown';
}

1;