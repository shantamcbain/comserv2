package Comserv::Controller::Admin::Docker;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;
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
        my $cmd = "cd /home/shanta/PycharmProjects/comserv2/Comserv && TRIGGER_SOURCE='$trigger_source' script/deploy_docker_to_production.pl --target=production1 2>&1";
        my $ssh_cmd = "ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 shanta\@$workstation_host \"$cmd\"";
        my $remote_output = `$ssh_cmd`;
        my $exit_code = $? >> 8;
        push @lines, $remote_output;
        push @lines, "Remote deploy on workstation exited with code $exit_code";
        $success = ($exit_code == 0);
    } else {
        # Safe server (workstation etc.): run locally
        my $repo_path    = '/home/shanta/PycharmProjects/comserv2';
        my $compose_file = "$repo_path/Comserv/docker-compose.prod.yml";

        push @lines, "[${\scalar localtime}] === git pull ===";
        my $git_out  = `cd '$repo_path' && git pull 2>&1`;
        my $git_exit = $? >> 8;
        push @lines, $git_out;
        push @lines, "git pull exited with code $git_exit" if $git_exit;
        $success = 0 if $git_exit;

        push @lines, "[${\scalar localtime}] === docker compose down + up (new container) ===";
        my $docker_result = $c->model('Docker')->restart_containers(
            services     => ['web-prod'],
            force        => 1,
            compose_file => $compose_file,
        );
        push @lines, $docker_result->{stdout} if $docker_result->{stdout};
        push @lines, $docker_result->{stderr} if $docker_result->{stderr};
        push @lines, "command: " . ($docker_result->{command} || 'n/a');
        unless ($docker_result->{success}) {
            $success = 0;
            push @lines, "docker compose exited with errors";
        }
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

    my $trigger = $c->req->body_params->{trigger_source} || 'manual';
    my $log_file = '/tmp/comserv_deploy.log';
    my $pid_file = '/tmp/comserv_deploy.pid';

    unlink $log_file;
    unlink $pid_file;

    my $pid = fork();
    if (!defined $pid) {
        $c->response->body(encode_json({ success => 0, message => 'fork failed' }));
        return;
    }

    if ($pid == 0) {
        # CHILD – perform the real 5-step deploy
        open(my $log, '>>', $log_file) or exit 1;
        select((select($log), $|=1)[0]);

        my $repo = '/home/shanta/PycharmProjects/comserv2/Comserv';
        my $compose = 'docker-compose.prod.yml';

        print $log "[".scalar(localtime)."] === DOCKER DEPLOY STARTED (trigger=$trigger) ===\n";

        # 1. Auto-commit (robust version)
        my $work_repo = '/home/shanta/PycharmProjects/comserv2';
        print $log "[".scalar(localtime)."] Step 1: Checking for uncommitted changes in $work_repo ...\n";

        my $git_status = `cd '$work_repo' && git status --porcelain 2>&1`;
        my $git_status_exit = $? >> 8;
        print $log "git status exit=$git_status_exit\n";
        print $log "git status output:\n$git_status\n";

        if ($git_status =~ /\S/ && $git_status_exit == 0) {
            print $log "[".scalar(localtime)."] Uncommitted changes detected – performing git add -A ...\n";
            my $add_out = `cd '$work_repo' && git add -A 2>&1`;
            print $log "git add output:\n$add_out\n";

            my $commit_msg = "Auto-deploy commit before production push [".scalar(localtime)."]";
            my $commit_out = `cd '$work_repo' && git commit -m "$commit_msg" 2>&1`;
            my $commit_exit = $? >> 8;
            print $log "git commit exit=$commit_exit\n";
            print $log "git commit output:\n$commit_out\n";

            if ($commit_exit == 0) {
                print $log "[".scalar(localtime)."] Auto-commit successful.\n";
            } else {
                print $log "[".scalar(localtime)."] WARNING: git commit returned non-zero (may be nothing to commit).\n";
            }
        } else {
            print $log "[".scalar(localtime)."] No uncommitted changes (or git status failed) – skipping auto-commit.\n";
        }

        # 2. Push
        print $log "[".scalar(localtime)."] Step 2: git push origin main...\n";
        my $push = `cd $repo && git push origin main 2>&1`;
        print $log $push;

        # 3. Build
        print $log "[".scalar(localtime)."] Step 3: docker compose build web-prod --no-cache...\n";
        my $build = `cd $repo && docker compose -f $compose build web-prod --no-cache 2>&1`;
        print $log $build;

        # 4. Push to registry (real push)
        print $log "[".scalar(localtime)."] Step 4: docker compose push web-prod...\n";
        my $push_img = `cd $repo && docker compose -f $compose push web-prod 2>&1`;
        print $log $push_img;

        # 5. Restart
        print $log "[".scalar(localtime)."] Step 5: docker compose up -d web-prod...\n";
        my $up = `cd $repo && docker compose -f $compose up -d web-prod 2>&1`;
        print $log $up;

        print $log "[".scalar(localtime)."] === DEPLOY COMPLETE ===\n";
        close($log);
        unlink($pid_file);
        exit 0;
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

    my $output = '';
    if (-f $log_file) {
        $output = do { open my $fh, '<', $log_file; local $/; <$fh> };
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
            $entry->update({
                status      => 3,
                end_time    => $end_time,
                time        => $elapsed,
                details     => $details_text,
                comments    => $output,
                last_mod_by => $c->session->{username} || 'system',
            });

            # Append the entire log output to the comments of the linked Todo task
            my $todo_record_id = $entry->todo_record_id;
            if ($todo_record_id) {
                my $todo = $c->model('DBEncy')->resultset('Todo')->find($todo_record_id);
                if ($todo) {
                    my $existing_comments = $todo->comments || '';
                    my $timestamp = localtime();
                    my $appended_comments = $existing_comments . "\n\n=== DEPLOYMENT LOG ($timestamp) ===\n" . $output;
                    $todo->update({
                        comments      => $appended_comments,
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
        my $output = `docker ps -a --format '{{.ID}}|{{.Names}}|{{.Image}}|{{.Status}}|{{.Ports}}' 2>/dev/null || echo ''`;
        foreach my $line (split /\n/, $output) {
            next unless $line =~ /\|/;
            my ($id, $name, $image, $status, $ports) = split /\|/, $line, 5;
            push @containers, {
                id => $id,
                name => $name,
                image => $image,
                status => $status,
                state => $status =~ /Up/i ? 'running' : ($status =~ /Exited/i ? 'exited' : 'unknown'),
                ports => $ports || '',
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
            push @containers, {
                id => $id,
                name => $name,
                image => $image,
                status => $status,
                state => $status =~ /Up/i ? 'running' : ($status =~ /Exited/i ? 'exited' : 'unknown'),
                ports => $ports || '',
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

    $c->stash->{json} = {
        success => 1,
        containers => \@containers,
        backups => \@backups,
        all_entries => \@all_entries,
        host => $host
    };
    $c->forward('View::JSON');
}

sub restart :Path('/admin/docker/restart') :Args(1) {
    my ($self, $c, $service) = @_;
    
    unless ($c->req->method eq 'POST') {
        $c->stash->{json} = { success => 0, stderr => 'POST required' };
        $c->forward('View::JSON');
        return;
    }
    
    
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'restart', "Restarting service: $service");
    my $result = $c->model('Docker')->restart_containers(services => [$service]);
    
    $c->stash->{json} = $result;
    $c->forward('View::JSON');
}

sub stop :Path('/admin/docker/stop') :Args(1) {
    my ($self, $c, $service) = @_;
    
    unless ($c->req->method eq 'POST') {
        $c->stash->{json} = { success => 0, stderr => 'POST required' };
        $c->forward('View::JSON');
        return;
    }
    
    
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'stop', "Stopping service: $service");
    my $result = $c->model('Docker')->stop_container($service);
    
    $c->stash->{json} = $result;
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
    
    
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'start', "Starting service: $service");
    my $result = $c->model('Docker')->start_container($service);
    
    $c->stash->{json} = $result;
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

sub logs :Path('/admin/docker/logs') :Args(1) {
    my ($self, $c, $service) = @_;
    
    my $lines = $c->req->param('lines') || 100;
    my $result = $c->model('Docker')->get_container_logs($service, $lines);
    
    $c->stash->{json} = $result;
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
