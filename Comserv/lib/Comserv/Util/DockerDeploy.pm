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
        no_cache   => $args{no_cache}   // 0,
        mode       => $args{mode}       || 'full',   # full, build-push, pull-deploy
        # Custom registry auth for pull-deploy
        registry_url  => $args{registry_url}  || '',
        registry_user => $args{registry_user} || '',
        registry_pass => $args{registry_pass} || '',
        image_tag     => $args{image_tag}     || '',
    }, $class;
}

sub _log {
    my ($self, $msg) = @_;
    my $fh = $self->{log_fh};
    return unless $fh;
    print $fh "[" . scalar(localtime) . "] $msg\n";
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
# Shared helper subroutines — single code path for container operations
# ─────────────────────────────────────────────────────────────────────────────

# Check if a container exists (by exact name match)
sub _container_exists {
    my ($self, $name, $is_remote, $ssh_prefix) = @_;
    my $cmd = $is_remote
        ? "$ssh_prefix \"docker ps -a -q --filter 'name=^$name\$' 2>/dev/null\""
        : "docker ps -a -q --filter 'name=^$name\$' 2>/dev/null";
    my $out = `$cmd` || '';
    chomp $out;
    return $out ? 1 : 0;
}

# Rename a Docker container (old → new). Returns exit code (0 = success).
# When $ignore_failure is true, failures are logged but non-fatal.
sub _rename_container {
    my ($self, $old_name, $new_name, $is_remote, $ssh_prefix, $ignore_failure) = @_;
    my $suffix = $ignore_failure ? ' || true' : '';
    my $cmd = $is_remote
        ? "$ssh_prefix \"docker rename $old_name $new_name 2>&1$suffix\""
        : "docker rename $old_name $new_name 2>&1$suffix";
    my $rc = $self->_stream_command($cmd);
    if ($rc == 0) {
        $self->_log("  Renamed $old_name → $new_name");
    } elsif (!$ignore_failure) {
        $self->_error("  Failed to rename $old_name → $new_name (exit=$rc)");
    }
    return $rc;
}

# Create a timestamped backup of a running container.
# Returns the backup name, or undef if the container doesn't exist.
sub _backup_container {
    my ($self, $container_name, $is_remote, $ssh_prefix) = @_;

    $self->_log("Backing up $container_name...");
    my $found = $self->_container_exists($container_name, $is_remote, $ssh_prefix);
    $self->_log("  Container check: " . ($found ? "found" : "not found"));

    if ($found) {
        my $now    = DateTime->now(time_zone => 'local');
        my $ts     = $now->ymd('') . '_' . $now->hms('');
        my $backup = "bk-$container_name-$ts";
        $self->_rename_container($container_name, $backup, $is_remote, $ssh_prefix, 0);
        return $backup;
    }

    $self->_log("  No existing container named $container_name — skipping backup, will create fresh.");
    return undef;
}

# ─────────────────────────────────────────────────────────────────────────────
# Docker registry login — supports both local and remote targets
# ─────────────────────────────────────────────────────────────────────────────
sub _docker_login {
    my ($self, $is_remote, $ssh_prefix) = @_;

    my $url  = $self->{registry_url}  || '';
    my $user = $self->{registry_user} || '';
    my $pass = $self->{registry_pass} || '';

    return 1 unless $url && $user;   # no custom registry — proceed
    $self->_log("Logging into registry: $url (user=$user)...");
    my $cmd;
    if ($is_remote) {
        $cmd = qq{$ssh_prefix "echo '$pass' | docker login $url --username '$user' --password-stdin 2>&1"};
    } else {
        $cmd = qq{echo '$pass' | docker login $url --username '$user' --password-stdin 2>&1};
    }
    my $rc = $self->_stream_command($cmd);
    if ($rc != 0) {
        $self->_error("Docker login to $url failed (exit=$rc)");
        return 0;
    }
    $self->_log("  Docker login to $url succeeded.");
    return 1;
}

sub deploy {
    my ($self) = @_;
    my $repo   = $self->{repo};
    my $target = $self->{target};
    my $mode   = $self->{mode};
    my $image_tag = $self->{image_tag} || 'latest';

    $self->_log("=== DEPLOY STARTED (target=$target, trigger=$self->{trigger}, mode=$mode) ===");

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
        $compose_files  = '-f docker-compose.dev.yml';
        $is_remote      = 0;
        # Use repo root/static directory instead of /root/static (root-owned, may be empty)
        $ENV{STATIC_SRC}       = "$repo/root/static";
    } elsif ($target eq 'local-test') {
        $service        = 'web-prod';
        $container_name = 'comserv-web-prod';
        $port           = 5000;
        $compose_files  = '-f docker-compose.dev.yml';
        $is_remote      = 0;
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
        my $ssh_user    = 'ubuntu';
        my $cred_file   = $ENV{HOME} . '/.comserv/secrets/ssh_credentials.json';
        if (-f $cred_file) {
            open(my $cfh, '<', $cred_file) or warn "Can't open $cred_file: $!";
            my $json_str = do { local $/; <$cfh> };
            close $cfh;
            my $creds = decode_json($json_str);
            if ($creds->{$target} && $creds->{$target}->{ssh_user}) {
                $ssh_user = $creds->{$target}->{ssh_user};
            }
        }
        $self->{ssh_user} = $ssh_user;
        $ssh_prefix     = $ssh_pass
                    ? "sshpass -e ssh -o StrictHostKeyChecking=no $ssh_user\@$ssh_host"
                    : "ssh -o StrictHostKeyChecking=no $ssh_user\@$ssh_host";
        my $scp_prefix  = $ssh_pass
            ? "sshpass -e scp -o StrictHostKeyChecking=no"
            : "scp -o StrictHostKeyChecking=no";
        $compose_files  = $self->_sync_compose_to_remote($repo, $scp_prefix, $ssh_host);
    }

    # ── PUSH ONLY mode ──
    if ($mode eq 'push-only') {
        $self->_log("Step 2: Pushing $service to Docker Hub (no rebuild)...");
        my $rc = $self->_stream_command("cd $repo && docker compose $compose_files push $service 2>&1");
        if ($rc != 0) {
            $self->_log("✗ Push failed (exit=$rc).");
            $self->_save_deploy_log($container_name, $target);
            return 0;
        }
        $self->_log("=== PUSH ONLY COMPLETE (target=$target) ===");
        $self->_log("The running $container_name is untouched. Use 'Pull & Deploy' on the production server to deploy this image.");
        $self->_save_deploy_log($container_name, $target);
        return 1;
    }

    # ── VOLUME CREATION (always runs for all modes) ──
    $self->_log("Step 1: Ensuring all required volumes exist...");
    if ($is_remote) {
        $self->ensure_all_required_volumes_remote($ssh_prefix);
    } else {
        $self->ensure_all_required_volumes($repo);
    }

    # ── BUILD & PUSH phase (steps 2-3) ──
    if ($mode ne 'pull-deploy') {
        my $git_hash = `cd $repo && git rev-parse --short HEAD 2>/dev/null` || 'unknown';
        chomp $git_hash;
        $self->_log("Step 2: Building $service container (commit=$git_hash)" . ($self->{no_cache} ? ' [--no-cache]' : '') . "...");
        my $no_cache_flag = $self->{no_cache} ? ' --no-cache' : '';
        my $build_rc = $self->_stream_command("cd $repo && docker compose $compose_files build --progress plain$no_cache_flag $service 2>&1");
        if ($build_rc != 0) {
            $self->_log("✗ Build failed (exit=$build_rc) — aborting. Running container $container_name is untouched.");
            $self->_save_deploy_log($container_name, $target);
            return 0;
        }
        system("docker tag shantamcsbain/comserv-web-prod:latest shantamcsbain/comserv-web-prod:$git_hash 2>/dev/null");
        $self->_log("Step 2b: Build finished (commit=$git_hash).");
        $self->{_git_hash} = $git_hash;

        if ($is_remote) {
            $self->_docker_login($is_remote, $ssh_prefix) or do {
                $self->_error("Aborting: registry login failed before push.");
                $self->_save_deploy_log($container_name, $target);
                return 0;
            };
            $self->_log("Step 3: Pushing $service to Docker Hub...");
            $self->_stream_command("cd $repo && docker compose $compose_files push $service 2>&1");
            $self->_log("Step 3b: Push finished.");
        }

        if ($mode eq 'build-push') {
            $self->_log("=== BUILD & PUSH COMPLETE (target=$target, image=$git_hash) ===");
            $self->_log("The running $container_name is untouched. Use 'Pull & Deploy' on the production server to deploy this image.");
            $self->_save_deploy_log($container_name, $target);
            return 1;
        }
    }

    # ── PULL & DEPLOY phase (steps 3-6) ──
    $self->_log("Step 4: Backing up old $container_name...");
    my $backup  = $self->_backup_container($container_name, $is_remote, $ssh_prefix);

    my $healthy = 0;
    my $deploy_ok = eval {
        $self->_prune_backups($container_name, 5, $is_remote, $ssh_prefix);

        if ($is_remote) {
            $self->_stream_command("$ssh_prefix \"docker ps -q --filter 'name=bk-$container_name' --filter 'publish=$port' 2>/dev/null | xargs -r docker stop 2>&1 || true\"");
        } else {
            system("docker ps -q --filter 'name=bk-$container_name' --filter 'publish=$port' 2>/dev/null | xargs -r docker stop 2>&1 || true");
        }

        if ($is_remote) {
            $self->_docker_login($is_remote, $ssh_prefix) or do {
                $self->_error("Aborting: registry login failed before pull on $target.");
                die "docker login failed";
            };
            $self->_log("Step 5: Pulling image on $target and starting $service...");
            my $remote_cmd = sprintf(
                'cd %s && ( docker compose %s pull %s 2>&1 ) && ( docker compose %s up -d --force-recreate %s 2>&1 )',
                $self->{_remote_compose_dir}, $compose_files, $service,
                $compose_files, $service
            );
            $self->_stream_command("$ssh_prefix \"$remote_cmd\"");
        } else {
            $self->_docker_login($is_remote, $ssh_prefix) or do {
                $self->_error("Aborting: registry login failed before local pull.");
                die "docker login failed";
            };
            $self->_log("Step 5: Starting $service on localhost...");
            $self->_stream_command("cd $repo && docker compose $compose_files up -d --force-recreate $service 2>&1");
        }

        # Rename compose-created container to expected name
        {
            my $compose_ps = $is_remote
                ? `$ssh_prefix "cd $self->{_remote_compose_dir} && docker compose $compose_files ps --format '{{.Names}}' 2>/dev/null | head -1"`
                : `cd $repo && docker compose $compose_files ps --format '{{.Names}}' 2>/dev/null | head -1`;
            chomp $compose_ps;
            if ($compose_ps && $compose_ps ne $container_name) {
                $self->_rename_container($compose_ps, $container_name, $is_remote, $ssh_prefix, 0);
            } elsif ($compose_ps) {
                $self->_log("  Container name already matches $container_name");
            } else {
                $self->_log("  WARNING: Could not determine compose container name – continuing with assumed name $container_name");
            }
        }

        # 6. Health-check loop (up to 90 seconds)
        $self->_log("Step 6: Waiting for $container_name to become healthy...");
        $healthy = 0;
        for my $i (1..45) {
            my $health;
            if ($is_remote) {
                $health = `$ssh_prefix "docker inspect --format='{{.State.Health.Status}}' $container_name 2>/dev/null || echo 'unknown'"`;
            } else {
                $health = `docker inspect --format='{{.State.Health.Status}}' $container_name 2>/dev/null || echo 'unknown'`;
            }
            chomp $health;
            $health =~ s/^\s+|\s+$//g;
            $self->_log("  [$i/45] health=$health");
            if ($health =~ /healthy/i) { $healthy = 1; last; }
            if ($is_remote) {
                my $http_ok = system("$ssh_prefix \"curl -sf --max-time 3 http://localhost:$port/ >/dev/null 2>&1\"") == 0;
                if ($http_ok) { $healthy = 1; last; }
            } else {
                my $http_ok = system("curl -sf --max-time 3 http://localhost:$port/ >/dev/null 2>&1") == 0;
                if ($http_ok) { $healthy = 1; last; }
            }
            if ($i % 10 == 0) {
                my $state;
                if ($is_remote) {
                    $state = `$ssh_prefix "docker inspect --format='{{.State.Status}}' $container_name 2>/dev/null || echo 'unknown'"`;
                } else {
                    $state = `docker inspect --format='{{.State.Status}}' $container_name 2>/dev/null || echo 'unknown'`;
                }
                chomp $state;
                $state =~ s/^\s+|\s+$//g;
                $self->_log("  State check: container status=$state");
                if ($state ne 'running' && $state ne 'starting' && $state ne 'unknown') {
                    $self->_log("  ✗ Container is not running (status=$state) — aborting health check.");
                    last;
                }
            }
            sleep 2;
        }
    };  # end eval
    if ($@) {
        $self->_log("CRITICAL: Runtime error during deploy phase: $@");
        my $stop_new = $is_remote
            ? "$ssh_prefix \"docker stop $container_name 2>&1 || true\""
            : "docker stop $container_name 2>&1 || true";
        $self->_stream_command($stop_new);
        if ($backup) {
            $self->_log("Emergency rollback: restoring $backup...");
            my $start_backup = $is_remote
                ? "$ssh_prefix \"docker start $backup 2>&1 || echo 'ROLLBACK_FAILED'\""
                : "docker start $backup 2>&1 || echo 'ROLLBACK_FAILED'";
            $self->_stream_command($start_backup);
        } else {
            $self->_log("No backup container to restore (fresh deploy).");
        }
        $self->_log("=== DEPLOY FAILED (target=$target) - emergency rollback ===");
        $self->_save_deploy_log($container_name, $target);
        return 0;
    }

    if ($healthy) {
        $self->_log("✅ New $container_name is healthy" . ($backup ? " – stopping backup $backup." : " (fresh deploy, no backup)."));
        if ($backup) {
            my $stop_cmd = $is_remote
                ? "$ssh_prefix \"docker stop $backup 2>&1 || true\""
                : "docker stop $backup 2>&1 || true";
            $self->_stream_command($stop_cmd);
        }
        $self->_log("=== DEPLOY COMPLETE (target=$target) ===");
        $self->_save_deploy_log($container_name, $target);
        return 1;
    } else {
        $self->_log("✗ New $container_name failed health check – rolling back.");
        my $backup_exists = $is_remote
            ? `$ssh_prefix "docker ps -a -q --filter 'name=^$backup\$' 2>/dev/null"`
            : `docker ps -a -q --filter 'name=^$backup\$' 2>/dev/null`;
        chomp $backup_exists;
        if ($backup_exists) {
            $self->_log("  Stopping failed new container $container_name...");
            my $stop_new = $is_remote
                ? "$ssh_prefix \"docker stop $container_name 2>&1 || true\""
                : "docker stop $container_name 2>&1 || true";
            $self->_stream_command($stop_new);

            my $rollback_cmd = $is_remote
                ? "$ssh_prefix \"docker start $backup 2>&1\""
                : "docker start $backup 2>&1";
            my $rc = $self->_stream_command($rollback_cmd);
            if ($rc == 0) {
                $self->_error("Deploy FAILED on $target – rolled back to $backup. Old container restarted.");
            } else {
                $self->_log("  docker start failed (exit=$rc) — trying to fix stale network references...");
                $self->_log("  Attempting: disconnect stale networks and retry start...");
                my $fmt = '{{range $n, $v := .NetworkSettings.Networks}}{{.NetworkID}} {{end}}';
                $fmt =~ s/\$/\\\$/g;
                my $list_nets = $is_remote
                    ? "$ssh_prefix \"docker inspect --format='$fmt' $backup 2>/dev/null\""
                    : "docker inspect --format='$fmt' $backup 2>/dev/null";
                my $net_ids = `$list_nets` || '';
                chomp $net_ids;
                my @stale_nets = grep { $_ ne '' } split(/\s+/, $net_ids);
                $self->_log("  Found " . scalar(@stale_nets) . " network(s) attached to $backup.");
                foreach my $nid (@stale_nets) {
                    my $found = $is_remote
                        ? `$ssh_prefix "docker network inspect $nid 2>/dev/null || echo 'NOT_FOUND'"`
                        : `docker network inspect $nid 2>/dev/null || echo 'NOT_FOUND'`;
                    chomp $found;
                    if ($found =~ /NOT_FOUND/) {
                        $self->_log("  Removing stale network $nid from $backup...");
                        my $dc = $is_remote
                            ? system("$ssh_prefix \"docker network disconnect -f $nid $backup 2>/dev/null\"")
                            : system("docker network disconnect -f $nid $backup 2>/dev/null");
                    }
                }
                my $retry = $is_remote
                    ? "$ssh_prefix \"docker start $backup 2>&1 || echo 'ROLLBACK_FAILED'\""
                    : "docker start $backup 2>&1 || echo 'ROLLBACK_FAILED'";
                $self->_stream_command($retry);
                $self->_error("Deploy FAILED on $target – attempted rollback with network recovery.");
            }
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
            system("docker volume create $v 2>/dev/null");
            $self->_log("Created volume: $v");
            push @created, $v;
        }
    }
    return @created;
}

sub ensure_all_required_volumes_remote {
    my ($self, $ssh_prefix) = @_;

    my @required = @CANONICAL_VOLUMES;
    my @created;
    foreach my $v (@required) {
        my $exists = `$ssh_prefix "docker volume inspect $v 2>/dev/null"`;
        if ($exists) {
            $self->_log("Volume OK: $v");
        } else {
            system("$ssh_prefix \"docker volume create $v 2>/dev/null\"");
            $self->_log("Created volume: $v");
            push @created, $v;
        }
    }
    return @created;
}

# ─────────────────────────────────────────────────────────────────────────────
# Backup pruning — keep at most $max_backups per container
# ─────────────────────────────────────────────────────────────────────────────
sub _prune_backups {
    my ($self, $container_name, $max_backups, $is_remote, $ssh_prefix) = @_;

    $max_backups ||= 5;
    my $list_cmd = $is_remote
        ? "$ssh_prefix \"docker ps -a --filter 'name=bk-$container_name-' --format '{{.Names}}' 2>/dev/null\""
        : "docker ps -a --filter 'name=bk-$container_name-' --format '{{.Names}}' 2>/dev/null";
    my @backups = `$list_cmd`;
    chomp @backups;
    @backups = grep { $_ } sort @backups;

    if (@backups > $max_backups) {
        my @to_remove = splice(@backups, 0, scalar(@backups) - $max_backups);
        $self->_log("  Pruning " . scalar(@to_remove) . " old backup(s) of $container_name (keeping $max_backups)...");
        foreach my $b (@to_remove) {
            my $rm_cmd = $is_remote
                ? "$ssh_prefix \"docker rm -f $b 2>&1 || true\""
                : "docker rm -f $b 2>&1 || true";
            system($rm_cmd);
            $self->_log("    Removed $b");
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Deploy log saving
# ─────────────────────────────────────────────────────────────────────────────
sub _save_deploy_log {
    my ($self, $container_name, $target) = @_;

    my $log_dir  = $ENV{HOME} . '/deploy_logs';
    mkdir $log_dir unless -d $log_dir;

    my $now  = DateTime->now(time_zone => 'local');
    my $date = $now->ymd('');
    my $time = $now->hms('');
    $time =~ s/://g;

    my $log_file = "$log_dir/${container_name}_${target}_${date}_${time}.log";
    open(my $fh, '>', $log_file) or warn "Can't write deploy log: $!";
    print $fh $self->{_log_buffer} || "No log buffer available.\n";
    close $fh;

    $self->_log("Deploy log saved: $log_file");
}

# ─────────────────────────────────────────────────────────────────────────────
# Stream command — captures output, writes to log buffer, returns exit code
# ─────────────────────────────────────────────────────────────────────────────
sub _stream_command {
    my ($self, $cmd) = @_;

    $self->_log("Running: $cmd");
    open(my $pipe, '-|', "$cmd 2>&1") or do {
        $self->_error("Failed to run command: $cmd");
        return -1;
    };

    while (my $line = <$pipe>) {
        chomp $line;
        $self->_log($line);
    }

    close $pipe;
    my $exit = $? >> 8;
    $self->_log("Exit code: $exit");
    return $exit;
}

# ─────────────────────────────────────────────────────────────────────────────
# Sync compose files to remote host
# ─────────────────────────────────────────────────────────────────────────────
sub _sync_compose_to_remote {
    my ($self, $repo, $scp_prefix, $ssh_host) = @_;

    my $remote_dir = '/opt/comserv/Comserv';
    # Ensure the remote directory exists
    my $ssh_user = $self->{ssh_user} || 'ubuntu';
    my $ssh_pass = $ENV{SSHPASS} || '';
    my $ssh_prefix_base = $ssh_pass
        ? "sshpass -e ssh -o StrictHostKeyChecking=no $ssh_user\@$ssh_host"
        : "ssh -o StrictHostKeyChecking=no $ssh_user\@$ssh_host";

    system("$ssh_prefix_base \"mkdir -p $remote_dir 2>/dev/null\"") if $ssh_prefix_base;

    # Copy compose files that the remote host needs
    foreach my $cf ('docker-compose.yml', 'docker-compose.prod.yml') {
        my $src = "$repo/$cf";
        if (-f $src) {
            system("$scp_prefix $src $ssh_user\@$ssh_host:$remote_dir/ 2>/dev/null");
        }
    }

    $self->{_remote_compose_dir} = $remote_dir;
    return '-f docker-compose.yml -f docker-compose.prod.yml';
}

# ─────────────────────────────────────────────────────────────────────────────
# Public API methods called from controller
# ─────────────────────────────────────────────────────────────────────────────
sub deploy_to_production {
    my ($self, $c, $args) = @_;
    $self->{target}  = $args->{target}  || 'production1';
    $self->{repo}    = $args->{repo}    || '/home/shanta/PycharmProjects/comserv2/Comserv';
    $self->{no_cache}= $args->{no_cache}// 0;
    $self->{mode}    = 'full';

    $self->_log("=== DEPLOY TO PRODUCTION (target=$self->{target}) ===");
    my $rc = $self->deploy;

    # Return JSON-compatible result
    my $success = $rc ? 1 : 0;
    return { success => $success, message => $rc ? 'Deploy completed successfully' : 'Deploy failed' };
}

sub get_deploy_status {
    my ($self, $c) = @_;

    my $status_file = $ENV{HOME} . '/deploy_status.json';
    if (-f $status_file) {
        open(my $fh, '<', $status_file) or return { success => 0, error => "Cannot read status file" };
        my $json = do { local $/; <$fh> };
        close $fh;
        my $data = decode_json($json);
        return {
            success => 1,
            is_running => $data->{is_running} || 0,
            output => $data->{output} || '',
        };
    }

    return { success => 0, error => 'No deploy status file found' };
}

sub get_deploy_logs {
    my ($self, $c, $container_name, $file) = @_;

    my $log_dir = $ENV{HOME} . '/deploy_logs';
    unless (-d $log_dir) {
        return { success => 0, error => 'No deploy logs directory found' };
    }

    if ($file) {
        my $path = "$log_dir/$file";
        unless (-f $path) {
            return { success => 0, error => "Log file not found: $file" };
        }
        open(my $fh, '<', $path) or return { success => 0, error => "Cannot read $file: $!" };
        my $output = do { local $/; <$fh> };
        close $fh;
        return { success => 1, output => $output };
    }

    # List log files for this container
    opendir(my $dh, $log_dir) or return { success => 0, error => "Cannot list logs: $!" };
    my @files = grep { /^$container_name/ && -f "$log_dir/$_" } readdir($dh);
    closedir $dh;

    @files = sort { (stat("$log_dir/$b"))[9] <=> (stat("$log_dir/$a"))[9] } @files;

    my @logs = map { { file => $_, date => (stat("$log_dir/$_"))[9] } } @files;
    return { success => 1, logs => \@logs };
}

sub rebuild {
    my ($self, $c, $args) = @_;

    my $host      = $args->{host}      || 'workstation';
    my $container = $args->{container} || '';
    my $mode      = $args->{mode}      || 'pull-deploy';
    my $no_cache  = $args->{no_cache}  || 0;

    unless ($container) {
        return { success => 0, error => 'container name is required' };
    }

    $self->{target}   = $host;
    $self->{mode}     = $mode;
    $self->{no_cache} = $no_cache;

    # Fork the deploy process to run in background
    my $pid = fork;
    if (!defined $pid) {
        return { success => 0, error => 'fork failed' };
    }

    if ($pid == 0) {
        # Child process
        close STDOUT;
        close STDERR;

        # Open log file for this deploy
        my $log_dir = $ENV{HOME} . '/deploy_logs';
        mkdir $log_dir unless -d $log_dir;
        my $now = DateTime->now(time_zone => 'local');
        my $ts = $now->ymd('') . '_' . $now->hms('');
        $ts =~ s/://g;
        my $log_file = "$log_dir/${container}_${host}_${ts}.log";

        open(my $lfh, '>', $log_file) or exit 1;
        $self->{log_fh} = $lfh;

        $self->_log("=== REBUILD: $container on $host (mode=$mode) ===");
        my $rc = $self->deploy;
        $self->_log("=== REBUILD " . ($rc ? "SUCCESS" : "FAILED") . " ===");
        close $lfh;

        # Write status file for polling
        my $status_file = $ENV{HOME} . '/deploy_status.json';
        open(my $sfh, '>', $status_file) or exit 1;
        print $sfh encode_json({
            is_running => 0,
            output => "Deploy " . ($rc ? "completed" : "failed") . ".\n",
            exit_code => $rc ? 0 : 1,
        });
        close $sfh;

        exit($rc ? 0 : 1);
    }

    # Parent process
    $self->{fork_pid} = $pid;
    return { success => 1, message => "Deploy process started (PID: $pid)" };
}

sub restore_backup {
    my ($self, $c, $args) = @_;

    my $host        = $args->{host}        || 'workstation';
    my $backup_name = $args->{backup_name} || '';

    my $is_remote = $host ne 'workstation' && $host ne 'localhost';
    my $ssh_prefix = '';

    if ($is_remote) {
        my $ssh_host    = $host eq 'production1' ? '192.168.1.126' : '192.168.1.127';
        my $ssh_pass    = $ENV{SSHPASS} || '';
        my $ssh_user    = $self->{ssh_user} || 'ubuntu';
        $ssh_prefix     = $ssh_pass
            ? "sshpass -e ssh -o StrictHostKeyChecking=no $ssh_user\@$ssh_host"
            : "ssh -o StrictHostKeyChecking=no $ssh_user\@$ssh_host";
    }

    # Derive the active container name from the backup name
    my ($active_name) = $backup_name =~ /^bk-(.+)_\d{8}_\d{9}$/;
    $active_name ||= 'comserv-web-prod';

    $self->_log("Restoring backup $backup_name as $active_name on $host...");

    # Stop the current active container (if any)
    my $stop_cmd = $is_remote
        ? "$ssh_prefix \"docker stop $active_name 2>&1 || true\""
        : "docker stop $active_name 2>&1 || true";
    system($stop_cmd);

    # Remove/rename the current active
    my $rm_cmd = $is_remote
        ? "$ssh_prefix \"docker rm $active_name 2>&1 || true\""
        : "docker rm $active_name 2>&1 || true";
    system($rm_cmd);

    # Rename backup to active
    my $rename_cmd = $is_remote
        ? "$ssh_prefix \"docker rename $backup_name $active_name 2>&1\""
        : "docker rename $backup_name $active_name 2>&1";
    my $rc = system($rename_cmd);

    if ($rc != 0) {
        $self->_error("Failed to rename backup $backup_name to $active_name");
        return { success => 0, error => "Rename failed", output => "Check deploy logs for details." };
    }

    # Start the restored container
    my $start_cmd = $is_remote
        ? "$ssh_prefix \"docker start $active_name 2>&1\""
        : "docker start $active_name 2>&1";
    $rc = system($start_cmd);

    if ($rc != 0) {
        $self->_error("Failed to start restored container $active_name");
        return { success => 0, error => "Start failed", output => "Check deploy logs for details." };
    }

    $self->_log("Successfully restored $backup_name as $active_name on $host.");
    return { success => 1, message => "Restored $backup_name as $active_name" };
}

1;