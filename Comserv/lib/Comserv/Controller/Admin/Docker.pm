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

    # Determine if this is a production server
    if ($hostname =~ /^prod/i || $hostname eq 'production1' || $ip eq '192.168.1.126') {
        return 'production1';
    } elsif ($hostname =~ /^prod/i || $hostname =~ /^docker/i || $ip eq '192.168.1.127') {
        return 'production2';
    }

    return 'workstation';
}

sub _can_access_docker_widget {
    my ($self, $c) = @_;

    # Triple check: 1) not production1, 2) username 'Shanta', 3) CSC admin
    my $server_role = $self->_get_current_server_role($c);
    return 0 if $server_role eq 'production1';

    my $username = $c->session->{username} || '';
    return 0 unless $username eq 'Shanta';

    my $is_admin = $c->session->{is_admin} || 0;
    return 0 unless $is_admin;

    return 1;
}

sub deploy_form :Path('/admin/docker/deploy_form') :Args(0) {
    my ($self, $c) = @_;

    my $host = $c->req->param('host') || 'workstation';
    my $container_name = $c->req->param('container_name') || '';

    $c->stash->{template}   = 'admin/docker/deploy_form.tt';
    $c->stash->{no_wrapper} = 1;
    $c->stash->{host}       = $host;
    $c->stash->{container_name} = $container_name;
}

sub deploy :Path('/admin/docker/deploy') :Args(0) {
    my ($self, $c) = @_;

    unless ($c->req->method eq 'POST') {
        $c->stash->{json} = { success => 0, stderr => 'POST required' };
        $c->forward('View::JSON');
        return;
    }

    my $host      = $c->req->param('host') || 'workstation';
    my $container = $c->req->param('container_name') || '';
    my $mode      = $c->req->param('mode') || 'pull-deploy';
    my $no_cache  = $c->req->param('no_cache') || 0;
    my $registry_url  = $c->req->param('registry_url') || '';
    my $registry_user = $c->req->param('registry_user') || '';
    my $registry_pass = $c->req->param('registry_pass') || '';
    my $image_tag     = $c->req->param('image_tag') || '';

    unless ($container) {
        $c->stash->{json} = { success => 0, error => 'container_name is required' };
        $c->forward('View::JSON');
        return;
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'deploy',
        "Deploying $container on $host (mode=$mode, no_cache=$no_cache)");

    my $deployer = Comserv::Util::DockerDeploy->new(
        logging => $self->logging,
    );

    my $result = $deployer->deploy($c, {
        host         => $host,
        container    => $container,
        mode         => $mode,
        no_cache     => $no_cache,
        registry_url => $registry_url,
        image_tag    => $image_tag,
    });

    if ($result->{success}) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'deploy',
            "Deploy started for $container on $host");
    } else {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'deploy',
            "Deploy failed for $container on $host: " . ($result->{error} || $result->{stderr} || 'unknown'));
    }

    $c->stash->{json} = $result;
    $c->forward('View::JSON');
}

sub docker_deploy_to_production :Path('/admin/docker-deploy-to-production') :Args(0) {
    my ($self, $c) = @_;

    unless ($c->req->method eq 'POST') {
        $c->stash->{json} = { success => 0, stderr => 'POST required' };
        $c->forward('View::JSON');
        return;
    }

    my $target = $c->req->param('target') || 'production1';
    my $container = $c->req->param('container_name') || 'comserv-web-prod';
    my $no_cache = $c->req->param('no_cache') || 0;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'deploy_to_production',
        "Deploying $container to $target (no_cache=$no_cache)");

    my $deployer = Comserv::Util::DockerDeploy->new(
        logging => $self->logging,
    );

    my $result = $deployer->deploy_to_production($c, {
        target     => $target,
        container  => $container,
        no_cache   => $no_cache,
    });

    $c->stash->{json} = $result;
    $c->forward('View::JSON');
}

sub deploy_status :Path('/admin/docker-deploy-status') :Args(0) {
    my ($self, $c) = @_;

    my $deployer = Comserv::Util::DockerDeploy->new(
        logging => $self->logging,
    );

    my $result = $deployer->get_deploy_status($c);

    $c->stash->{json} = $result;
    $c->forward('View::JSON');
}

# These keep the exact URLs used in the admin dashboard and other templates.
# They render the template, and the JS handles the actual data fetching via AJAX.
sub docker_containers :Path('/admin/docker-containers') :Args(0) {
    my ($self, $c) = @_;

    $c->stash->{docker_available} = 1;
    $c->stash->{template} = 'admin/docker/docker_containers.tt';
}

sub docker_containers_working :Path('/admin/docker-containers-working') :Args(0) {
    my ($self, $c) = @_;

    $c->stash->{docker_available} = 1;
    $c->stash->{template} = 'admin/docker/docker_containers_working.tt';
}

sub docker_containers_old :Path('/admin/docker-containers-old') :Args(0) {
    my ($self, $c) = @_;

    $c->stash->{docker_available} = 1;
    $c->stash->{template} = 'admin/docker_containers_old.tt';
}

sub docker_containers_legacy :Path('/admin/docker-containers-legacy') :Args(0) {
    my ($self, $c) = @_;

    $c->stash->{docker_available} = 1;
    $c->stash->{template} = 'admin/docker/docker_containers_legacy.tt';
}

sub list :Path('/admin/docker/list') :Args(0) {
    my ($self, $c) = @_;

    my $host = $c->req->param('host') || 'workstation';
    my $type = $c->req->param('type') || '';

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'list_containers',
        "Listing containers for host=$host");

    my $manager = Comserv::Util::DockerManager->new(
        logging => $self->logging,
    );

    my $result;
    if ($type eq 'volumes') {
        $result = $manager->list_volumes($c, host => $host);
    } else {
        $result = $manager->list_containers($c, host => $host);
    }

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

    my $host = $c->req->param('host') || 'workstation';

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'restart', "Restarting service: $service on $host");

    my $manager = Comserv::Util::DockerManager->new(
        logging => $self->logging,
    );

    my $result = $manager->restart($c, service => $service, host => $host);

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

    my $host = $c->req->param('host') || 'workstation';

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'stop', "Stopping service: $service on $host");

    my $manager = Comserv::Util::DockerManager->new(
        logging => $self->logging,
    );

    my $result = $manager->stop($c, $service, host => $host);

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

    my $host = $c->req->param('host') || 'workstation';

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'start', "Starting service: $service on $host");

    my $manager = Comserv::Util::DockerManager->new(
        logging => $self->logging,
    );

    my $result = $manager->start($c, $service, host => $host);

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

    my $host = $c->req->param('host') || 'workstation';

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'up', "Up-ing service: $service on $host");

    my $manager = Comserv::Util::DockerManager->new(
        logging => $self->logging,
    );

    my $result = $manager->up($c, $service, host => $host);

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

    my $host = $c->req->param('host') || 'workstation';

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'down', "Down-ing service: $service on $host");

    my $manager = Comserv::Util::DockerManager->new(
        logging => $self->logging,
    );

    my $result = $manager->down($c, $service, host => $host);

    $c->stash->{json} = $result;
    $c->forward('View::JSON');
}

sub logs :Path('/admin/docker/logs') :Args(1) {
    my ($self, $c, $service) = @_;

    my $host  = $c->req->param('host') || 'workstation';
    my $lines = $c->req->param('lines') || 100;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'logs', "Getting logs for: $service on $host");

    my $manager = Comserv::Util::DockerManager->new(
        logging => $self->logging,
    );

    my $result = $manager->logs($c, $service, host => $host, lines => $lines);

    $c->stash->{json} = $result;
    $c->forward('View::JSON');
}

sub delete :Path('/admin/docker/delete') :Args(1) {
    my ($self, $c, $service) = @_;

    unless ($c->req->method eq 'POST') {
        $c->stash->{json} = { success => 0, stderr => 'POST required' };
        $c->forward('View::JSON');
        return;
    }

    my $host = $c->req->param('host') || 'workstation';

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'delete', "Deleting container: $service on $host");

    my $manager = Comserv::Util::DockerManager->new(
        logging => $self->logging,
    );

    my $result = $manager->delete_container($c, $service, host => $host);

    $c->stash->{json} = $result;
    $c->forward('View::JSON');
}

sub rebuild :Path('/admin/docker/rebuild') :Args(1) {
    my ($self, $c, $service) = @_;

    unless ($c->req->method eq 'POST') {
        $c->stash->{json} = { success => 0, stderr => 'POST required' };
        $c->forward('View::JSON');
        return;
    }

    my $host     = $c->req->param('host') || 'workstation';
    my $mode     = $c->req->param('mode') || 'pull-deploy';
    my $no_cache = $c->req->param('no_cache') || 0;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'rebuild',
        "Rebuilding container: $service on $host (mode=$mode, no_cache=$no_cache)");

    my $deployer = Comserv::Util::DockerDeploy->new(
        logging => $self->logging,
    );

    my $result = $deployer->rebuild($c, {
        host      => $host,
        container => $service,
        mode      => $mode,
        no_cache  => $no_cache,
    });

    $c->stash->{json} = $result;
    $c->forward('View::JSON');
}

sub prune :Path('/admin/docker/prune') :Args(0) {
    my ($self, $c) = @_;

    unless ($c->req->method eq 'POST') {
        $c->stash->{json} = { success => 0, stderr => 'POST required' };
        $c->forward('View::JSON');
        return;
    }

    my $host   = $c->req->param('host') || 'workstation';
    my $action = $c->req->param('action') || 'df';

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'prune',
        "Docker disk action: $action on $host");

    my $manager = Comserv::Util::DockerManager->new(
        logging => $self->logging,
    );

    my $result = $manager->prune($c, host => $host, action => $action);

    $c->stash->{json} = $result;
    $c->forward('View::JSON');
}

sub restore_backup :Path('/admin/docker/restore_backup') :Args(0) {
    my ($self, $c) = @_;

    unless ($c->req->method eq 'POST') {
        $c->stash->{json} = { success => 0, stderr => 'POST required' };
        $c->forward('View::JSON');
        return;
    }

    my $host        = $c->req->param('host') || 'workstation';
    my $backup_name = $c->req->param('backup_name') || '';

    unless ($backup_name) {
        $c->stash->{json} = { success => 0, error => 'backup_name is required' };
        $c->forward('View::JSON');
        return;
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'restore_backup',
        "Restoring backup container: $backup_name on $host");

    my $deployer = Comserv::Util::DockerDeploy->new(
        logging => $self->logging,
    );

    my $result = $deployer->restore_backup($c, {
        host        => $host,
        backup_name => $backup_name,
    });

    $c->stash->{json} = $result;
    $c->forward('View::JSON');
}

sub deploy_logs :Path('/admin/docker/deploy-logs') :Args(1) {
    my ($self, $c, $container_name) = @_;

    my $file = $c->req->param('file') || '';

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'deploy_logs',
        "Fetching deploy logs for: $container_name" . ($file ? " (file: $file)" : ''));

    my $deployer = Comserv::Util::DockerDeploy->new(
        logging => $self->logging,
    );

    my $result = $deployer->get_deploy_logs($c, $container_name, $file);

    $c->stash->{json} = $result;
    $c->forward('View::JSON');
}

sub docker_self :Path('/admin/docker/self') :Args(0) {
    my ($self, $c) = @_;

    my $container_id = '';
    if (open my $fh, '<', '/proc/1/cgroup') {
        while (<$fh>) {
            if (/docker[\/-]([a-f0-9]{64})/) {
                $container_id = substr($1, 0, 12);
                last;
            }
        }
        close $fh;
    }
    # Fallback: check hostname
    unless ($container_id) {
        my $hostname = `hostname 2>/dev/null` || '';
        chomp $hostname;
        if ($hostname =~ /^([a-f0-9]{12})$/) {
            $container_id = $hostname;
        }
    }

    $c->stash->{json} = { container_id => $container_id };
    $c->forward('View::JSON');
}

__PACKAGE__->meta->make_immutable;

1;