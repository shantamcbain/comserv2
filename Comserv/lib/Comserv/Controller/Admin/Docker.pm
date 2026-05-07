package Comserv::Controller::Admin::Docker;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;
use JSON qw(encode_json);

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

sub deploy :Path('/admin/docker/deploy') :Args(0) {
    my ($self, $c) = @_;

    $c->response->content_type('application/json; charset=utf-8');

    unless ($c->stash->{is_admin} && ($c->stash->{SiteName} || $c->session->{SiteName}) eq 'CSC') {
        $c->response->status(403);
        $c->response->body(encode_json({ success => 0, message => 'CSC admin only' }));
        return;
    }

    unless ($c->req->method eq 'POST') {
        $c->response->status(405);
        $c->response->body(encode_json({ success => 0, message => 'POST required' }));
        return;
    }

    my $repo_path = '/home/shanta/PycharmProjects/comserv2';
    my @log;
    my $success = 1;

    my $git_out = `cd '$repo_path' && git pull 2>&1`;
    my $git_exit = $? >> 8;
    push @log, "=== git pull ===", $git_out;
    if ($git_exit != 0) {
        $success = 0;
        push @log, "git pull failed (exit $git_exit)";
    }

    my $docker_out = `docker restart comserv-web-prod 2>&1`;
    my $docker_exit = $? >> 8;
    push @log, "=== docker restart comserv-web-prod ===", $docker_out;
    if ($docker_exit != 0) {
        $success = 0;
        push @log, "docker restart failed (exit $docker_exit)";
    }

    my $level = $success ? 'info' : 'error';
    $self->logging->log_with_details($c, $level, __FILE__, __LINE__, 'deploy',
        "Docker deploy: success=$success git_exit=$git_exit docker_exit=$docker_exit");

    $c->response->body(encode_json({
        success => $success ? 1 : 0,
        message => $success ? 'Deploy complete' : 'Deploy had errors — see log',
        log     => join("\n", @log),
    }));
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
