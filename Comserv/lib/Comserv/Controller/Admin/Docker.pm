package Comserv::Controller::Admin::Docker;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;
use JSON qw(encode_json);
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
    if ($action =~ /list|containers|restart|stop|start|up|down|logs|deploy_form|docker/) {
        unless ($self->_can_access_docker_widget($c)) {
            $c->stash->{error_msg} = "Docker container management widget is restricted. " .
                "Available only to Shanta (CSC admin) on non-production servers. " .
                "Use Daily Priorities deploy option instead.";
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

    my $on_safe_server = $server_role ne 'production1';
    my $is_shanta      = $username eq 'Shanta';
    my $is_csc_admin   = $c->stash->{is_admin} &&
                         (grep { lc($_) =~ /admin|csc/ } @$roles) &&
                         (($c->stash->{SiteName} || $c->session->{SiteName} || '') eq 'CSC');

    # ALL THREE must match before the widget is shown
    return $on_safe_server && $is_shanta && $is_csc_admin;
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
    unless ($self->_csc_admin_check($c)) {
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

    unless ($self->_csc_admin_check($c)) {
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

    unless ($self->_csc_admin_check($c)) {
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

sub close_deploy_log :Path('/admin/docker/close_deploy_log') :Args(0) {
    my ($self, $c) = @_;

    $c->response->content_type('application/json; charset=utf-8');

    unless ($self->_csc_admin_check($c)) {
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
        $c->stash->{json} = { success => 0, error => 'Docker widget restricted to Shanta (CSC admin) on non-production1 servers. Use Daily Priorities.' };
        $c->forward('View::JSON');
        return;
    }
    
    my $result = $c->model('Docker')->list_containers();
    
    $c->stash->{json} = $result;
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

sub logs :Path('/admin/docker/logs') :Args(1) {
    my ($self, $c, $service) = @_;
    
    my $lines = $c->req->param('lines') || 100;
    my $result = $c->model('Docker')->get_container_logs($service, $lines);
    
    $c->stash->{json} = $result;
    $c->forward('View::JSON');
}

__PACKAGE__->meta->make_immutable;

1;
