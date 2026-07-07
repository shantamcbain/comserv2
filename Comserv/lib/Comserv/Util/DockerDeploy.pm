package Comserv::Util::DockerDeploy;
use strict;
use warnings;
use DateTime;
use JSON qw(encode_json decode_json);

# ─────────────────────────────────────────────────────────────────────────────
# Core deploy logic - one routine for ALL deployment targets.
# Handles: volume creation, backup rotation, build/up, health-check, rollback.
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
    print $fh "[".scalar(localtime)."] $msg\n";
    $fh->flush();
}

sub _error {
    my ($self, $msg) = @_;
    $self->_log("ERROR: $msg");
    $self->{logging}->log_with_details(undef, 'error', __FILE__, __LINE__, 'docker_deploy', $msg)
        if $self->{logging};
}

# Canonical volumes required on every server
our @CANONICAL_VOLUMES = qw(
    comserv2_config_db_data comserv2_redis_data comserv2_logs
    comserv2_sessions comserv2_workshop_files comserv2_whisper_venv
    comserv2_cpan_cache comserv2_temp comserv2_themes comserv2_cache
);

# ─────────────────────────────────────────────────────────────────────────────
# PUBLIC ENTRY POINT — one method for all targets
# ─────────────────────────────────────────────────────────────────────────────
sub deploy {
    my ($self) = @_;
    my $repo   = $self->{repo};
    my $target = $self->{target};

    $self->_log("=== DEPLOY STARTED (target=$target, trigger=$self->{trigger}) ===");

    # 1. Create all required volumes (same routine for every target)
    $self->_log("Step 1: Ensuring all required volumes exist...");
    $self->ensure_all_required_volumes($repo);

    # 2. Map target to service name and build/up strategy
    my ($service, $container_name, $port, $compose_args, $ssh_prefix, $is_remote);
    if ($target eq 'staging-4000' || $target eq 'local-staging') {
        $service        = 'web-staging';
        $container_name = 'comserv2-web-staging';
        $port           = 4000;
        $compose_args   = '-f docker-compose.yml';
        $is_remote      = 0;
    } elsif ($target eq 'web-dev') {
        $service        = 'web-dev';
        $container_name = 'comserv2-web-dev';
        $port           = 3000;
        $compose_args   = '-f docker-compose.yml';
        $is_remote      = 0;
    } else {
        $service        = 'web-prod';
        $container_name = 'comserv2-web-prod';
        $port           = 5000;
        $compose_args   = $self->_compose_args($repo);
        $is_remote      = 1;
        my $ssh_host    = $target eq 'production1' ? '192.168.1.126'
                        : $target eq 'production2' ? '192.168.1.127'
                        : 'localhost';
        $ssh_prefix     = "ssh -o StrictHostKeyChecking=no ubuntu\@$ssh_host";
    }

    # 3. Build (local) or build+push (remote production)
    # Tag the image with the git commit hash for build identity
    my $git_hash = `cd $repo && git rev-parse --short HEAD 2>/dev/null` || 'unknown';
    chomp $git_hash;
    $self->_log("Step 2: Building $service container (commit=$git_hash)...");
    $self->_stream_command("cd $repo && docker compose $compose_args build --progress plain $service 2>&1");
    # Tag with git hash for traceability
    system("docker tag shantamcsbain/comserv-web-prod:latest shantamcsbain/comserv-web-prod:$git_hash 2>/dev/null");
    $self->_log("Step 2b: Build finished (commit=$git_hash).");
    $self->{_git_hash} = $git_hash;  # stash for later use

    if ($is_remote) {
        $self->_log("Step 3: Pushing $service to Docker Hub...");
        $self->_stream_command("cd $repo && docker compose $compose_args push $service 2>&1");
        $self->_log("Step 3b: Push finished.");
    }

    # 4. Rename old container to date-stamped backup (local or remote)
    $self->_log("Step 4: Renaming old $container_name to backup...");
    my $now     = DateTime->now(time_zone => 'local');
    my $ts      = $now->ymd('') . '_' . $now->hms('');
    my $backup  = "bk-$container_name-$ts";
    my $docker_ps_cmd = $is_remote
        ? "$ssh_prefix \"docker ps -a --format '{{.Names}}' 2>/dev/null\""
        : "docker ps -a --format '{{.Names}}' 2>/dev/null";
    my $ps_out = `$docker_ps_cmd`;
    my $found = 0;
    foreach my $n (split /\\n/, $ps_out) {
        chomp $n;
        if ($n eq $container_name) {
            $found = 1;
            last;
        }
    }
    $self->_log("  Container check: ps found=" . ($found ? 'yes' : 'no'));
    if ($found) {
        my $rename_cmd = $is_remote
            ? "$ssh_prefix \"docker rename $container_name $backup 2>&1\""
            : "docker rename $container_name $backup 2>&1";
        $self->_stream_command($rename_cmd);
        $self->_log("Renamed old container to $backup");
    } else {
        $self->_log("No existing container named $container_name found — will be created fresh.");
    }

    # 5. Rotate backups — keep max 5 (prune oldest)
    $self->_prune_backups($container_name, 5, $is_remote, $ssh_prefix);

    # 6. Start new container (pull first if remote)
    if ($is_remote) {
        $self->_log("Step 5: Pulling image on $target and starting $service...");
        $self->_stream_command("$ssh_prefix \"cd /home/shanta/PycharmProjects/comserv2/Comserv && docker compose $compose_args pull $service && docker compose $compose_args up -d --force-recreate $service 2>&1\"");
    } else {
        $self->_log("Step 5: Starting $service on localhost...");
        $self->_stream_command("cd $repo && docker compose $compose_args up -d --force-recreate $service 2>&1");
    }

    # 7. Health-check loop (up to 60 seconds)
    $self->_log("Step 6: Waiting for $container_name to become healthy...");
    my $healthy = 0;
    for my $i (1..30) {
        my $health;
        if ($is_remote) {
            $health = `$ssh_prefix "docker inspect --format='{{.State.Health.Status}}' $container_name 2>/dev/null || echo 'unknown'"`;
        } else {
            $health = `docker inspect --format='{{.State.Health.Status}}' $container_name 2>/dev/null || echo 'unknown'`;
        }
        chomp $health;
        $self->_log("  [$i/30] health=$health");
        if ($health =~ /healthy/i) { $healthy = 1; last; }
        my $http_url = $is_remote ? "http://localhost:$port" : "http://localhost:$port";
        my $http_ok = system("curl -sf --max-time 2 $http_url/ >/dev/null 2>&1") == 0;
        if ($http_ok) { $healthy = 1; last; }
        sleep 2;
    }

    if ($healthy) {
        $self->_log("✅ New $container_name is healthy – stopping backup $backup.");
        my $stop_cmd = $is_remote
            ? "$ssh_prefix \"docker stop $backup 2>&1 || true\""
            : "docker stop $backup 2>&1 || true";
        $self->_stream_command($stop_cmd);
        $self->_log("=== DEPLOY COMPLETE (target=$target) ===");
        # Save deploy log to per-container file
        $self->_save_deploy_log($container_name, $target);
        return 1;
    } else {
        $self->_log("✗ New $container_name failed health check – rolling back to $backup.");
        my $rollback_cmd = $is_remote
            ? "$ssh_prefix \"docker start $backup 2>&1 || true\""
            : "docker start $backup 2>&1 || true";
        $self->_stream_command($rollback_cmd);
        $self->_error("Deploy FAILED on $target – rolled back to $backup. Old container restarted.");
        $self->_log("=== DEPLOY FAILED (target=$target) ===");
        $self->_save_deploy_log($container_name, $target);
        return 0;
    }
}

# Backward-compatible wrappers
sub deploy_to_target_safe { my $self = shift; $self->deploy; }
sub deploy_local_staging  { my $self = shift; $self->deploy; }
sub deploy_to_target      { my $self = shift; $self->deploy; }

# ─────────────────────────────────────────────────────────────────────────────
# Volume management
# ─────────────────────────────────────────────────────────────────────────────
sub ensure_all_required_volumes {
    my ($self, $repo) = @_;
    $repo ||= $self->{repo};

    my @required = @CANONICAL_VOLUMES;
    my @created;
    foreach my $v (@required) {
        my $exists = `docker volume inspect $v 2>/dev/null`;
        if ($exists) {
            $self->_log("Volume OK: $v");
        } else {
            $self->_log("Creating missing volume: $v");
            my $rc = system("docker volume create $v >/dev/null 2>&1");
            if ($rc == 0) {
                push @created, $v;
            } else {
                $self->_error("Failed to create volume: $v");
            }
        }
    }
    if (@created) {
        $self->_log("Created volumes: " . join(', ', @created));
    } else {
        $self->_log("All volumes already exist.");
    }
    # Verify volumes exist (fast inspect, no container needed)
    foreach my $v (@required) {
        my $info = `docker volume inspect $v 2>/dev/null`;
        if ($info) {
            $self->_log("  $v OK");
        } else {
            $self->_error("  $v NOT FOUND despite create attempt");
        }
    }
    return (1, \@created);
}

# ─────────────────────────────────────────────────────────────────────────────
# Backup pruning — keeps at most N backup containers for a given base name
# ─────────────────────────────────────────────────────────────────────────────
sub _prune_backups {
    my ($self, $base_name, $max_keep, $is_remote, $ssh_prefix) = @_;
    $max_keep ||= 5;

    my $list_cmd = $is_remote
        ? "$ssh_prefix \"docker ps -a --format '{{.Names}}' 2>/dev/null | grep '^bk-$base_name-' | sort\""
        : "docker ps -a --format '{{.Names}}' 2>/dev/null | grep '^bk-$base_name-' | sort";
    my $output = `$list_cmd` || '';
    my @backups = split /\n/, $output;
    return if @backups <= $max_keep;

    # Remove oldest (sorted so first entries are oldest)
    my @to_remove = splice @backups, 0, (@backups - $max_keep);
    foreach my $old (@to_remove) {
        chomp $old;
        $self->_log("Pruning old backup: $old");
        my $rm_cmd = $is_remote
            ? "$ssh_prefix \"docker rm -f $old 2>&1 || true\""
            : "docker rm -f $old 2>&1 || true";
        $self->_stream_command($rm_cmd);
    }
    $self->_log("Pruned " . scalar(@to_remove) . " old backup(s), keeping $max_keep.");
}

# ─────────────────────────────────────────────────────────────────────────────
# Save deploy log to a per-container file for later viewing
# ─────────────────────────────────────────────────────────────────────────────
sub _save_deploy_log {
    my ($self, $container_name, $target) = @_;
    my $log_dir = '/home/shanta/PycharmProjects/comserv2/log/docker_deploy';
    system("mkdir -p $log_dir/$container_name") == 0
        or warn "Cannot create $log_dir/$container_name: $!";
    my $now = DateTime->now(time_zone => 'local');
    my $ts  = $now->ymd('') . '_' . $now->hms('');
    my $path = "$log_dir/$container_name/deploy_$ts.log";
    # Get backup name from the last backup created (freshest)
    my $backup_name = `docker ps -a --format '{{.Names}}' 2>/dev/null | grep '^bk-$container_name-' | tail -1` || '';
    chomp $backup_name;
    # Read the temp log file and copy to per-container file with metadata header
    if (open my $src, '<', '/tmp/comserv_deploy.log') {
        if (open my $dst, '>', $path) {
            print $dst "# Deploy target: $target\n";
            print $dst "# Container: $container_name\n";
            print $dst "# Backup: $backup_name\n" if $backup_name;
            print $dst "# Timestamp: $ts\n";
            print $dst "#\n";
            print $dst do { local $/; <$src> };
            close $dst;
        }
        close $src;
    }
    $self->_log("Deploy log saved to $path");
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

1;