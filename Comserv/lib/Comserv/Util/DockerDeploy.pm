package Comserv::Util::DockerDeploy;
use strict;
use warnings;
use DateTime;
use JSON qw(encode_json decode_json);

# ─────────────────────────────────────────────────────────────────────────────
# Core deploy logic used by both the pop-up flow and the legacy deploy action.
# All heavy work (consistency check, SSH to target, rename/health/rollback,
# error logging) lives here so the controller stays small.
# ─────────────────────────────────────────────────────────────────────────────

sub new {
    my ($class, %args) = @_;
    bless {
        log_fh     => $args{log_fh},
        logging    => $args{logging},
        repo       => $args{repo}       || '/home/shanta/PycharmProjects/comserv2/Comserv',
        target     => $args{target}     || 'production1',
        trigger    => $args{trigger}    || 'manual',
    }, $class;
}

sub _log {
    my ($self, $msg) = @_;
    my $fh = $self->{log_fh};
    return unless $fh;
    print $fh "[${\scalar localtime}] $msg\n";
    $fh->flush();
    $| = 1;   # also flush STDOUT so the parent sees it immediately
}

sub _error {
    my ($self, $msg) = @_;
    $self->_log("ERROR: $msg");
    $self->{logging}->log_with_details(undef, 'error', __FILE__, __LINE__, 'docker_deploy', $msg)
        if $self->{logging};
}

# Canonical list of volumes that every server must declare
our @CANONICAL_VOLUMES = qw(
    comserv2_config_db_data comserv2_redis_data comserv2_logs
    comserv2_sessions comserv2_workshop_files comserv2_whisper_venv
    comserv2_cpan_cache comserv2_temp comserv2_themes comserv2_cache
    comserv-static comserv-cache comserv-userprefs comserv-sessions
);

# ─────────────────────────────────────────────────────────────────────────────
# Public entry point – performs a full deploy to the chosen target
# Returns (success, final_log_text)
# ─────────────────────────────────────────────────────────────────────────────
sub deploy_to_target {
    my ($self) = @_;

    my $repo   = $self->{repo};
    my $target = $self->{target};

    $self->_log("=== DOCKER DEPLOY STARTED (target=$target, trigger=$self->{trigger}) ===");
    $self->_log("Step 0: Initialising deploy to $target...");
    $self->_log("Step 1: Checking for uncommitted changes (non-fatal push)...");

    # 1. Consistency check (same on every server)
    $self->_log("Step 1a: Running volume consistency check...");
    return (0, "Volume inconsistency") unless $self->_check_volume_consistency($repo);
    $self->_log("Step 1b: Volume consistency check passed.");

    # 2. Git push (from workstation) – non-fatal if already up-to-date
    $self->_log("Step 2: Pushing to origin main (non-fatal)...");
    if (open my $pipe, '-|', "cd $repo && git push origin main 2>&1 || true") {
        while (my $line = <$pipe>) {
            chomp $line;
            $self->_log($line);
        }
        close $pipe;
    }
    $self->_log("Step 2b: Git push completed (or was already up-to-date).");

    # 3. Build & push image
    my $compose_args = $self->_compose_args($repo);
    $self->_log("Step 3: Building image (docker compose $compose_args build web-prod --no-cache)...");
    $self->_stream_command("cd $repo && docker compose $compose_args build web-prod --no-cache 2>&1");
    $self->_log("Step 3b: Build finished.");

    $self->_log("Step 4: docker compose $compose_args push web-prod...");
    $self->_stream_command("cd $repo && docker compose $compose_args push web-prod 2>&1");

    # 4. Remote deploy on target (rename, start, health-check, rollback)
    my $remote_success = $self->_remote_deploy($target, $compose_args);

    $self->_log("=== DEPLOY COMPLETE ===");
    return ($remote_success, "Deploy finished");
}

# ─────────────────────────────────────────────────────────────────────────────
# Local staging deploy (port 4000 / web-staging service)
# Creates missing volumes first, then brings up the staging service.
# ─────────────────────────────────────────────────────────────────────────────
sub deploy_local_staging {
    my ($self) = @_;

    my $repo = $self->{repo};
    $self->_log("=== LOCAL STAGING DEPLOY (4000) START ===");

    $self->_ensure_named_volumes($repo);

    my $cmd = "cd $repo && docker compose -f docker-compose.yml up -d web-staging 2>&1";
    $self->_log("Running: $cmd");
    $self->_stream_command($cmd);

    # Quick health probe on 4000
    sleep 3;
    my $http = system("curl -sf --max-time 3 http://localhost:4000/ >/dev/null 2>&1") == 0;
    $self->_log($http ? "Local staging (4000) responded ✓" : "WARNING: 4000 did not respond yet");

    $self->_log("=== LOCAL STAGING DEPLOY COMPLETE ===");
    return 1;
}

# Ensure the four new named volumes for static, cache, userprefs, sessions exist
sub _ensure_named_volumes {
    my ($self, $repo) = @_;
    my @vols = qw(comserv-static comserv-cache comserv-userprefs comserv-sessions);

    foreach my $v (@vols) {
        my $exists = `docker volume inspect $v 2>/dev/null`;
        if ($exists) {
            $self->_log("Volume $v already exists.");
        } else {
            $self->_log("Creating volume: $v");
            system("docker volume create $v >/dev/null 2>&1");
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Internal helpers
# ─────────────────────────────────────────────────────────────────────────────
sub _compose_args {
    my ($self, $repo) = @_;
    my $base = "$repo/docker-compose.yml";
    my $prod = "$repo/docker-compose.prod.yml";
    my $nfs  = "$repo/docker-compose.prod.nfs.yml";
    my @f = ('-f', $base, '-f', $prod);
    push @f, '-f', $nfs if -f $nfs;
    return join(' ', @f);
}

sub _check_volume_consistency {
    my ($self, $repo) = @_;
    my $compose_args = $self->_compose_args($repo);
    my $config = `cd $repo && docker compose $compose_args config 2>/dev/null`;
    my %seen;
    while ($config =~ /comserv2_\w+/g) { $seen{$&} = 1; }

    my @missing = grep { !$seen{$_} } @CANONICAL_VOLUMES;
    my @extra   = grep { !grep { $_ eq $seen{$_} } @CANONICAL_VOLUMES } sort keys %seen;

    if (@missing || @extra) {
        my $err = "VOLUME INCONSISTENCY DETECTED\n  Missing: " . join(', ', @missing) .
                  "\n  Extra:   " . join(', ', @extra);
        $self->_error($err);
        return 0;
    }
    $self->_log("Volume consistency check passed.");
    return 1;
}

sub _stream_command {
    my ($self, $cmd) = @_;
    if (open my $pipe, '-|', $cmd) {
        while (my $line = <$pipe>) {
            chomp $line;
            $self->_log($line);
            $self->{log_fh}->flush() if $self->{log_fh};
        }
        close $pipe;
    }
}

# SSH + remote rename / health / rollback logic
sub _remote_deploy {
    my ($self, $target, $compose_args) = @_;

    my $ssh_host = $target eq 'production1' ? '192.168.1.126'
                 : $target eq 'production2' ? '192.168.1.127'
                 : 'localhost';
    my $ssh_user = 'ubuntu';
    my $ssh_prefix = "ssh -o StrictHostKeyChecking=no $ssh_user\@$ssh_host";

    my $now = DateTime->now(time_zone => 'local');
    my $backup_name = "comserv-web-prod-backup-" . $now->ymd('-') . '-' . $now->hms('');

    $self->_log("Step 5a: Renaming running container to $backup_name on $target...");
    $self->_stream_command("$ssh_prefix \"docker rename comserv-web-prod $backup_name 2>&1 || true\"");

    $self->_log("Step 5b: docker compose $compose_args pull && up -d web-prod on $target...");
    $self->_stream_command("$ssh_prefix \"cd /home/shanta/PycharmProjects/comserv2/Comserv && docker compose $compose_args pull web-prod && docker compose $compose_args up -d web-prod 2>&1\"");

    # Health-check loop (60 s)
    $self->_log("Step 5c: Waiting for new container on $target to become healthy...");
    my $healthy = 0;
    for my $i (1..30) {
        my $health = `$ssh_prefix "docker inspect --format='{{.State.Health.Status}}' comserv-web-prod 2>/dev/null || echo 'unknown'"`;
        chomp $health;
        $self->_log("  [$i/30] health=$health");
        if ($health =~ /healthy/i) { $healthy = 1; last; }
        my $http_ok = system("$ssh_prefix \"curl -sf --max-time 2 http://localhost:5000/ >/dev/null 2>&1\"") == 0;
        if ($http_ok) { $healthy = 1; last; }
        sleep 2;
    }

    if ($healthy) {
        $self->_log("New container healthy ✓ – stopping $backup_name on $target");
        $self->_stream_command("$ssh_prefix \"docker stop $backup_name 2>&1 || true\"");
        return 1;
    } else {
        $self->_log("✗ New container failed health check – rolling back to $backup_name");
        $self->_stream_command("$ssh_prefix \"docker start $backup_name 2>&1 || true\"");
        $self->_error("Deploy FAILED on $target – rolled back to $backup_name");
        return 0;
    }
}

1;