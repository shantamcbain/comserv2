package Comserv::Controller::Admin::Docker;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;
use Comserv::Util::DockerDeploy;
use JSON qw(encode_json decode_json);
use DateTime;

BEGIN { extends 'Comserv::Controller::Base'; }

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

sub begin :Private {
    my ($self, $c) = @_;

    my $roles = $c->session->{roles} || [];
    unless (grep { $_ eq 'admin' || $_ eq 'developer' } @$roles) {
        $c->res->redirect($c->uri_for('/'));
        $c->detach;
    }

    my $action = $c->action ? $c->action->name : '';
    return if $action eq 'deploy' || $action eq 'deploy_form' || $action eq 'init_log' || $action eq 'close_deploy_log';

    my $env = $ENV{CATALYST_ENV} || 'development';
    my $server_role = $self->_get_current_server_role($c);

    # Strict triple-check for full Docker widget access:
    # 1. Server must NOT be production1 (widget only on safe servers like workstation)
    # 2. Username must be 'Shanta'
    # 3. Must be CSC admin
    if ($action =~ /^(list|restart|stop|start|up|down|logs|deploy_form|docker)$/ || $action =~ /containers_(working|old|legacy)$/) {
        unless ($self->_can_access_docker_widget($c)) {
            $c->stash->{error_msg} = "Docker container management widget is restricted. " .
                "Available only to admins/developers on non-production1 servers.";
            $c->res->redirect($c->uri_for('/admin/planning/DailyPlan'));
            $c->detach;
        }
    }

    unless ($env eq 'development' || $server_role eq 'workstation') {
        # Still allow limited actions from DailyPlan even on prod, but widget is blocked above
    }
}

sub _get_current_server_role {
    my ($self, $c) = @_;

    my $hostname = `hostname 2>/dev/null` || $ENV{HOSTNAME} || '';
    chomp $hostname;

    my $ip = '';
    if (open my $fh, '-|', 'hostname -I 2>/dev/null') {
        $ip = <$fh> || '';
        chomp $ip;
        $ip =~ s/\s.*//;
        close $fh;
    }

    return 'production1' if $hostname =~ /production1|prod1/i || $ip =~ /192\.168\.1\.126/i || $ENV{PRODUCTION1};
    return 'production2' if $hostname =~ /production2|prod2/i || $ip =~ /192\.168\.1\.127/i;
    return 'workstation' if $hostname =~ /workstation|dev/i || $ip =~ /192\.168\.1\.199/i;
    return 'unknown';
}

sub _can_access_docker_widget {
    my ($self, $c) = @_;

    my $server_role = $self->_get_current_server_role($c);
    my $username    = $c->session->{username} || '';
    my $roles       = $c->session->{roles} || [];

    # Safe servers: workstation, production2, and any non-production1 environment
    # Also treat 'unknown' as safe (common on development laptops)
    my $on_safe_server = $server_role ne 'production1';

    # Allow any admin or developer on a safe server
    my $is_admin_or_dev = $c->stash->{is_admin} ||
                          (grep { lc($_) =~ /admin|developer/ } @$roles) ||
                          ($username eq 'Shanta');   # legacy hard-coded user

    return $on_safe_server && $is_admin_or_dev;
}

sub _csc_admin_check {
    my ($self, $c) = @_;
    
    # Allow any verified admin or developer, bypassing SiteName checks on workstation/localhost.
    my $is_admin = $c->stash->{is_admin} || $c->session->{is_admin};
    
    if (!$is_admin && $c->session->{username} && $c->session->{username} eq 'Shanta') {
        $is_admin = 1;
    }
    
    if (!$is_admin && $c->session->{roles}) {
        my $roles = $c->session->{roles} || [];
        if (ref($roles) eq 'ARRAY') {
            $is_admin = 1 if grep { lc($_) eq 'admin' || lc($_) eq 'developer' } @$roles;
        } elsif (!ref($roles)) {
            $is_admin = 1 if $roles =~ /\b(admin|developer)\b/i;
        }
    }
    
    return $is_admin;
}

sub deploy_form :Path('/admin/docker/deploy_form') :Args(0) {
    my ($self, $c) = @_;
    unless ($self->_can_access_docker_widget($c)) {
        $c->response->status(403);
        $c->response->body('<html><body><p>CSC admin only</p></body></html>');
        return;
    }
    $c->stash->{template}   = 'admin/docker/deploy_form.tt';
    $c->stash->{no_wrapper} = 1;
}

sub deploy :Path('/admin/docker/deploy') :Args(0) {
    my ($self, $c) = @_;

    $c->response->content_type('application/json; charset=utf-8');

    unless ($self->_can_access_docker_widget($c)) {
        $c->response->status(403);
        $c->response->body(encode_json({ success => 0, message => 'CSC admin only' }));
        return;
    }

    unless ($c->req->method eq 'POST') {
        $c->response->status(405);
        $c->response->body(encode_json({ success => 0, message => 'POST required' }));
        return;
    }

    my $now       = DateTime->now(time_zone => 'local');
    my $today     = $now->ymd;
    my $now_time  = $now->hms;
    my $username  = $c->session->{username} || 'system';
    my $sitename  = $c->session->{SiteName} || 'CSC';
    my $title     = "\x{1F433} Docker Deploy $today ${\$now->hms('.')}";

    my $todo_record_id = $c->req->body_params->{todo_record_id} || 0;
    my $trigger_source = $c->req->body_params->{trigger_source} || $c->req->body_params->{source} || 'manual';

    my $log_id;
    eval {
        my %log_fields = (
            abstract        => $title,
            username        => $username,
            sitename        => $sitename,
            start_date      => $today,
            due_date        => $today,
            start_time      => $now_time,
            end_time        => $now_time,
            time            => '00:00:00',
            status          => 2,
            priority        => 3,
            group_of_poster => 'admin',
            last_mod_by     => $username,
            last_mod_date   => $today,
            project_code    => 'PLANNING',
            details         => "Deploy in progress… (trigger: $trigger_source)",
            comments        => '',
            points_processed => 0,
        );
        $log_fields{todo_record_id} = $todo_record_id || 0;
        my $entry = $c->model('DBEncy')->resultset('Log')->create(\%log_fields);
        $log_id = $entry->id;
    };

    my $server_role = $self->_get_current_server_role($c);
    my @lines;
    my $success = 1;

    my $t0 = time();

    if ($server_role eq 'production1') {
        # Running on production1: delegate to workstation (build/edit/execute must happen there)
        push @lines, "[${\scalar localtime}] Detected production1 — SSHing to workstation to perform deploy (source: $trigger_source)...";
        # The workstation has the full source, docker build context, and rights.
        # We trigger the main deploy script on workstation (which will then push to prod if needed).
        my $workstation_host = 'workstation.local';  # or 192.168.1.199
        # Use standardized compose files + volume normalization via main deploy.sh
        my $cmd = "cd /home/shanta/PycharmProjects/comserv2/Comserv && TRIGGER_SOURCE='$trigger_source' DEPLOY_MODE=prod script/deploy.sh 2>&1";
        my $ssh_cmd = "ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 shanta\@$workstation_host \"$cmd\"";
        my $remote_output = `$ssh_cmd`;
        my $exit_code = $? >> 8;
        push @lines, $remote_output;
        push @lines, "Remote deploy on workstation exited with code $exit_code";
        $success = ($exit_code == 0);
    } else {
        # Safe server (workstation etc.): run locally with dated container backup
        # Using standardized comserv2_* volume compose files
        my $repo_path    = '/home/shanta/PycharmProjects/comserv2';
        my $base_compose = "$repo_path/Comserv/docker-compose.yml";
        my $prod_compose = "$repo_path/Comserv/docker-compose.prod.yml";
        my $nfs_compose  = "$repo_path/Comserv/docker-compose.prod.nfs.yml";
        my $container    = 'comserv-web-prod';

        # NEW: Support local staging deploy to port 4000 (web-staging service)
        #       and local workstation deploy to port 5000 (web-prod service)
        my $target = $c->req->body_params->{target} || '';
        if ($target =~ /^(local-staging|staging-4000|workstation|web-dev|local-test)$/) {
            push @lines, "[${\\scalar localtime}] $target DEPLOY requested";
            require Comserv::Util::DockerDeploy;
            my $deploy = Comserv::Util::DockerDeploy->new(
                log_fh  => undef,
                logging => $self->logging,
                repo    => "$repo_path/Comserv",
                target  => $target,
                trigger => $trigger_source,
                no_cache => $c->req->body_params->{no_cache} // 0,
            );
            # Use the shared safe entry point (ensures volumes first for any target)
            my $ok = $deploy->deploy_to_target_safe();
            push @lines, "[${\scalar localtime}] deploy_to_target_safe returned: " . ($ok ? "success" : "error");
            $success = $ok;
            push @lines, "[${\\scalar localtime}] Deploy to $target complete.";
            # Early return for local targets
            my $elapsed = time() - $t0;
            $c->response->body(encode_json({
                success => $success ? 1 : 0,
                message => $success ? 'Staging deploy complete' : 'Staging deploy had errors',
                log_id  => $log_id,
                output  => join("\n", @lines),
                title   => $title,
                server_role => $server_role,
                trigger_source => $trigger_source,
            }));
            return;
        }

        # Determine compose file list
        my @compose_files = ('-f', $base_compose, '-f', $prod_compose);
        if (-f $nfs_compose && $server_role eq 'production1') {
            push @compose_files, '-f', $nfs_compose;
        }
        my $compose_args = join(' ', @compose_files);

        push @lines, "[${\scalar localtime}] === git pull ===";
        my $git_out  = `cd '$repo_path' && git pull 2>&1`;
        my $git_exit = $? >> 8;
        push @lines, $git_out;
        push @lines, "git pull exited with code $git_exit" if $git_exit;
        $success = 0 if $git_exit;

        # === Step: Create dated backup via Model (Catalyst norm) ===
        push @lines, "[${\scalar localtime}] === Creating dated backup of $container ===";
        my $backup_result = $c->model('Docker')->create_dated_backup($container);
        if ($backup_result->{success}) {
            push @lines, "[${\scalar localtime}] Backup created: $backup_result->{backup_name}";
        } else {
            push @lines, "[${\scalar localtime}] Backup step skipped or failed";
        }

        # === Volume Normalization (ensure comserv2_* volumes) ===
        push @lines, "[${\scalar localtime}] === Normalizing volumes (comserv2_* standard) ===";
        my $norm_out = `cd '$repo_path/Comserv' && docker compose $compose_args config --quiet 2>&1 || true`;
        push @lines, $norm_out;

        # === Consistency Check (all servers must use the same comserv2_* volumes) ===
        my @canonical_volumes = qw(
            comserv2_config_db_data comserv2_redis_data comserv2_logs
            comserv2_sessions comserv2_workshop_files comserv2_whisper_venv
            comserv2_cpan_cache comserv2_temp comserv2_themes comserv2_cache
        );
        my $config_out = `cd '$repo_path/Comserv' && docker compose $compose_args config 2>/dev/null`;
        my %seen;
        while ($config_out =~ /comserv2_\w+/g) { $seen{$&} = 1; }
        my @missing = grep { !$seen{$_} } @canonical_volumes;
        my @extra   = grep { !grep { $_ eq $seen{$_} } @canonical_volumes } sort keys %seen;  # any comserv2_* not in canonical

        if (@missing || @extra) {
            my $err = "VOLUME INCONSISTENCY DETECTED\n  Missing: " . join(', ', @missing) .
                      "\n  Extra:   " . join(', ', @extra);
            push @lines, "[${\scalar localtime}] ERROR: $err";
            $self->logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'docker_deploy', $err);
            # Abort deploy
            $c->response->body(encode_json({ success => 0, message => 'Volume inconsistency', output => join("\n", @lines) })) if $c;
            exit 1;
        } else {
            push @lines, "[${\scalar localtime}] Volume consistency check passed (all comserv2_* volumes present).";
        }

        # === Build new image ===
        push @lines, "[${\scalar localtime}] === Building new image (web-prod) ===";
        my $build_out = `cd '$repo_path/Comserv' && docker compose $compose_args build web-prod --no-cache 2>&1`;
        push @lines, $build_out;
        if ($? >> 8) { $success = 0; }

        # === Start new container ===
        push @lines, "[${\scalar localtime}] === Starting new container ===";
        my $up_out = `cd '$repo_path/Comserv' && docker compose $compose_args up -d web-prod 2>&1`;
        push @lines, $up_out;
        if ($? >> 8) { $success = 0; }

        push @lines, "[${\scalar localtime}] Local deploy sequence complete.";
    }

    my $elapsed = time() - $t0;
    push @lines, "[${\scalar localtime}] Done in ${elapsed}s — " . ($success ? 'SUCCESS' : 'ERRORS DETECTED');

    my $output = join("\n", @lines);

    $self->logging->log_with_details($c, $success ? 'info' : 'error', __FILE__, __LINE__, 'deploy',
        "Docker deploy: success=$success elapsed=${elapsed}s server=$server_role trigger=$trigger_source log_id=" . ($log_id // 'n/a'));

    $c->response->body(encode_json({
        success => $success ? 1 : 0,
        message => $success ? 'Deploy complete' : 'Deploy had errors',
        log_id  => $log_id,
        output  => $output,
        title   => $title,
        server_role => $server_role,
        trigger_source => $trigger_source,
    }));
}

sub init_log :Path('/admin/docker/init_log') :Args(0) {
    my ($self, $c) = @_;

    $c->response->content_type('application/json; charset=utf-8');

    unless ($self->_can_access_docker_widget($c)) {
        $c->response->status(403);
        $c->response->body(encode_json({ success => 0, message => 'CSC admin only' }));
        return;
    }

    unless ($c->req->method eq 'POST') {
        $c->response->status(405);
        $c->response->body(encode_json({ success => 0, message => 'POST required' }));
        return;
    }

    my $now            = DateTime->now(time_zone => 'local');
    my $today          = $now->ymd;
    my $now_time       = $now->hms;
    my $username       = $c->session->{username} || 'system';
    my $sitename       = $c->session->{SiteName} || 'CSC';
    my $todo_record_id = $c->req->body_params->{todo_record_id} || 0;
    my $title          = "\x{1F433} Docker Hub Deploy $today ${\$now->hms('.')}";

    my $log_id;
    eval {
        my %log_fields = (
            abstract         => $title,
            username         => $username,
            sitename         => $sitename,
            start_date       => $today,
            due_date         => $today,
            start_time       => $now_time,
            end_time         => '00:00:00',
            time             => 0,
            status           => 2,
            priority         => 3,
            group_of_poster  => 'admin',
            last_mod_by      => $username,
            last_mod_date    => $today,
            project_code     => 'PLANNING',
            details          => 'Hub deploy in progress...',
            todo_record_id   => $todo_record_id || 0,
            comments         => '',
            points_processed => 0,
        );
        my $entry = $c->model('DBEncy')->resultset('Log')->create(\%log_fields);
        $log_id = $entry->id;
    };

    if ($@) {
        $c->response->body(encode_json({ success => 0, message => "Log creation failed: $@" }));
        return;
    }

    $c->response->body(encode_json({ success => 1, log_id => $log_id, title => $title }));
}

# ─────────────────────────────────────────────────────────────────────────────
# Deploy-to-production endpoint called by deploy_form.tt JS (POST /admin/docker-deploy-to-production)
# Starts a background (or placeholder) deploy and returns success immediately.
# The JS then polls /admin/docker-deploy-status until is_running becomes false.
# ─────────────────────────────────────────────────────────────────────────────
sub docker_deploy_to_production :Path('/admin/docker-deploy-to-production') :Args(0) {
    my ($self, $c) = @_;

    $c->response->content_type('application/json; charset=utf-8');

    unless ($self->_can_access_docker_widget($c)) {
        $c->response->status(403);
        $c->response->body(encode_json({ success => 0, message => 'CSC admin only' }));
        return;
    }

    my $trigger   = $c->req->body_params->{trigger_source} || 'manual';
    my $target    = $c->req->body_params->{target} || 'production1';  # extract BEFORE fork
    my $no_cache  = $c->req->body_params->{no_cache} // 0;
    my $log_file  = '/tmp/comserv_deploy.log';
    my $pid_file  = '/tmp/comserv_deploy.pid';

    unlink $log_file;
    unlink $pid_file;

    # Resolve SSH credentials before forking so the child inherits $ENV{SSHPASS}
    my $is_remote_target = ($target ne 'staging-4000' && $target ne 'local-staging' && $target ne 'web-dev');
    if ($is_remote_target) {
        my $admin_ctrl = $c->controller('Admin');
        my ($resolved_host, $resolved_user, $ssh_port, $ssh_pass) = $admin_ctrl->_resolve_ssh_target($target);
        if ($ssh_pass) {
            $ENV{SSHPASS} = $ssh_pass;
        }
        # Also set user for the SSH prefix in DockerDeploy (used in its own target mapping)
    }

    my $pid = fork();
    if (!defined $pid) {
        $c->response->body(encode_json({ success => 0, message => 'fork failed' }));
        return;
    }

    if ($pid == 0) {
        # CHILD – catch ALL fatal errors and write them to the log file
        local $SIG{__DIE__} = sub {
            my $err = shift || 'unknown error';
            if (open my $lf, '>>', $log_file) {
                print $lf "[".scalar(localtime)."] CHILD CRASHED: $err\n";
                close $lf;
            }
            unlink $pid_file;
            exit(1);
        };

        close_std_fds();
        open(my $log, '>>', $log_file) or do {
            warn "Cannot open $log_file: $!";
            unlink $pid_file;
            exit(1);
        };
        $| = 1;
        select((select($log), $|=1)[0]);

        print $log "[".scalar(localtime)."] === DOCKER DEPLOY STARTED (trigger=$trigger, target=$target) ===\n";
        $log->flush();

        # Wrap both ->new and deploy in eval so any error is logged
        my $deployer;
        eval {
            $deployer = Comserv::Util::DockerDeploy->new(
                log_fh   => $log,
                logging  => $self->logging,
                trigger  => $trigger,
                target   => $target,
                no_cache => $no_cache,
            );
        };
        if ($@) {
            print $log "[".scalar(localtime)."] Failed to create DockerDeploy: $@\n";
            $log->flush();
            close($log);
            unlink($pid_file);
            exit(1);
        }

        eval {
            my $ok = $deployer->deploy_to_target_safe;
            print $log "[".scalar(localtime)."] deploy_to_target_safe finished: " . ($ok ? "SUCCESS\n" : "FAIL\n");
            $log->flush();
            if ($ok) {
                $deployer->_log("=== DEPLOY COMPLETE ===");
            } else {
                $deployer->_log("=== DEPLOY FAILED (see errors above) ===");
            }
        };
        if ($@) {
            print $log "[".scalar(localtime)."] CRASH in deploy: $@\n";
            $log->flush();
        }
        close($log);
        unlink($pid_file);
        exit(0);
    }

    sub close_std_fds {
        # Child process inherits parent's DB handles. They're harmless — the
        # child exits after the deploy finishes, and the OS reclaims them.
        # Explicit disconnect is unreliable across DBI versions, so skip it.
    }

    # PARENT
    open(my $pf, '>', $pid_file); print $pf $pid; close($pf);
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'docker_deploy',
        "Background deploy started (pid=$pid)");

    $c->response->body(encode_json({ success => 1, message => 'Background deploy started' }));
}

# ─────────────────────────────────────────────────────────────────────────────
# Deploy status endpoint (polled by deploy_form.tt JS)
# Returns whether a background deploy is still running.
# Minimal implementation: always reports not-running (no background job tracked yet).
# Extend later with a real job queue / PID file if needed.
# ─────────────────────────────────────────────────────────────────────────────
sub deploy_status :Path('/admin/docker-deploy-status') :Args(0) {
    my ($self, $c) = @_;

    $c->response->content_type('application/json; charset=utf-8');

    my $pid_file = '/tmp/comserv_deploy.pid';
    my $log_file = '/tmp/comserv_deploy.log';

    my $is_running = 0;
    if (-f $pid_file) {
        my $pid = do { open my $fh, '<', $pid_file; local $/; <$fh> };
        chomp $pid;
        if ($pid && kill 0, $pid) {
            $is_running = 1;
        } else {
            unlink $pid_file;   # stale
        }
    }

    # Always return the FULL current log content (not incremental)
    my $output = '';
    if (-f $log_file) {
        if (open my $fh, '<', $log_file) {
            local $/;
            $output = <$fh>;
            close $fh;
        }
    }

    $c->response->body(encode_json({
        success    => 1,
        is_running => $is_running ? 1 : 0,
        output     => $output,
    }));
}

sub close_deploy_log :Path('/admin/docker/close_deploy_log') :Args(0) {
    my ($self, $c) = @_;

    $c->response->content_type('application/json; charset=utf-8');

    unless ($self->_can_access_docker_widget($c)) {
        $c->response->status(403);
        $c->response->body(encode_json({ success => 0, message => 'CSC admin only' }));
        return;
    }

    unless ($c->req->method eq 'POST') {
        $c->response->status(405);
        $c->response->body(encode_json({ success => 0, message => 'POST required' }));
        return;
    }

    my $log_id  = $c->req->body_params->{log_id}  || 0;
    my $output  = $c->req->body_params->{output}  || '';
    my $notes   = $c->req->body_params->{notes}   || '';

    unless ($log_id) {
        $c->response->body(encode_json({ success => 0, message => 'log_id required' }));
        return;
    }

    my $now      = DateTime->now(time_zone => 'local');
    my $end_time = $now->hms;

    eval {
        my $entry = $c->model('DBEncy')->resultset('Log')->find($log_id);
        if ($entry) {
            my $start = $entry->start_time || '00:00:00';
            my ($sh,$sm) = split /:/, $start;
            my ($eh,$em) = split /:/, $end_time;
            my $mins = ($eh*60+$em) - ($sh*60+$sm);
            $mins = 0 if $mins < 0;
            my $elapsed = sprintf('%02d:%02d:00', int($mins/60), $mins%60);

            my $details_text = $notes || 'Docker Hub deployment executed.';

            # Save full log output to a persistent file (DB comments field is too small)
            my $log_dir  = '/home/shanta/PycharmProjects/comserv2/log/docker_deploy';
            system("mkdir -p $log_dir") == 0 or warn "mkdir $log_dir failed: $!";
            my $ts = $now->ymd('') . '_' . $now->hms('');
            my $output_file = "$log_dir/deploy_$ts.log";
            if (open my $lfh, '>', $output_file) {
                print $lfh $output;
                close $lfh;
            } else {
                warn "Cannot write $output_file: $!";
                $output_file = '';
            }

            # Store a short summary + file path in the DB comments field
            my $summary = $details_text;
            $summary .= "\n\n--- Full log saved to: $output_file" if $output_file;
            # Truncate to fit in text column (65KB), keep the file pointer
            my $truncated = length($output) > 60000
                ? " (full log truncated — see file on server)"
                : '';
            $summary .= $truncated if $truncated;

            $entry->update({
                status      => 3,
                end_time    => $end_time,
                time        => $elapsed,
                details     => $details_text,
                comments    => $summary,
                last_mod_by => $c->session->{username} || 'system',
            });

            # Link the dated deploy log file to the Todo task (don't dump the whole log)
            my $todo_record_id = $entry->todo_record_id;
            if ($todo_record_id && $output_file) {
                my $todo = $c->model('DBEncy')->resultset('Todo')->find($todo_record_id);
                if ($todo) {
                    my $existing_comments = $todo->comments || '';
                    my $timestamp = localtime();
                    my $log_link = "\n\n=== DEPLOYMENT ($timestamp) ===\nFull log: $output_file";
                    # Only note the size, never store the body
                    my $log_size = -s $output_file || 0;
                    $log_link .= " ($log_size bytes)" if $log_size;
                    $todo->update({
                        comments      => $existing_comments . $log_link,
                        last_mod_by   => $c->session->{username} || 'system',
                        last_mod_date => $now->ymd,
                    });
                }
            }
        }
    };
    $c->response->body(encode_json({ success => $@ ? 0 : 1, message => $@ ? "Error: $@" : 'Log closed' }));
}

sub list :Path('/admin/docker/list') :Args(0) {
    my ($self, $c) = @_;

    unless ($self->_can_access_docker_widget($c)) {
        $c->stash->{json} = { success => 0, error => 'Docker widget restricted to admins on non-production1 servers.' };
        $c->forward('View::JSON');
        return;
    }

    my $host = $c->req->param('host') || 'workstation';

    my @containers = ();

    my $ssh_prefix;  # Declare early

    if ($host eq 'workstation' || $host eq 'localhost' || $host eq '127.0.0.1') {
        my $output = `docker ps -a --format '{{.ID}}|{{.Names}}|{{.Image}}|{{.Status}}|{{.Ports}}|{{.CreatedAt}}|{{.RunningFor}}|{{.State}}|{{.Mounts}}|{{.Networks}}' 2>/dev/null || echo ''`;
        foreach my $line (split /\n/, $output) {
            next unless $line =~ /\|/;
            my ($id, $name, $image, $status, $ports, $created, $running_for, $state, $mounts, $networks) = split /\|/, $line, 10;
            $id = substr($id, 0, 12) if $id;
            my $is_backup_container = ($name =~ /^bk-/i || $name =~ /backup/i || $name =~ /\.backup\./i) ? 1 : 0;

            # Get image creation date
            my $img_created = '';
            my $img_inspect = `docker inspect --format='{{.Created}}' "$image" 2>/dev/null | head -1`;
            if ($img_inspect) {
                chomp $img_inspect;
                $img_created = $img_inspect;
            }

            # For backup containers also fetch container creation time
            my $container_created = '';
            if ($is_backup_container) {
                $container_created = $c->model('Docker')->get_container_created($name);
            }

            push @containers, {
                id => $id,
                name => $name,
                image => $image,
                status => $status,
                state => $state || ($status =~ /Up/i ? 'running' : ($status =~ /Exited/i ? 'exited' : 'unknown')),
                ports => $ports || '',
                created => $created || '',
                running_for => $running_for || '',
                mounts => $mounts || '',
                networks => $networks || '',
                is_backup_container => $is_backup_container,
                image_created => $img_created,
                container_created => $container_created,
            };
        }
    } else {
        my $ssh_host = $host eq 'production1' ? '192.168.1.126' : '192.168.1.127';
        my $ssh_user = 'ubuntu';

        my $admin_ctrl = $c->controller('Admin');
        my ($resolved_host, $resolved_user, $ssh_port, $ssh_pass) = $admin_ctrl->_resolve_ssh_target($host);
        $ssh_pass ||= $ENV{SSHPASS} || '';

        unless ($ssh_pass) {
            $c->stash->{json} = { success => 0, error => "No SSH password for $host", host => $host };
            $c->forward('View::JSON');
            return;
        }

        local $ENV{SSHPASS} = $ssh_pass;
        $ssh_prefix = "sshpass -e ssh -o StrictHostKeyChecking=no $ssh_user\@$ssh_host";

        my $cmd = "$ssh_prefix \"docker ps -a --format '{{.ID}}|{{.Names}}|{{.Image}}|{{.Status}}|{{.Ports}}' 2>/dev/null || echo ''\"";
        my $output = `$cmd 2>/dev/null` || '';

        foreach my $line (split /\n/, $output) {
            next unless $line =~ /\|/;
            my ($id, $name, $image, $status, $ports) = split /\|/, $line, 5;
            # Detect dated backup containers
            my $is_backup_container = ($name =~ /^bk-/i || $name =~ /backup/i || $name =~ /\.backup\./i) ? 1 : 0;

            # Get image creation date
            my $img_created = '';
            my $img_inspect = `docker inspect --format='{{.Created}}' "$image" 2>/dev/null | head -1`;
            if ($img_inspect) {
                chomp $img_inspect;
                $img_created = $img_inspect;
            }

            # For backup containers also fetch container creation time
            my $container_created = '';
            if ($is_backup_container) {
                $container_created = $c->model('Docker')->get_container_created($name);
            }

            push @containers, {
                id => $id,
                name => $name,
                image => $image,
                status => $status,
                state => $status =~ /Up/i ? 'running' : ($status =~ /Exited/i ? 'exited' : 'unknown'),
                ports => $ports || '',
                is_backup_container => $is_backup_container,
                image_created => $img_created,
                container_created => $container_created,
            };
        }
    }

    # Backup Images
    my @backups = ();
    my $img_cmd = ($host eq 'workstation' || $host eq 'localhost' || $host eq '127.0.0.1')
        ? 'docker images --filter "reference=*backup*" --format "{{.Repository}}|{{.Tag}}|{{.ID}}|{{.CreatedAt}}|{{.Size}}" 2>/dev/null'
        : qq{$ssh_prefix "docker images --filter 'reference=*backup*' --format '{{.Repository}}|{{.Tag}}|{{.ID}}|{{.CreatedAt}}|{{.Size}}' 2>/dev/null"};

    my $img_out = `$img_cmd` || '';
    foreach my $line (split /\n/, $img_out) {
        next unless $line =~ /\|/;
        my ($repo, $tag, $id, $created, $size) = split /\|/, $line, 5;
        next unless $tag && $tag =~ /^backup-/;
        push @backups, {
            id => $id,
            name => "$repo:$tag",
            image => "$repo:$tag",
            tag => $tag,
            state => 'backup',
            status => 'Available Backup',
            is_backup => 1,
            created => $created,
            size => $size || '',
        };
    }

    my @all_entries = (@containers, @backups);

    # === Persistent Data Volumes (cache, backup, temp, workshop) ===
    my @volumes = ();
    my $vol_cmd = ($host eq 'workstation' || $host eq 'localhost' || $host eq '127.0.0.1')
        ? 'docker volume ls --format "{{.Name}}" 2>/dev/null'
        : qq{$ssh_prefix "docker volume ls --format '{{.Name}}' 2>/dev/null"};

    my $vol_out = `$vol_cmd` || '';
    my %canonical = map { $_ => 1 } qw(
        comserv2_config_db_data comserv2_redis_data comserv2_logs
        comserv2_sessions comserv2_workshop_files comserv2_whisper_venv
        comserv2_cpan_cache comserv2_temp comserv2_themes comserv2_cache
    );
    foreach my $vname (split /\n/, $vol_out) {
        chomp $vname;
        next unless $canonical{$vname};
        my $inspect_cmd = ($host eq 'workstation' || $host eq 'localhost')
            ? "docker volume inspect $vname 2>/dev/null"
            : qq{$ssh_prefix "docker volume inspect $vname 2>/dev/null"};
        my $inspect_json = `$inspect_cmd` || '[]';
        my $vdata;
        eval { $vdata = decode_json($inspect_json); };
        next if $@ || ref($vdata) ne 'ARRAY' || !@$vdata;
        my $vi = $vdata->[0];

        my $created = $vi->{CreatedAt} || '';
        my $mountpoint = $vi->{Mountpoint} || '';
        my $driver = $vi->{Driver} || 'local';

        # Try to get size (best effort)
        my $size = 'unknown';
        if ($mountpoint) {
            my $size_cmd = ($host eq 'workstation')
                ? "du -sh $mountpoint 2>/dev/null | cut -f1"
                : qq{$ssh_prefix "du -sh $mountpoint 2>/dev/null | cut -f1"};
            $size = `$size_cmd` || 'unknown';
            chomp $size;
        }

        my $is_cache = $vname =~ /cache/i;
        my $is_backup = $vname =~ /backup/i;
        my $is_temp = $vname =~ /temp/i;
        my $is_workshop = $vname =~ /workshop/i;

        push @volumes, {
            name => $vname,
            driver => $driver,
            created => $created,
            mountpoint => $mountpoint,
            size => $size,
            is_cache => $is_cache ? 1 : 0,
            is_backup => $is_backup ? 1 : 0,
            is_temp => $is_temp ? 1 : 0,
            is_workshop => $is_workshop ? 1 : 0,
            highlight => ($is_cache || $is_backup) ? 1 : 0,
        };
    }

    $c->stash->{json} = {
        success => 1,
        containers => \@containers,
        backups => \@backups,
        all_entries => \@all_entries,
        volumes => \@volumes,
        host => $host
    };
    $c->forward('View::JSON');
}

# ── Shared helper: run a container action locally or via SSH ──
sub _run_docker_action {
    my ($self, $c, $action, $container) = @_;
    # action: start|stop|restart|rm
    my $host = $c->req->param('host') || 'workstation';
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, $action,
        "Running docker $action on $container ($host)");

    my ($output, $success);
    if ($host eq 'workstation' || $host eq 'localhost' || $host eq '127.0.0.1') {
        if ($action eq 'rm') {
            my $force = $c->req->param('force') || 0;
            my $cmd = $force
                ? "docker rm -f \"$container\" 2>&1"
                : "docker rm \"$container\" 2>&1";
            $output = `$cmd`;
        } else {
            $output = `docker $action $container 2>&1`;
        }
        $success = $? == 0;
    } else {
        my $admin_ctrl = $c->controller('Admin');
        my ($resolved_host, $resolved_user, $ssh_port, $ssh_pass) = $admin_ctrl->_resolve_ssh_target($host);
        $ssh_pass ||= $ENV{SSHPASS} || '';
        unless ($ssh_pass) {
            return (0, '', "No SSH password for $host");
        }
        local $ENV{SSHPASS} = $ssh_pass;

        my $ssh_host = $host eq 'production1' ? '192.168.1.126' : '192.168.1.127';
        my $remote_cmd = "docker $action $container 2>&1";
        my $cmd = $action eq 'rm'
            ? "sshpass -e ssh -o StrictHostKeyChecking=no ubuntu\@$ssh_host \"$remote_cmd\""
            : "sshpass -e ssh -o StrictHostKeyChecking=no ubuntu\@$ssh_host \"$remote_cmd\"";
        $output = `$cmd 2>/dev/null` || '';
        $success = $? == 0;
    }

    return ($success, $output);
}

sub restart :Path('/admin/docker/restart') :Args(1) {
    my ($self, $c, $service) = @_;

    unless ($c->req->method eq 'POST') {
        $c->stash->{json} = { success => 0, stderr => 'POST required' };
        $c->forward('View::JSON');
        return;
    }

    my ($success, $output) = $self->_run_docker_action($c, 'restart', $service);
    my $host = $c->req->param('host') || 'workstation';
    $c->stash->{json} = {
        success => $success ? 1 : 0,
        message => $success ? "Restarted $service on $host" : "Restart failed on $host",
        output  => $output,
        stderr  => $output,
    };
    $c->forward('View::JSON');
}

sub rebuild :Path('/admin/docker/rebuild') :Args(1) {
    my ($self, $c, $service) = @_;

    unless ($c->req->method eq 'POST') {
        $c->stash->{json} = { success => 0, error => 'POST required' };
        $c->forward('View::JSON');
        return;
    }

    my $host = $c->req->param('host') || 'workstation';
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'rebuild', "Rebuild requested for $service on $host");

    # Map container name to DockerDeploy target
    my $deploy_target;
    if ($service eq 'comserv2-web-dev') {
        $deploy_target = 'web-dev';
    } elsif ($service eq 'comserv2-web-staging') {
        $deploy_target = 'staging-4000';
    } elsif ($service eq 'comserv-web-prod') {
        $deploy_target = $host;
    } else {
        $c->stash->{json} = { success => 0, error => "Unknown container: $service" };
        $c->forward('View::JSON');
        return;
    }

    my $no_cache = $c->req->body_params->{no_cache} // 0;
    my $log_file = '/tmp/comserv_deploy.log';
    my $pid_file = '/tmp/comserv_deploy.pid';
    unlink $log_file;
    unlink $pid_file;

    my $pid = fork();
    if (!defined $pid) {
        $c->stash->{json} = { success => 0, error => 'fork failed' };
        $c->forward('View::JSON');
        return;
    }

    if ($pid == 0) {
        # CHILD — run the deploy asynchronously
        local $SIG{__DIE__} = sub {
            my $err = shift || 'unknown error';
            if (open my $lf, '>>', $log_file) {
                print $lf "[" . scalar(localtime) . "] CHILD CRASHED: $err\n";
                close $lf;
            }
            unlink $pid_file;
            exit(1);
        };

        close_std_fds();
        open(my $log, '>>', $log_file) or do {
            warn "Cannot open $log_file: $!";
            unlink $pid_file;
            exit(1);
        };
        $| = 1;
        select((select($log), $|=1)[0]);

        print $log "[" . scalar(localtime) . "] === REBUILD STARTED (service=$service, target=$deploy_target, no_cache=" . ($no_cache ? 'yes' : 'no') . ") ===\n";
        $log->flush();

        require Comserv::Util::DockerDeploy;
        my $deployer;
        eval {
            $deployer = Comserv::Util::DockerDeploy->new(
                log_fh   => $log,
                logging  => $self->logging,
                repo    => '/home/shanta/PycharmProjects/comserv2/Comserv',
                target  => $deploy_target,
                trigger => 'rebuild',
                no_cache => $no_cache,
            );
        };
        if ($@) {
            print $log "[" . scalar(localtime) . "] Failed to create DockerDeploy: $@\n";
            $log->flush();
            close($log);
            unlink($pid_file);
            exit(1);
        }

        eval {
            my $ok = $deployer->deploy_to_target_safe();
            print $log "[" . scalar(localtime) . "] deploy_to_target_safe finished: " . ($ok ? "SUCCESS\n" : "FAIL\n");
            $log->flush();
            if ($ok) {
                print $log "[" . scalar(localtime) . "] === REBUILD SUCCESS ===\n";
            } else {
                print $log "[" . scalar(localtime) . "] === REBUILD FAILED (see errors above) ===\n";
            }
        };
        if ($@) {
            print $log "[" . scalar(localtime) . "] CRASH in deploy: $@\n";
            $log->flush();
        }
        close($log);
        unlink($pid_file);
        exit(0);
    }

    # PARENT
    open(my $pf, '>', $pid_file); print $pf $pid; close($pf);
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'rebuild',
        "Rebuild backgrounded for $service (target=$deploy_target, pid=$pid)");

    $c->stash->{json} = {
        success => 1,
        message => "Rebuild started for $service on $host",
        target  => $deploy_target,
    };
    $c->forward('View::JSON');
}

sub stop :Path('/admin/docker/stop') :Args(1) {
    my ($self, $c, $service) = @_;

    unless ($c->req->method eq 'POST') {
        $c->stash->{json} = { success => 0, stderr => 'POST required' };
        $c->forward('View::JSON');
        return;
    }

    my ($success, $output) = $self->_run_docker_action($c, 'stop', $service);
    my $host = $c->req->param('host') || 'workstation';
    $c->stash->{json} = {
        success => $success ? 1 : 0,
        message => $success ? "Stopped $service on $host" : "Stop failed on $host",
        output  => $output,
        stderr  => $output,
    };
    $c->forward('View::JSON');
}

sub down :Path('/admin/docker/down') :Args(1) {
    my ($self, $c, $service) = @_;
    
    unless ($c->req->method eq 'POST') {
        $c->stash->{json} = { success => 0, stderr => 'POST required' };
        $c->forward('View::JSON');
        return;
    }
    
    
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'down', "Downing service: $service");
    my $result = $c->model('Docker')->down_container($service);
    
    $c->stash->{json} = $result;
    $c->forward('View::JSON');
}

sub start :Path('/admin/docker/start') :Args(1) {
    my ($self, $c, $service) = @_;

    unless ($c->req->method eq 'POST') {
        $c->stash->{json} = { success => 0, stderr => 'POST required' };
        $c->forward('View::JSON');
        return;
    }

    my ($success, $output) = $self->_run_docker_action($c, 'start', $service);
    my $host = $c->req->param('host') || 'workstation';
    $c->stash->{json} = {
        success => $success ? 1 : 0,
        message => $success ? "Started $service on $host" : "Start failed on $host",
        output  => $output,
        stderr  => $output,
    };
    $c->forward('View::JSON');
}

sub up :Path('/admin/docker/up') :Args(1) {
    my ($self, $c, $service) = @_;
    
    unless ($c->req->method eq 'POST') {
        $c->stash->{json} = { success => 0, stderr => 'POST required' };
        $c->forward('View::JSON');
        return;
    }
    
    
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'up', "Up-ing service: $service");
    my $result = $c->model('Docker')->up_container($service);
    
    $c->stash->{json} = $result;
    $c->forward('View::JSON');
}

sub recovery_history :Path('/admin/docker/recovery_history') :Args(0) {
    my ($self, $c) = @_;
    
    my $host = $c->req->param('host') || 'production1';
    my $service = $c->req->param('service') || 'web-prod';
    
    # For now we read the JSON log file via SSH on the target host
    my $ssh_host = $host eq 'production1' ? '192.168.1.126' : ($host eq 'production2' ? '192.168.1.127' : 'localhost');
    my $ssh_user = 'ubuntu';
    
    my $admin_ctrl = $c->controller('Admin');
    my ($resolved_host, $resolved_user, $ssh_port, $ssh_pass) = $admin_ctrl->_resolve_ssh_target($host);
    $ssh_pass ||= $ENV{SSHPASS} || '';
    
    unless ($ssh_pass) {
        $c->stash->{json} = { success => 0, error => "No SSH password for $host", host => $host };
        $c->forward('View::JSON');
        return;
    }
    
    local $ENV{SSHPASS} = $ssh_pass;
    my $cmd = sprintf(qq(sshpass -e ssh -o StrictHostKeyChecking=no %s@%s 'cat /tmp/comserv_recovery_history.json 2>/dev/null || echo "[]"'), $ssh_user, $ssh_host);
    
    my $json = `$cmd 2>/dev/null` || '[]';
    $json =~ s/^\s+|\s+$//g;
    
    my $history;
    eval { $history = decode_json($json); };
    $history = [] if $@ || ref($history) ne 'ARRAY';
    
    $c->stash->{json} = { success => 1, host => $host, service => $service, history => $history };
    $c->forward('View::JSON');
}

sub start_backup :Path('/admin/docker/start_backup') :Args(0) {
    my ($self, $c) = @_;
    
    unless ($c->req->method eq 'POST') {
        $c->stash->{json} = { success => 0, error => 'POST required' };
        $c->forward('View::JSON');
        return;
    }
    
    my $host = $c->req->param('host') || 'production1';
    my $backup_tag = $c->req->param('backup_tag');
    my $service = $c->req->param('service') || 'web-prod';
    
    unless ($backup_tag) {
        $c->stash->{json} = { success => 0, error => 'backup_tag required' };
        $c->forward('View::JSON');
        return;
    }
    
    my $ssh_host = $host eq 'production1' ? '192.168.1.126' : ($host eq 'production2' ? '192.168.1.127' : 'localhost');
    my $ssh_user = 'ubuntu';
    
    my $admin_ctrl = $c->controller('Admin');
    my ($resolved_host, $resolved_user, $ssh_port, $ssh_pass) = $admin_ctrl->_resolve_ssh_target($host);
    $ssh_pass ||= $ENV{SSHPASS} || '';
    
    unless ($ssh_pass) {
        $c->stash->{json} = { success => 0, error => "No SSH password for $host", host => $host };
        $c->forward('View::JSON');
        return;
    }
    
    local $ENV{SSHPASS} = $ssh_pass;
    my $ssh_prefix = "sshpass -e ssh -o StrictHostKeyChecking=no $ssh_user\@$ssh_host";
    
    my $container_name = "comserv2-$service";
    my $image_name = "comserv2-$service";
    
    # Stop + remove current container
    my $stop_cmd = "$ssh_prefix \"sudo docker stop $container_name 2>/dev/null; sudo docker rm -f $container_name 2>/dev/null\"";
    system($stop_cmd);
    
    # Start the selected backup
    my $start_cmd = "$ssh_prefix \"sudo docker run -d --name $container_name --restart unless-stopped -p 5000:3000 --log-opt max-size=50m --log-opt max-file=5 -e SYSTEM_IDENTIFIER=$host $image_name:$backup_tag\"";
    my $output = `$start_cmd 2>&1`;
    my $exit = $? >> 8;
    
    # Log the manual start
    my $log_entry = {
        timestamp => scalar(localtime),
        container => $container_name,
        reason => "Manual start of backup: $backup_tag",
        health_status => 'manual',
        last_logs => 'User-initiated failover via UI',
        port_check => 'manual start',
        app_error => '',
        backup_tag => $backup_tag,
    };
    
    my $recovery_log = '/tmp/comserv_recovery_history.json';
    my $existing = `$ssh_prefix "cat $recovery_log 2>/dev/null || echo '[]'"` || '[]';
    $existing =~ s/^\s+|\s+$//g;
    
    # Append log entry
    my $append_cmd = "$ssh_prefix \"echo '".encode_json([$log_entry])."' | sudo tee -a $recovery_log >/dev/null 2>&1 || true\"";
    system($append_cmd);
    
    if ($exit == 0) {
        $c->stash->{json} = { success => 1, message => "Started backup $backup_tag", output => $output };
    } else {
        $c->stash->{json} = { success => 0, error => "Failed to start backup", output => $output };
    }
    $c->forward('View::JSON');
}

sub restore_backup :Path('/admin/docker/restore_backup') :Args(0) {
    my ($self, $c) = @_;

    unless ($c->req->method eq 'POST') {
        $c->stash->{json} = { success => 0, error => 'POST required' };
        $c->forward('View::JSON');
        return;
    }

    my $host = $c->req->param('host') || 'production1';
    my $backup_name = $c->req->param('backup_name');
    my $service = $c->req->param('service') || '';

    unless ($backup_name) {
        $c->stash->{json} = { success => 0, error => 'backup_name required' };
        $c->forward('View::JSON');
        return;
    }

    # Derive active container name from backup name:
    #   bk-comserv2-web-prod-20260706_235959  ->  comserv2-web-prod
    my $active_name = $backup_name;
    $active_name =~ s/^bk-//;
    $active_name =~ s/-\d{8}_\d{6}$//;

    # Determine service from active name if not provided
    $service = $active_name;
    $service =~ s/^comserv2-//;

    # Determine host SSH details
    my $is_remote = ($host ne 'workstation' && $host ne 'localhost' && $host ne '127.0.0.1');
    my $ssh_prefix = '';
    if ($is_remote) {
        my $ssh_host = $host eq 'production1' ? '192.168.1.126' : '192.168.1.127';
        my $ssh_user = 'ubuntu';
        my $admin_ctrl = $c->controller('Admin');
        my ($resolved_host, $resolved_user, $ssh_port, $ssh_pass) = $admin_ctrl->_resolve_ssh_target($host);
        $ssh_pass ||= $ENV{SSHPASS} || '';
        unless ($ssh_pass) {
            $c->stash->{json} = { success => 0, error => "No SSH password for $host", host => $host };
            $c->forward('View::JSON');
            return;
        }
        local $ENV{SSHPASS} = $ssh_pass;
        $ssh_prefix = "sshpass -e ssh -o StrictHostKeyChecking=no $ssh_user\@$ssh_host";
        $ssh_prefix .= " sudo";
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'restore_backup',
        "Restoring backup container $backup_name as $active_name on $host");

    my $now = DateTime->now(time_zone => 'local');
    my $ts = $now->ymd('') . '_' . $now->hms('');
    my $new_backup = "bk-$active_name-$ts";

    my @output;
    my $success = 1;

    # Step 1: Stop the active container
    my $stop_cmd = $is_remote
        ? "$ssh_prefix \"docker stop $active_name 2>&1 || true\""
        : "docker stop $active_name 2>&1 || true";
    my $stop_out = `$stop_cmd`;
    push @output, "Stopped $active_name: $stop_out";

    # Step 2: Rename the active container to a new dated backup
    # (docker rename only works on stopped containers)
    my $rename_active_cmd = $is_remote
        ? "$ssh_prefix \"docker rename $active_name $new_backup 2>&1 || true\""
        : "docker rename $active_name $new_backup 2>&1 || true";
    my $rename_active_out = `$rename_active_cmd`;
    push @output, "Preserved previous active as $new_backup: $rename_active_out";

    # Step 3: Rename the backup container to the active name
    my $rename_backup_cmd = $is_remote
        ? "$ssh_prefix \"docker rename $backup_name $active_name 2>&1\""
        : "docker rename $backup_name $active_name 2>&1";
    my $rename_backup_out = `$rename_backup_cmd`;
    my $rename_exit = $? >> 8;
    if ($rename_exit != 0) {
        push @output, "ERROR renaming $backup_name to $active_name: $rename_backup_out";
        $success = 0;
    } else {
        push @output, "Renamed $backup_name to $active_name";
    }

    # Step 4: Start the now-restored active container
    my $start_cmd = $is_remote
        ? "$ssh_prefix \"docker start $active_name 2>&1\""
        : "docker start $active_name 2>&1";
    my $start_out = `$start_cmd`;
    my $start_exit = $? >> 8;
    if ($start_exit != 0) {
        push @output, "ERROR starting $active_name: $start_out";
        $success = 0;
    } else {
        push @output, "Started $active_name";
    }

    # Log the restore in recovery history (remote only)
    if ($is_remote) {
        my $recovery_log = '/tmp/comserv_recovery_history.json';
        my $existing = `$ssh_prefix \"cat $recovery_log 2>/dev/null || echo '[]'\"` || '[]';
        $existing =~ s/^\s+|\s+$//g;
        my $log_entry = {
            timestamp => scalar(localtime),
            container => $active_name,
            reason => "Manual restore from backup: $backup_name",
            health_status => $success ? 'started' : 'failed',
            last_logs => $success ? 'Restore complete via UI' : 'Restore failed',
        };
        my $append_cmd = "$ssh_prefix \"echo '" . encode_json([$log_entry]) . "' | tee -a $recovery_log >/dev/null 2>&1 || true\"";
        system($append_cmd);
    }

    $c->stash->{json} = {
        success => $success,
        message => $success
            ? "Restored $backup_name as $active_name (previous active saved as $new_backup)"
            : "Restore partially failed — see output",
        output => join("\n", @output),
    };
    $c->forward('View::JSON');
}

sub delete :Path('/admin/docker/delete') :Args(1) {
    my ($self, $c, $name) = @_;

    unless ($c->req->method eq 'POST') {
        $c->stash->{json} = { success => 0, stderr => 'POST required' };
        $c->forward('View::JSON');
        return;
    }

    unless ($self->_can_access_docker_widget($c)) {
        $c->stash->{json} = { success => 0, error => 'CSC admin only' };
        $c->forward('View::JSON');
        return;
    }

    my ($success, $output) = $self->_run_docker_action($c, 'rm', $name);
    my $host = $c->req->param('host') || 'workstation';

    $self->logging->log_with_details($c, $success ? 'info' : 'error', __FILE__, __LINE__, 'docker_delete',
        "Deleted container: $name (host=$host)");

    $c->stash->{json} = {
        success => $success ? 1 : 0,
        output  => $output,
        message => $success ? "Container $name removed from $host" : "Failed to remove $name on $host"
    };
    $c->forward('View::JSON');
}

# ── /admin/docker/deploy-logs — get deploy log for a container ──
sub deploy_logs :Path('/admin/docker/deploy-logs') :Args(1) {
    my ($self, $c, $container_name) = @_;

    my $log_dir = '/home/shanta/PycharmProjects/comserv2/log/docker_deploy/' . $container_name;
    my @logs;
    if (-d $log_dir) {
        opendir my $dh, $log_dir or do {
            $c->stash->{json} = { success => 0, error => "Cannot read $log_dir" };
            $c->forward('View::JSON');
            return;
        };
        while (my $f = readdir $dh) {
            next unless $f =~ /\.log$/;
            push @logs, { file => $f, path => "$log_dir/$f", mtime => (stat("$log_dir/$f"))[9] };
        }
        closedir $dh;
        @logs = sort { $b->{mtime} <=> $a->{mtime} } @logs;  # newest first
    }

    # If a specific file is requested via ?file= param, return its content
    my $req_file = $c->req->param('file');
    if ($req_file) {
        my $path = "$log_dir/$req_file";
        $path =~ s/\.\.//g;  # prevent path traversal
        if (-f $path) {
            if (open my $fh, '<', $path) {
                local $/;
                my $content = <$fh>;
                close $fh;
                $c->stash->{json} = { success => 1, output => $content, logs => \@logs };
                $c->forward('View::JSON');
                return;
            }
        }
        $c->stash->{json} = { success => 0, error => "File not found: $req_file" };
        $c->forward('View::JSON');
        return;
    }

    $c->stash->{json} = { success => 1, logs => \@logs };
    $c->forward('View::JSON');
}

sub logs :Path('/admin/docker/logs') :Args(1) {
    my ($self, $c, $service) = @_;
    
    my $lines = $c->req->param('lines') || 100;
    my $host  = $c->req->param('host')  || 'workstation';
    
    if ($host eq 'workstation' || $host eq 'localhost' || $host eq '127.0.0.1') {
        my $result = $c->model('Docker')->get_container_logs($service, $lines);
        $c->stash->{json} = $result;
    } else {
        # Remote host via SSH
        my $ssh_host = $host eq 'production1' ? '192.168.1.126' : '192.168.1.127';
        my $admin_ctrl = $c->controller('Admin');
        my ($resolved_host, $resolved_user, $ssh_port, $ssh_pass) = $admin_ctrl->_resolve_ssh_target($host);
        $ssh_pass ||= $ENV{SSHPASS} || '';
        unless ($ssh_pass) {
            $c->stash->{json} = { success => 0, error => "No SSH password for $host" };
            $c->forward('View::JSON');
            return;
        }
        local $ENV{SSHPASS} = $ssh_pass;
        my $cmd = "sshpass -e ssh -o StrictHostKeyChecking=no ubuntu\@$ssh_host \"docker logs --tail=$lines $service 2>&1\"";
        my $output = `$cmd 2>/dev/null` || '';
        $c->stash->{json} = { success => 1, output => $output, logs => $output };
    }
    
    $c->forward('View::JSON');
}

# ─────────────────────────────────────────────────────────────────────────────
# Main container management pages (restored from Admin.pm)
# These keep the exact URLs used in the admin dashboard and other templates.
# ─────────────────────────────────────────────────────────────────────────────

sub docker_containers :Path('/admin/docker-containers') :Args(0) {
    my ($self, $c) = @_;

    unless ($self->_can_access_docker_widget($c)) {
        $c->flash->{error_msg} = "You need to be a CSC administrator to access Docker management.";
        $c->response->redirect($c->uri_for('/user/login', { destination => $c->req->uri }));
        return;
    }

    my $docker_available = ! -f '/.dockerenv';

    $c->stash(
        template => 'admin/docker/docker_containers.tt',
        docker_available => $docker_available,
        authenticated => 1,
    );
}

sub docker_containers_working :Path('/admin/docker-containers-working') :Args(0) {
    my ($self, $c) = @_;

    unless ($self->_can_access_docker_widget($c)) {
        $c->flash->{error_msg} = "You need to be a CSC administrator to access Docker management.";
        $c->response->redirect($c->uri_for('/user/login', { destination => $c->req->uri }));
        return;
    }

    my $docker_available = ! -f '/.dockerenv';

    $c->stash(
        template => 'admin/docker/docker_containers_working.tt',
        docker_available => $docker_available,
        authenticated => 1,
    );
}

sub docker_containers_old :Path('/admin/docker-containers-old') :Args(0) {
    my ($self, $c) = @_;

    unless ($self->_can_access_docker_widget($c)) {
        $c->flash->{error_msg} = "You need to be a CSC administrator to access Docker management.";
        $c->response->redirect($c->uri_for('/user/login', { destination => $c->req->uri }));
        return;
    }

    my $docker_available = ! -f '/.dockerenv';

    $c->stash(
        template => 'admin/docker_containers_old.tt',
        docker_available => $docker_available,
        authenticated => 1,
    );
}

sub docker_containers_legacy :Path('/admin/docker-containers-legacy') :Args(0) {
    my ($self, $c) = @_;

    unless ($self->_can_access_docker_widget($c)) {
        $c->flash->{error_msg} = "You need to be a CSC administrator to access Docker management.";
        $c->response->redirect($c->uri_for('/user/login', { destination => $c->req->uri }));
        return;
    }

    my $docker_available = ! -f '/.dockerenv';

    $c->stash(
        template => 'admin/docker/docker_containers_legacy.tt',
        docker_available => $docker_available,
        authenticated => 1,
    );
}

__PACKAGE__->meta->make_immutable;

1;

# ── /admin/docker/self — returns our container ID if inside Docker ──
sub docker_self :Path('/admin/docker/self') :Args(0) {
    my ($self, $c) = @_;
    $c->response->content_type('application/json; charset=utf-8');
    my $cid = `cat /proc/1/cgroup 2>/dev/null | head -1 | grep -oP 'docker/[a-f0-9]{12}' | cut -d/ -f2` || '';
    chomp $cid;
    $c->response->body(encode_json({ container_id => $cid || '', in_docker => (-f '/.dockerenv' ? 1 : 0) }));
}

1;
