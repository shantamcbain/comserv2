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
        # Resolve SSH user from credentials file, falling back to ubuntu
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
        # SCP prefix for transferring compose files
        my $scp_prefix  = $ssh_pass
            ? "sshpass -e scp -o StrictHostKeyChecking=no"
            : "scp -o StrictHostKeyChecking=no";
        # Sync compose files to remote BEFORE using them
        $compose_files  = $self->_sync_compose_to_remote($repo, $scp_prefix, $ssh_host);
    }

    # ── PUSH ONLY mode ──
    # Just push the existing image without rebuilding
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
    # 1. Create all required volumes — local for dev, remote for production
    #    Always runs so that pull-deploy mode works on hosts with no volumes yet.
    $self->_log("Step 1: Ensuring all required volumes exist...");
    if ($is_remote) {
        $self->ensure_all_required_volumes_remote($ssh_prefix);
    } else {
        $self->ensure_all_required_volumes($repo);
    }

    # ── BUILD & PUSH phase (steps 2-3) ──
    # Runs in full and build-push modes. Skipped in pull-deploy mode.
    if ($mode ne 'pull-deploy') {
        # 2. Build (local) then push if remote
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
        # Tag with git hash for traceability
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

        # In build-push mode, stop here — don't touch the running container
        if ($mode eq 'build-push') {
            $self->_log("=== BUILD & PUSH COMPLETE (target=$target, image=$git_hash) ===");
            $self->_log("The running $container_name is untouched. Use 'Pull & Deploy' on the production server to deploy this image.");
            $self->_save_deploy_log($container_name, $target);
            return 1;
        }
    }

    # ── PULL & DEPLOY phase (steps 3-6) ──
    # Runs in full and pull-deploy modes.
    # In pull-deploy mode we do NOT build locally — we rely on the image already
    # being on Docker Hub (pushed by a prior build-push run).

    # 3. Backup old container (handles "no container" gracefully)
    $self->_log("Step 4: Backing up old $container_name...");
    my $backup  = $self->_backup_container($container_name, $is_remote, $ssh_prefix);

    # ── eval wrap: exception safety from here through health check ──
    # The old container was renamed to $backup above (or $backup is undef if no
    # container existed). If anything dies during the deploy phase, the
    # EVAL_ERROR handler below rolls back (honoring undef $backup gracefully).
    my $healthy = 0;
    my $deploy_ok = eval {
        # 4. Rotate backups — keep up to 5 per container (global cap).
    #     Per-container expectations: 4000/staging at least 1, web-dev at least 2, web-prod at least 1.
    #     Since 5 >= all these, they're automatically satisfied by the global cap.
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

    # 5.5 Rename compose-created container to expected name
    # Docker Compose names containers as <project>_<service>_<index> (e.g.
    # comserv-deploy_web-prod_1), but our health-check, rollback, and
    # diagnostics code expects the canonical name ($container_name).
    {
        my $compose_ps = $is_remote
            ? `$ssh_prefix \"cd $self->{_remote_compose_dir} && docker compose $compose_files ps --format '{{.Names}}' 2>/dev/null | head -1\"`
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
        # Fallback: try direct HTTP to the port (covers missing Docker HEALTHCHECK)
        if ($is_remote) {
            my $http_ok = system("$ssh_prefix \"curl -sf --max-time 3 http://localhost:$port/ >/dev/null 2>&1\"") == 0;
            if ($http_ok) { $healthy = 1; last; }
        } else {
            my $http_ok = system("curl -sf --max-time 3 http://localhost:$port/ >/dev/null 2>&1") == 0;
            if ($http_ok) { $healthy = 1; last; }
        }
        # Check if container is actually running (not exited)
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
        # Stop the new container (always safe)
        my $stop_new = $is_remote
            ? "$ssh_prefix \"docker stop $container_name 2>&1 || true\""
            : "docker stop $container_name 2>&1 || true";
        $self->_stream_command($stop_new);
        # Restore backup only if we had one
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
        # Check if backup exists before trying to start it
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
                # Rollback docker start failed — likely a stale Docker network issue.
                # The backup container was originally created with a different Compose
                # project network that may have been rotated. Disconnect stale networks
                # and retry.
                $self->_log("  docker start failed (exit=$rc) — trying to fix stale network references...");
                $self->_log("  Attempting: disconnect stale networks and retry start...");
                # Build the docker inspect format string for listing network IDs
                # (single-quoted so Perl doesn't interpret Go template vars $n $v)
                my $fmt = '{{range $n, $v := .NetworkSettings.Networks}}{{.NetworkID}} {{end}}';
                $fmt =~ s/\$/\\\$/g;  # escape $ for shell (interpolated in double-quoted ssh command)
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

    # Use a FIXED remote directory so Docker Compose reuses the same
    # auto-created network (named <dirname>_default) across deploys.
    # A timestamped directory creates a NEW project network each deploy,
    # which breaks rollback — the backup container references the old network.
    my $remote_dir = "/tmp/comserv-deploy";

    # List of compose files to transfer (base + prod only — no NFS on remote)
    my @files = ('docker-compose.yml', 'docker-compose.prod.yml');

    # 1. Create remote temp dir
    $self->_log("Syncing compose files to $ssh_host:$remote_dir ...");
    my $mkdir_cmd = $ENV{SSHPASS}
        ? "sshpass -e ssh -o StrictHostKeyChecking=no $self->{ssh_user}\@$ssh_host \"mkdir -p $remote_dir\""
        : "ssh -o StrictHostKeyChecking=no $self->{ssh_user}\@$ssh_host \"mkdir -p $remote_dir\"";
    my $rc = system($mkdir_cmd);
    if ($rc != 0) {
        $self->_error("Failed to create remote dir $remote_dir on $ssh_host (exit=$rc)");
        # Fallback: try using absolute workstation paths (will fail on remote,
        # but better than silent failure)
        return $self->_compose_args($repo);
    }

    # 2. SCP each compose file — strip STATIC_SRC/LEGACY_STATIC_SRC bind mounts
    #    from docker-compose.prod.yml for remote deploys. The image already has
    #    static files at /opt/comserv/root/static; bind mounts override (and hide)
    #    them on remote hosts where STATIC_SRC is unset, falling back to
    #    /root/static (empty/missing on the remote host).
    foreach my $f (@files) {
        my $local  = "$repo/$f";
        my $remote = "$self->{ssh_user}\@$ssh_host:$remote_dir/";

        if ($f eq 'docker-compose.prod.yml') {
            # Read, filter STATIC_SRC/LEGACY_STATIC_SRC bind mount lines, write temp
            open my $fh_in, '<', $local or do {
                $self->_error("Cannot read $local: $!");
                next;
            };
            my $content = do { local $/; <$fh_in> };
            close $fh_in;
            my $orig_len = length $content;
            $content =~ s/^[ ]*-\s*\$\{STATIC_SRC[^}]*\}.*\n//gm;
            $content =~ s/^[ ]*-\s*\$\{LEGACY_STATIC_SRC[^}]*\}.*\n//gm;
            if (length $content != $orig_len) {
                my $tmp = "/tmp/comserv_deploy_$f";
                open my $fh_out, '>', $tmp or do {
                    $self->_error("Cannot write $tmp: $!");
                    next;
                };
                print $fh_out $content;
                close $fh_out;
                $self->_log("  Stripped STATIC_SRC/LEGACY_STATIC_SRC bind mounts from $f for remote deploy");
                $local = $tmp;
            }
        }

        $self->_log("  Transferring $f ...");
        my $dest = "$self->{ssh_user}\@$ssh_host:$remote_dir/$f";
        my $scp_cmd = "$scp_prefix $local $dest";
        $rc = system($scp_cmd);
        if ($rc != 0) {
            $self->_error("Failed to SCP $f to $ssh_host (exit=$rc)");
        }

        # Clean up temp file if we created one
        if ($local ne "$repo/$f") {
            unlink $local;
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
        return ($? >> 8);
    }
    return -1;
}

1;