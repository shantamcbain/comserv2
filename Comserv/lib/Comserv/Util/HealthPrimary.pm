package Comserv::Util::HealthPrimary;
# One health-check server per machine.
#
# Only the "primary" server on a host runs scheduled health work
# (hardware_monitor run/watchdog/report_down/ingest, logging_audit run,
# HealthLogger rows). Every other dev/branch server on the same host skips it.
#
# Decision order:
#   1. COMSERV_HEALTH_PRIMARY=1 / 0 in the environment wins.
#   2. Inside a container (Docker/Podman) -> primary: a container is its own
#      host, so prod :5000 keeps running its own checks.
#   3. Port this process listens on == <HealthCheck> primary_port (default 3001).
#      An unknown port (e.g. Starman with no -p) counts as primary, matching the
#      old behaviour where every server ran health checks.
# COMSERV_NO_HEALTH_LOG is separate and unchanged: it still silences health
# logging on any server, primary or not.
use strict;
use warnings;

my $DEFAULT_PRIMARY_PORT = 3001;

sub listen_port {
    my ($class, @argv) = @_;
    @argv = @ARGV unless @argv;
    my $p = $ENV{WEB_PORT} || $ENV{COMSERV_PORT} || $ENV{CATALYST_PORT} || '';
    return $p if $p;
    for my $i (0 .. $#argv) {
        my $a = $argv[$i] // '';
        my $n = $argv[$i + 1] // '';
        return $1 if $a =~ /^-p(\d+)$/ || $a =~ /^--port=(\d+)$/;
        return $n if ($a eq '-p' || $a eq '--port') && $n =~ /^\d+$/;
    }
    return '';
}

sub in_container {
    return 1 if -f '/.dockerenv' || -f '/run/.containerenv';
    return 1 if ($ENV{container} // '') =~ /^(docker|podman)$/;
    return 0;
}

sub primary_port {
    my ($class, $c) = @_;
    my $cfg;
    $cfg = eval { $c->config->{HealthCheck} } if $c && ref $c;
    $cfg ||= eval { Comserv->config->{HealthCheck} } if $INC{'Comserv.pm'};
    my $p = ref $cfg eq 'HASH' ? $cfg->{primary_port} : undef;
    return (defined $p && $p =~ /^\d+$/) ? $p : $DEFAULT_PRIMARY_PORT;
}

# Returns (is_primary, reason).
sub decide {
    my ($class, $c, %o) = @_;
    my $env = exists $o{env} ? $o{env} : $ENV{COMSERV_HEALTH_PRIMARY};
    if (defined $env && $env ne '') {
        return ($env =~ /^(1|yes|true|on)$/i ? 1 : 0, "COMSERV_HEALTH_PRIMARY=$env");
    }
    my $container = exists $o{container} ? $o{container} : $class->in_container;
    return (1, 'container') if $container;
    my $port    = exists $o{port} ? ($o{port} // '') : $class->listen_port;
    my $primary = exists $o{primary_port} ? $o{primary_port} : $class->primary_port($c);
    return (1, 'port unknown') if $port eq '';
    return ($port eq "$primary" ? 1 : 0, "port $port vs primary_port $primary");
}

sub is_primary { my ($ok) = shift->decide(@_); return $ok }

# Controller helper: if this server is not the health primary, answer the
# trigger with 200 {ok:1, skipped:1} and return true so the caller returns.
sub skip_response {
    my ($class, $c, $what) = @_;
    my ($ok, $why) = $class->decide($c);
    return 0 if $ok;
    $c->response->status(200);
    $c->response->content_type('application/json');
    require JSON;
    $c->response->body(JSON::encode_json({
        ok => 1, skipped => 1, what => $what // 'health',
        reason => "not health primary ($why)",
    }));
    return 1;
}

1;
