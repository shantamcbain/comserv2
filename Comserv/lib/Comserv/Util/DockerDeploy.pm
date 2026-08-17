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
        # IMGDEP (2026-08-04): image repository ref. Defaults to a LAN-local
        # registry host (NOT the database server — separation of concerns).
        # The Docker Hub ref (shantamcsbain/comserv-web-prod) is retired. The
        # caller MUST pass the real LAN registry host; this default is a
        # placeholder that must be overridden in production config.
        image_repo    => $args{image_repo}    || 'comserv-registry.lan:5000/comserv-web-prod',
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
    comserv2_sessions comserv2_nfs_data comserv2_whisper_venv
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

# Create a timestamped backup of a running container by COMMITTING IT TO AN IMAGE.
# Returns the backup image ref (bk-<name>:<ts>), or undef if no container exists.
#
# WHY an image, not `docker rename`: a renamed container keeps its Compose labels
# (com.docker.compose.service/project/container-number). The next
# `docker compose up --force-recreate` matches by LABELS, finds the renamed
# backup, and RECREATES (destroys) it — so every rename-based backup was lost.
# A committed image has no Compose labels, so compose cannot touch it.
sub _backup_container {
    my ($self, $container_name, $is_remote, $ssh_prefix) = @_;

    $self->_log("Backing up $container_name...");
    my $found = $self->_container_exists($container_name, $is_remote, $ssh_prefix);
    $self->_log("  Container check: " . ($found ? "found" : "not found"));

    unless ($found) {
        $self->_log("  No existing container named $container_name — skipping backup, will create fresh.");
        return undef;
    }

    # Capture the image the running container uses so rollback can retag→compose up.
    my $img_ref_cmd = $is_remote
        ? "$ssh_prefix \"docker inspect --format='{{.Config.Image}}' $container_name 2>/dev/null\""
        : "docker inspect --format='{{.Config.Image}}' $container_name 2>/dev/null";
    my $img_ref = `$img_ref_cmd` || '';
    chomp $img_ref;
    $self->{_backup_image_ref} = $img_ref;

    my $now    = DateTime->now(time_zone => 'local');
    my $ts     = $now->ymd('') . '_' . $now->hms('');
    my $backup = "bk-$container_name:$ts";

    my $commit_cmd = $is_remote
        ? "$ssh_prefix \"docker commit $container_name $backup 2>&1\""
        : "docker commit $container_name $backup 2>&1";
    my $rc = $self->_stream_command($commit_cmd);
    if ($rc != 0) {
        $self->_error("  Failed to commit backup image $backup (exit=$rc)");
        return undef;
    }
    $self->_log("  Backed up $container_name → image $backup (source image_ref=$img_ref)");

    # Also create a VISIBLE stopped backup container from the committed image,
    # so backups can be seen at a glance in `docker ps -a` / the admin browser,
    # restarted by name, and deleted individually (user requirement).
    #
    # CRITICAL: labels are wiped (com.docker.compose.* overridden to a distinct
    # project) so `docker compose up --force-recreate` can NEVER match and
    # destroy it — that label-match destruction is why plain `docker rename`
    # backups kept disappearing.
    my $bk_cname = "bk-$container_name-$ts";
    my $create_cmd_body =
        "docker create --name $bk_cname"
      . " -p $self->{_svc_port}:$self->{_svc_port}"
      . " --label com.docker.compose.project=backup"
      . " --label com.docker.compose.service=backup"
      . " --label comserv.backup=1"
      . " --label comserv.backup.of=$container_name"
      . " --label comserv.backup.ts=$ts"
      . " $backup 2>&1";
    my $create_cmd = $is_remote
        ? "$ssh_prefix \"$create_cmd_body\""
        : $create_cmd_body;
    my $crc = $self->_stream_command($create_cmd);
    if ($crc == 0) {
        $self->{_backup_cname} = $bk_cname;
        $self->_log("  Created stopped backup container: $bk_cname (port $self->{_svc_port} mapped — can be started directly)");
    } else {
        $self->_error("  WARNING: backup image OK but could not create visible backup container $bk_cname (exit=$crc)");
    }
    return $backup;
}

# Restore a committed backup image: retag it to the image Compose expects, then
# recreate the service from it via compose (no pull). Returns 1 on success.
sub _restore_backup_image {
    my ($self, $backup_image, $service, $compose_files, $repo, $is_remote, $ssh_prefix) = @_;

    # ── Preferred path: visible-container rollback (user requirement) ──
    # 1. Stop the FAILED new container and rename it failed-<name>-<ts> so it
    #    stays visible in `docker ps -a` as evidence of what failed.
    # 2. START the stopped bk- backup container (it has the port mapping).
    # Result at a glance: failed-* = stopped broken deploy, bk-* Up = the
    # exact backup now serving traffic.
    my $bk_cname = $self->{_backup_cname} || '';
    if ($bk_cname) {
        my $svc_container = $self->{_svc_container} || '';
        my $now = DateTime->now(time_zone => 'local');
        my $fts = $now->ymd('') . '_' . $now->hms('');
        if ($svc_container) {
            my $failed_name = "failed-$svc_container-$fts";
            my $stop_rename = "docker stop $svc_container 2>&1 || true; docker rename $svc_container $failed_name 2>&1 || true";
            $self->_stream_command($is_remote ? "$ssh_prefix \"$stop_rename\"" : $stop_rename);
            $self->_log("  Failed container preserved as $failed_name (stopped).");
        }
        my $start_bk = "docker start $bk_cname 2>&1";
        my $rc = $self->_stream_command($is_remote ? "$ssh_prefix \"$start_bk\"" : $start_bk);
        if ($rc == 0) {
            $self->_log("  ✅ ROLLBACK: backup container $bk_cname is now RUNNING (visible by name in docker ps).");
            return 1;
        }
        $self->_error("  Could not start backup container $bk_cname (exit=$rc) — falling back to image-based restore.");
    }

    # ── Fallback path: retag backup image and compose-recreate ──
    my $img_ref = $self->{_backup_image_ref} || '';
    unless ($backup_image && $img_ref) {
        $self->_error("  Cannot restore: missing backup image or source image_ref.");
        return 0;
    }
    $self->_log("Restoring backup image $backup_image → $img_ref ...");
    my $tag_cmd = $is_remote
        ? "$ssh_prefix \"docker tag $backup_image $img_ref 2>&1\""
        : "docker tag $backup_image $img_ref 2>&1";
    $self->_stream_command($tag_cmd);
    my $up = $is_remote
        ? "$ssh_prefix \"cd $self->{_remote_compose_dir} && docker compose $compose_files up -d --force-recreate $service 2>&1\""
        : "cd $repo && docker compose $compose_files up -d --force-recreate $service 2>&1";
    my $rc = $self->_stream_command($up);
    return $rc == 0 ? 1 : 0;
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

    # ─────────────────────────────────────────────────────────────────────────
    # SINGLE DEPLOY ENGINE: delegate to script/deploy.sh (canonical_deploy).
    # This guarantees EVERY caller (dashboard buttons, Planning.pm staging
    # worker, cron) runs the IDENTICAL pipeline: pre-SSH self-sync of changed
    # scripts -> build -> push -> pull exact digest -> compose up --no-build
    # --force-recreate (old container renamed first, so NO name conflict) ->
    # health gate with rollback -> real success/failure. No divergent Perl
    # build/pull/recreate logic remains. Debuggable: deploy.sh writes a
    # structured log and returns a non-zero exit on any failure.
    # ─────────────────────────────────────────────────────────────────────────
    my $log_fh = $self->{log_fh};
    my $log_line = sub { my ($msg) = @_; $self->_log($msg); };

    # Map this object target -> deploy.sh target/host.
    my $node = $target;
    if ($target eq 'production1')        { $node = '192.168.1.126'; }
    elsif ($target eq 'production2')      { $node = '192.168.1.127'; }
    elsif ($target eq 'staging-4000' || $target eq 'local-staging') { $node = 'local'; }
    elsif ($target eq 'workstation')      { $node = 'local'; }
    elsif ($target eq 'local-test' || $target eq 'web-dev')         { $node = 'local'; }
    else                                 { $node = '192.168.1.126'; }

    $log_line->("=== DEPLOY STARTED (target=$target -> node=$node, trigger=$self->{trigger}) ===");
    $log_line->("Delegating to single engine: script/deploy.sh --deploy-to-node $node");

    my $cmd = "cd '$repo' && TRIGGER_SOURCE='$self->{trigger}' script/deploy.sh --deploy-to-node $node 2>&1";
    my $out = `$cmd`;
    my $rc  = $? >> 8;
    if ($log_fh) { print $log_fh $out; $log_fh->flush(); }
    $self->_log($out) if !$log_fh;

    if ($rc == 0) {
        $self->_log("=== DEPLOY COMPLETE (target=$target) ===");
        $self->_save_deploy_log('comserv2-web-prod', $target);
        return 1;
    } else {
        $self->_error("DEPLOY FAILED (target=$target, rc=$rc). Container unchanged / rolled back. Check deploy.sh log.");
        $self->_save_deploy_log('comserv2-web-prod', $target);
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
# Backup pruning — keeps at most N backup IMAGES for a given base name.
# Backups are now committed images tagged bk-<base_name>:<timestamp>.
# ─────────────────────────────────────────────────────────────────────────────
sub _prune_backups {
    my ($self, $base_name, $max_keep, $is_remote, $ssh_prefix) = @_;
    $max_keep ||= 5;

    # List backup image tags (bk-<base>:<ts>) sorted oldest→newest by tag.
    my $repo_tag = "bk-$base_name";
    my $list_cmd = $is_remote
        ? "$ssh_prefix \"docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep '^$repo_tag:' | sort\""
        : "docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep '^$repo_tag:' | sort";
    my $output = `$list_cmd` || '';
    my @backups = grep { /\S/ } split /\n/, $output;
    return if @backups <= $max_keep;

    my @to_remove = splice @backups, 0, (@backups - $max_keep);
    foreach my $old (@to_remove) {
        chomp $old;
        $self->_log("Pruning old backup image: $old");
        # Remove the matching visible backup container first (bk-<name>-<ts>),
        # then the image. Container name = image repo:tag with ':' → '-'.
        my $cname = $old;
        $cname =~ s/:/-/;
        my $rm_ctr_cmd = $is_remote
            ? "$ssh_prefix \"docker rm -f $cname 2>&1 || true\""
            : "docker rm -f $cname 2>&1 || true";
        $self->_stream_command($rm_ctr_cmd);
        my $rm_cmd = $is_remote
            ? "$ssh_prefix \"docker rmi $old 2>&1 || true\""
            : "docker rmi $old 2>&1 || true";
        $self->_stream_command($rm_cmd);
    }
    $self->_log("Pruned " . scalar(@to_remove) . " old backup(s) (container+image), keeping $max_keep.");

    # Also prune old failed-* containers (preserved failed deploys) — keep 2.
    my $failed_list_cmd = $is_remote
        ? "$ssh_prefix \"docker ps -a --format '{{.Names}}' 2>/dev/null | grep '^failed-$base_name-' | sort\""
        : "docker ps -a --format '{{.Names}}' 2>/dev/null | grep '^failed-$base_name-' | sort";
    my $failed_out = `$failed_list_cmd` || '';
    my @failed = grep { /\S/ } split /\n/, $failed_out;
    if (@failed > 2) {
        my @rm_failed = splice @failed, 0, (@failed - 2);
        foreach my $fc (@rm_failed) {
            chomp $fc;
            $self->_log("Pruning old failed-deploy container: $fc");
            my $cmd = $is_remote
                ? "$ssh_prefix \"docker rm -f $fc 2>&1 || true\""
                : "docker rm -f $fc 2>&1 || true";
            $self->_stream_command($cmd);
        }
    }
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
    # Get freshest backup image (bk-<name>:<ts>) for the log metadata header
    my $backup_name = `docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep '^bk-$container_name:' | sort | tail -1` || '';
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
    # auto-created network (named <dirname>_default) across deploys. A
    # timestamped directory creates a NEW project network each deploy.
    # (Backups are committed IMAGES now, so they carry no compose network
    #  labels and rollback retags→compose-recreates; the fixed dir mainly
    #  keeps the live service network stable across deploys.)
    my $remote_dir = "/tmp/comserv-deploy";

    # List of compose files to transfer. Only include files that actually exist
    # at the repo root — a phantom overlay (e.g. docker-compose.prod.yml, which
    # lives under Comserv/ not root) makes `docker compose -f ... -f missing.yml`
    # run against an absent overlay. The root docker-compose.yml fully defines
    # the web-prod service, so it is sufficient on its own.
    my @candidate_files = ('docker-compose.yml', 'docker-compose.prod.yml');
    my @files = grep { -f "$repo/$_" } @candidate_files;
    unless (@files) {
        $self->_error("No compose files found at $repo — cannot sync to remote");
        return $self->_compose_args($repo);
    }
    $self->_log("Compose files to sync: " . join(', ', @files));

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

    # 2b. Sync credential secrets tree to the remote compose project dir.
    #     ROOT CAUSE FIX: the compose file mounts the secrets dir into the
    #     container (RemoteDB reads ~/.comserv/secrets/dbi/*.json — the K8s-Secret
    #     pattern). Previously only compose files were synced, so on the remote
    #     host the mounted path was empty → RemoteDB found zero connections →
    #     select_connection('ency') died → the app attached to NO database.
    #     We copy the whole secrets tree into $remote_dir/secrets and point the
    #     compose mount at it via COMSERV_SECRETS_DIR in the generated .env below.
    my $local_secrets = ($ENV{HOME} || '/home/shanta') . '/.comserv/secrets';
    my $remote_secrets = "$remote_dir/secrets";
    if (-d $local_secrets) {
        $self->_log("  Syncing credential secrets ($local_secrets) to remote ...");
        my $scp_secrets = "$scp_prefix -r $local_secrets/. $self->{ssh_user}\@$ssh_host:$remote_secrets/";
        # Ensure the remote secrets dir exists first
        my $mk = $ENV{SSHPASS}
            ? "sshpass -e ssh -o StrictHostKeyChecking=no $self->{ssh_user}\@$ssh_host \"mkdir -p $remote_secrets\""
            : "ssh -o StrictHostKeyChecking=no $self->{ssh_user}\@$ssh_host \"mkdir -p $remote_secrets\"";
        system($mk);
        my $src = system($scp_secrets);
        if ($src != 0) {
            $self->_error("Failed to sync secrets to $ssh_host (exit=$src) — app will not find DB credentials");
        } else {
            $self->_log("  Secrets synced to $ssh_host:$remote_secrets");
        }
    } else {
        $self->_error("Local secrets dir $local_secrets not found — cannot propagate DB credentials to remote");
    }

    # 2c. Generate the compose .env on the remote (docker compose auto-loads
    #     ./.env from the project dir). This is the single place that guarantees
    #     the correct env is present for a remote deploy, generating it fresh
    #     each time from the known workstation source rather than relying on a
    #     stale .env.production being hand-copied to the server.
    #       COMSERV_SECRETS_DIR   → points the compose secrets mount at 2b's copy
    #       ACTIVE_DB_ENVIRONMENT → selects the 'production' connection set
    #                               (ency → production_server.json, 192.168.1.198,
    #                                priority 1; NOT the 192.168.1.20 migration box)
    my $active_env = $ENV{ACTIVE_DB_ENVIRONMENT} || 'production';
    # SYSTEM_IDENTIFIER: derive from the deploy TARGET, not from the compose
    # file's default (which is 'workstation-prod-local' and was branding every
    # remote host as the workstation — the root of months of log/email
    # confusion). docker compose auto-loads ./.env, and ${SYSTEM_IDENTIFIER:-...}
    # in the compose file means this value always wins over the default.
    my $sys_id = $ENV{SYSTEM_IDENTIFIER} || $self->{target} || 'production1';
    my $env_body = "# Generated by DockerDeploy for remote deploy — do not edit\n"
                 . "COMSERV_SECRETS_DIR=$remote_secrets\n"
                 . "ACTIVE_DB_ENVIRONMENT=$active_env\n"
                 . "SYSTEM_IDENTIFIER=$sys_id\n";
    my $local_env_tmp = "/tmp/comserv_deploy_remote.env";
    if (open my $efh, '>', $local_env_tmp) {
        print $efh $env_body;
        close $efh;
        my $env_scp = "$scp_prefix $local_env_tmp $self->{ssh_user}\@$ssh_host:$remote_dir/.env";
        my $erc = system($env_scp);
        unlink $local_env_tmp;
        if ($erc != 0) {
            $self->_error("Failed to write remote .env (exit=$erc)");
        } else {
            $self->_log("  Generated remote .env (COMSERV_SECRETS_DIR=$remote_secrets, ACTIVE_DB_ENVIRONMENT=$active_env)");
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