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
    return if $action eq 'deploy';

    my $env = $ENV{CATALYST_ENV} || 'development';
    unless ($env eq 'development') {
        $c->stash->{error_msg} = "Docker management is only available in development environment.";
        $c->res->redirect($c->uri_for('/admin/infrastructure'));
        $c->detach;
    }
}

sub _csc_admin_check {
    my ($self, $c) = @_;
    return $c->stash->{is_admin}
        && (($c->stash->{SiteName} || $c->session->{SiteName} || '') eq 'CSC');
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

    my $log_id;
    eval {
        my %log_fields = (
            abstract        => $title,
            username        => $username,
            sitename        => $sitename,
            start_date      => $today,
            start_time      => $now_time,
            end_time        => $now_time,
            time            => '00:00:00',
            status          => 1,
            priority        => 3,
            group_of_poster => 'admin',
            last_mod_by     => $username,
            details         => 'Deploy in progress…',
        );
        $log_fields{todo_record_id} = $todo_record_id if $todo_record_id;
        my $entry = $c->model('DBEncy')->resultset('Log')->create(\%log_fields);
        $log_id = $entry->id;
    };

    my $repo_path = '/home/shanta/PycharmProjects/comserv2';
    my @lines;
    my $success = 1;

    my $t0 = time();
    push @lines, "[${\scalar localtime}] === git pull ===";
    my $git_out   = `cd '$repo_path' && git pull 2>&1`;
    my $git_exit  = $? >> 8;
    push @lines, $git_out;
    push @lines, "git pull exited with code $git_exit" if $git_exit;
    $success = 0 if $git_exit;

    push @lines, "[${\scalar localtime}] === docker restart comserv-web-prod ===";
    my $docker_out  = `docker restart comserv-web-prod 2>&1`;
    my $docker_exit = $? >> 8;
    push @lines, $docker_out;
    push @lines, "docker restart exited with code $docker_exit" if $docker_exit;
    $success = 0 if $docker_exit;

    my $elapsed = time() - $t0;
    push @lines, "[${\scalar localtime}] Done in ${elapsed}s — " . ($success ? 'SUCCESS' : 'ERRORS DETECTED');

    my $output = join("\n", @lines);

    $self->logging->log_with_details($c, $success ? 'info' : 'error', __FILE__, __LINE__, 'deploy',
        "Docker deploy: success=$success elapsed=${elapsed}s log_id=" . ($log_id // 'n/a'));

    $c->response->body(encode_json({
        success => $success ? 1 : 0,
        message => $success ? 'Deploy complete' : 'Deploy had errors',
        log_id  => $log_id,
        output  => $output,
        title   => $title,
    }));
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

            $entry->update({
                status      => 3,
                end_time    => $end_time,
                time        => $elapsed,
                details     => $output,
                comments    => $notes,
                last_mod_by => $c->session->{username} || 'system',
            });
        }
    };

    $c->response->body(encode_json({ success => $@ ? 0 : 1, message => $@ ? "Error: $@" : 'Log closed' }));
}

sub list :Path('/admin/docker/list') :Args(0) {
    my ($self, $c) = @_;
    
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
