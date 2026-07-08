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

# Production-specific volumes (from docker-compose.prod.yml)
# Same as CANONICAL_VOLUMES — created on remote hosts via SSH
our @PRODUCTION_VOLUMES = @CANONICAL_VOLUMES;

# ─────────────────────────────────────────────────────────────────────────────
# PUBLIC ENTRY POINT — one method for all targets
# ─────────────────────────────────────────────────────────────────────────────
sub deploy {
    my ($self) = @_;
    my $repo   = $self->{repo};
    my $target = $self->{target};

    $self->_log("=== DEPLOY STARTED (target=$target, trigger=$self->{trigger}) ===");

    # 0. Map target to service/container/port/ssh details
    my ($service, $container_name, $port, $compose_files, $ssh_prefix, $is_remote);
    if ($target eq 'staging-4000' || $target eq 'local-staging') {
        $service        = 'web-staging';
        $container_name = 'comserv2-web-staging';
        $port           = 4000;
        $compose_files  = '-f docker-compose.yml';
        $is_remote      = 0;
    } elsif ($target eq 'web-dev') {
        $service        = 'web-dev';
        $container_name = 'comserv2-web-dev';
        $port           = 3000;
        $compose_files  = '-f docker-compose.yml';
        $is_remote      = 0;
    } elsif ($target eq 'workstation') {
        # Workstation: identical to production but runs locally
        $service        = 'web-prod';
        $container_name = 'comserv-web-prod';
        $port           = 5000;
        $compose_files  = '-f docker-compose.yml -f docker-compose.prod.yml';
        $is_remote      = 0;
        # Use repo root/static directory instead of /root/static (root-owned, may be empty)
        $ENV{STATIC_SRC}       = "$repo/root/static";
        # LegacyStaticPages is not in the repo — use default /root/LegacyStaticPages
    } elsif ($target eq 'local-test') {
        # Build & test only — build the prod image, quick verify, no deploy
        $service        = 'web-prod';
        $container_name = 'comserv-web-prod';
        $port           = 5000;
        $compose_files  = '-f docker-compose.yml -f docker-compose.prod.yml';
        $is_remote      = 0;
        # Use repo static dir for verification
        $ENV{STATIC_SRC}       = "$repo/root/static";
    } else {
        $service        = 'web-prod';
        $container_name = 'comserv-web-prod';
        $port           = 5000;
        $is_remote      = 1;
        my $ssh_host    = $target eq 'production1' ? '192.168.1.126'
                        : $target eq 'production2' ? '192.168.1.127'
                        : 'localhost';
        my $ssh_pass    = $ENV{SSHPASS} || '';
        $ssh_prefix     = $ssh_pass
            ? "sshpass -e ssh -o StrictHostKeyChecking=no ubuntu\@$ssh_host"
            : "ssh -o StrictHostKeyChecking=no ubuntu\@$ssh_host";
        # SCP prefix for transferring compose files
        my $scp_prefix  = $ssh_pass
            ? "sshpass -e scp -o StrictHostKeyChecking=no"
            : "scp -o StrictHostKeyChecking=no";
        # Sync compose files to remote BEFORE using them
        $compose_files  = $self->_sync_compose_to_remote($repo, $scp_prefix, $ssh_host);
    }

    # 1. Create all required volumes — local for dev, remote for production
    $self->_log("Step 1: Ensuring all required volumes exist...");
    if ($is_remote) {
        $self->ensure_all_required_volumes_remote($ssh_prefix);
    } else {
        $self->ensure_all_required_volumes($repo);
    }

    # 2. Build (local) then push if remote
    my $git_hash = `cd $repo && git rev-parse --short HEAD 2>/dev/null` || 'unknown';
    chomp $git_hash;
    $self->_log("Step 2: Building $service container (commit=$git_hash)...");
    $self->_stream_command("cd $repo && docker compose $compose_files build --progress plain $service 2>&1");
    # Tag with git hash for traceability
    system("docker tag shantamcsbain/comserv-web-prod:latest shantamcsbain/comserv-web-prod:$git_hash 2>/dev/null");
    $self->_log("Step 2b: Build finished (commit=$git_hash).");
    $self->{_git_hash} = $git_hash;

    if ($is_remote) {
        $self->_log("Step 3: Pushing $service to Docker Hub...");
        $self->_stream_command("cd $repo && docker compose $compose_files push $service 2>&1");
        $self->_log("Step 3b: Push finished.");
    }

    # 3. Rename old container to date-stamped backup (local or remote)
    $self->_log("Step 4: Renaming old $container_name to backup...");
    my $now     = DateTime->now(time_zone => 'local');
    my $ts      = $now->ymd('') . '_' . $now->hms('');
    my $backup  = "bk-$container_name-$ts";
    my $docker_ps_cmd = $is_remote
        ? "$ssh_prefix \"docker ps -a --format '{{.Names}}' 2>/dev/null\""
        : "docker ps -a --format '{{.Names}}' 2>/dev/null";
    my $ps_out = `$docker_ps_cmd`;
    my $found = 0;
    foreach my $n (split /\n/, $ps_out) {
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

    # 4. Rotate backups — keep max 5
    $self->_prune_backups($container_name, 5, $is_remote, $ssh_prefix);

    # 4.5 Stop any old backup container that may block port $port
    if ($is_remote) {
        # Stop all backup containers that might be holding the port
        $self->_stream_command("$ssh_prefix \"docker ps -q --filter 'name=bk-$container_name' --filter 'publish=$port' 2>/dev/null | xargs -r docker stop 2>&1 || true\"");
    } else {
        system("docker ps -q --filter 'name=bk-$container_name' --filter 'publish=$port' 2>/dev/null | xargs -r docker stop 2>&1 || true");
    }

    # 5. Start new container on remote (pull then up) or local (up only)
    if ($is_remote) {
        $self->_log("Step 5: Pulling image on $target and starting $service...");
        $self->_stream_command("$ssh_prefix \"cd $self->{_remote_compose_dir} && docker compose $compose_files pull $service && docker compose $compose_files up -d --force-recreate $service 2>&1\"");
    } else {
        $self->_log("Step 5: Starting $service on localhost...");
        $self->_stream_command("cd $repo && docker compose $compose_files up -d --force-recreate $service 2>&1");
    }

    # 6. Health-check loop (up to 60 seconds)
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
        if ($is_remote) {
            my $http_ok = system("$ssh_prefix \"curl -sf --max-time 2 http://localhost:$port/ >/dev/null 2>&1\"") == 0;
            if ($http_ok) { $healthy = 1; last; }
        } else {
            my $http_ok = system("curl -sf --max-time 2 http://localhost:$port/ >/dev/null 2>&1") == 0;
            if ($http_ok) { $healthy = 1; last; }
        }
        sleep 2;
    }

    if ($healthy) {
        $self->_log("✅ New $container_name is healthy – stopping backup $backup.");
        my $stop_cmd = $is_remote
            ? "$ssh_prefix \"docker stop $backup 2>&1 || true\""
            : "docker stop $backup 2>&1 || true";
        $self->_stream_command($stop_cmd);
        $self->_log("=== DEPLOY COMPLETE (target=$target) ===");
        $self->_save_deploy_log($container_name, $target);
        return 1;
    } else {
        $self->_log("✗ New $container_name failed health check – rolling back.");
        # Check if backup exists before trying to start it
        my $backup_exists = $is_remote
            ? `$ssh_prefix "docker ps -a -q --filter 'name=^$backup\$' 2>/dev/null"`
            : `docker ps -a -q --filter 'name=^$backup\$' 2>/dev/null`;
        chomp $backup_exists;
        if ($backup_exists) {
            my $rollback_cmd = $is_remote
                ? "$ssh_prefix \"docker start $backup 2>&1 || true\""
                : "docker start $backup 2>&1 || true";
            $self->_stream_command($rollback_cmd);
            $self->_error("Deploy FAILED on $target – rolled back to $backup. Old container restarted.");
        } else {
            $self->_error("Deploy FAILED on $target – no backup container to roll back to. Check container logs.");
        }
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

# Ensure production volumes exist on a remote host via SSH
sub ensure_all_required_volumes_remote {
    my ($self, $ssh_prefix) = @_;

    my @required = @PRODUCTION_VOLUMES;
    my @created;
    foreach my $v (@required) {
        my $exists = `$ssh_prefix "docker volume inspect $v 2>/dev/null"`;
        if ($exists) {
            $self->_log("Volume OK: $v");
        } else {
            $self->_log("Creating missing volume: $v");
            my $rc = system("$ssh_prefix \"docker volume create $v >/dev/null 2>&1\"");
            if ($rc == 0) {
                push @created, $v;
            } else {
                $self->_error("Failed to create volume: $v");
            }
        }
    }
    if (@created) {
        $self->_log("Created volumes on remote: " . join(', ', @created));
    } else {
        $self->_log("All volumes already exist on remote.");
    }
    foreach my $v (@required) {
        my $info = `$ssh_prefix "docker volume inspect $v 2>/dev/null"`;
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

# Local compose args — absolute paths (only valid on the workstation)
sub _compose_args {
    my ($self, $repo) = @_;
    my $base = "$repo/docker-compose.yml";
    my $prod = "$repo/docker-compose.prod.yml";
    return '-f ' . $base . ' -f ' . $prod;
}

# Sync compose files to remote host and return relative-file args.
# Creates /tmp/comserv-deploy-<ts>/ on the remote, SCPs the compose files
# there, and returns '-f docker-compose.yml -f docker-compose.prod.yml ...'
# (relative paths, to be used after cd-ing into the remote dir).
sub _sync_compose_to_remote {
    my ($self, $repo, $scp_prefix, $ssh_host) = @_;

    my $now = DateTime->now(time_zone => 'local');
    my $ts  = $now->ymd('') . '_' . $now->hms('');
    my $remote_dir = "/tmp/comserv-deploy-$ts";

    # List of compose files to transfer (base + prod only — no NFS on remote)
    my @files = ('docker-compose.yml', 'docker-compose.prod.yml');

    # 1. Create remote temp dir
    $self->_log("Syncing compose files to $ssh_host:$remote_dir ...");
    my $mkdir_cmd = $ENV{SSHPASS}
        ? "sshpass -e ssh -o StrictHostKeyChecking=no ubuntu\@$ssh_host \"mkdir -p $remote_dir\""
        : "ssh -o StrictHostKeyChecking=no ubuntu\@$ssh_host \"mkdir -p $remote_dir\"";
    my $rc = system($mkdir_cmd);
    if ($rc != 0) {
        $self->_error("Failed to create remote dir $remote_dir on $ssh_host (exit=$rc)");
        # Fallback: try using absolute workstation paths (will fail on remote,
        # but better than silent failure)
        return $self->_compose_args($repo);
    }

    # 2. SCP each compose file
    foreach my $f (@files) {
        my $local  = "$repo/$f";
        my $remote = "ubuntu\@$ssh_host:$remote_dir/";
        $self->_log("  Transferring $f ...");
        my $scp_cmd = "$scp_prefix $local $remote";
        $rc = system($scp_cmd);
        if ($rc != 0) {
            $self->_error("Failed to SCP $f to $ssh_host (exit=$rc)");
        }
    }

    # 3. Build relative-file args
    $self->{_remote_compose_dir} = $remote_dir;
    my @args;
    foreach my $f (@files) {
        push @args, '-f', $f;
    }
    my $compose_files = join(' ', @args);
    $self->_log("Compose synced to $remote_dir. Args: $compose_files");
    return $compose_files;
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