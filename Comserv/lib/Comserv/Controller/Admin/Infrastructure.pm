package Comserv::Controller::Admin::Infrastructure;

use Moose;
use namespace::autoclean;
use JSON::MaybeXS;
use Try::Tiny;
use File::Slurp qw(read_file write_file);
use File::Spec;
use File::Path qw(make_path);
use IPC::Run3;
use DateTime;
use Comserv::Util::Logging;

BEGIN { extends 'Comserv::Controller::Base'; }

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

sub begin :Private {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'begin', 
        "User accessing path: " . $c->req->uri);
    
    # Skip role check for API endpoints - just need valid session
    my $path = $c->req->path;
    if ($path =~ m{/infrastructure/(cluster/status|monitoring/status|kubectl|deploy)}) {
        # Just check if user is logged in
        return if $c->session->{username};
    }
    
    my $roles = $c->session->{roles} || [];
    
    if (ref $roles ne 'ARRAY') {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'begin', 
            "Invalid or undefined roles in session");
        $c->stash->{error_msg} = "Session expired or invalid. Please log in again.";
        $c->res->redirect($c->uri_for('/user/login'));
        $c->detach;
    }
    
    unless (grep { $_ eq 'admin' || $_ eq 'developer' } @$roles) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'begin', 
            "Unauthorized access attempt by user: " . ($c->session->{username} || 'Guest'));
        $c->stash->{error_msg} = "Unauthorized access. You do not have permission to view this page.";
        $c->res->redirect($c->uri_for('/'));
        $c->detach;
    }
}

sub index :Path('/admin/infrastructure') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', 
        'Loading infrastructure management dashboard');
    
    my @cluster_status = (
        {
            name => 'comserv-k8s-cluster',
            host => '192.168.1.50',
            kubeconfig_path => '',
            added_at => '2026-02-10T17:05:12',
            added_by => 'System',
            status => 'unknown',
            monitoring_deployed => 0,
            last_checked => DateTime->now->iso8601
        }
    );
    
    $c->stash(
        clusters => \@cluster_status,
        env => $ENV{CATALYST_ENV} || 'development',
        template => 'admin/infrastructure/index.tt'
    );
}

sub cluster_list :Path('/admin/infrastructure/clusters') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'cluster_list', 
        'Fetching cluster list');
    
    my $config = $self->_load_infrastructure_config($c);
    
    $c->stash->{json} = {
        success => 1,
        clusters => $config->{clusters} || {}
    };
    $c->forward('View::JSON');
}

sub cluster_add :Path('/admin/infrastructure/cluster/add') :Args(0) {
    my ($self, $c) = @_;
    
    unless ($c->req->method eq 'POST') {
        $c->stash->{json} = { success => 0, error => 'POST required' };
        $c->forward('View::JSON');
        return;
    }
    
    my $params = $c->req->body_parameters;
    my $cluster_name = $params->{name};
    my $host = $params->{host};
    my $kubeconfig_path = $params->{kubeconfig_path};
    
    unless ($cluster_name && $host) {
        $c->stash->{json} = { success => 0, error => 'Name and host required' };
        $c->forward('View::JSON');
        return;
    }
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'cluster_add', 
        "Adding cluster: $cluster_name at $host");
    
    try {
        my $config = $self->_load_infrastructure_config($c);
        $config->{clusters}{$cluster_name} = {
            host => $host,
            kubeconfig_path => $kubeconfig_path,
            added_at => DateTime->now->iso8601,
            added_by => $c->session->{username}
        };
        
        $self->_save_infrastructure_config($c, $config);
        
        $c->stash->{json} = {
            success => 1,
            message => "Cluster $cluster_name added successfully"
        };
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'cluster_add', 
            "Error adding cluster: $_");
        $c->stash->{json} = { success => 0, error => "Error adding cluster: $_" };
    };
    
    $c->forward('View::JSON');
}

sub deploy_monitoring :Path('/admin/infrastructure/deploy/monitoring') :Args(1) {
    my ($self, $c, $cluster_name) = @_;
    
    unless ($c->req->method eq 'POST') {
        $c->stash->{json} = { success => 0, error => 'POST required' };
        $c->forward('View::JSON');
        return;
    }
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'deploy_monitoring', 
        "Deploying monitoring stack to cluster: $cluster_name");
    
    try {
        my $config = $self->_load_infrastructure_config($c);
        my $cluster = $config->{clusters}{$cluster_name};
        
        unless ($cluster) {
            $c->stash->{json} = { success => 0, error => "Cluster $cluster_name not found" };
            $c->forward('View::JSON');
            return;
        }
        
        my $result = $self->_deploy_monitoring_stack($c, $cluster_name, $cluster);
        
        if ($result->{success}) {
            $cluster->{monitoring_deployed_at} = DateTime->now->iso8601;
            $cluster->{monitoring_deployed_by} = $c->session->{username};
            $self->_save_infrastructure_config($c, $config);
        }
        
        $c->stash->{json} = $result;
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'deploy_monitoring', 
            "Error deploying monitoring: $_");
        $c->stash->{json} = { success => 0, error => "Error deploying monitoring: $_" };
    };
    
    $c->forward('View::JSON');
}

sub cluster_status :Path('/admin/infrastructure/cluster/status') :Args(1) {
    my ($self, $c, $cluster_name) = @_;
    
    my $config = $self->_load_infrastructure_config($c);
    my $cluster = $config->{clusters}{$cluster_name};
    
    unless ($cluster) {
        $c->stash->{json} = { success => 0, error => 'Cluster not found' };
        $c->forward('View::JSON');
        return;
    }
    
    my $status = $self->_check_cluster_status($c, $cluster);
    
    $c->stash->{json} = {
        success => 1,
        cluster => $cluster_name,
        connected => $status->{connected},
        message => $status->{message},
        monitoring_deployed => $status->{monitoring_deployed}
    };
    $c->forward('View::JSON');
}

sub monitoring_status :Path('/admin/infrastructure/monitoring/status') :Args(1) {
    my ($self, $c, $cluster_name) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'monitoring_status', 
        "Checking monitoring status for cluster: $cluster_name");
    
    try {
        my $config = $self->_load_infrastructure_config($c);
        my $cluster = $config->{clusters}{$cluster_name};
        
        unless ($cluster) {
            $c->stash->{json} = { success => 0, error => "Cluster $cluster_name not found" };
            $c->forward('View::JSON');
            return;
        }
        
        my $status = $self->_check_monitoring_status($c, $cluster);
        
        $c->stash->{json} = {
            success => 1,
            cluster => $cluster_name,
            %$status
        };
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'monitoring_status', 
            "Error checking monitoring status: $_");
        $c->stash->{json} = { success => 0, error => "Error checking status: $_" };
    };
    
    $c->forward('View::JSON');
}

sub exec_kubectl :Path('/admin/infrastructure/kubectl') :Args(0) {
    my ($self, $c) = @_;
    
    unless ($c->req->method eq 'POST') {
        $c->stash->{json} = { success => 0, error => 'POST required' };
        $c->forward('View::JSON');
        return;
    }
    
    my $params = $c->req->body_parameters;
    my $cluster_name = $params->{cluster};
    my $command = $params->{command};
    
    unless ($cluster_name && $command) {
        $c->stash->{json} = { success => 0, error => 'Cluster and command required' };
        $c->forward('View::JSON');
        return;
    }
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'exec_kubectl', 
        "Executing kubectl command on cluster $cluster_name: $command");
    
    try {
        my $config = $self->_load_infrastructure_config($c);
        my $cluster = $config->{clusters}{$cluster_name};
        
        unless ($cluster) {
            $c->stash->{json} = { success => 0, error => "Cluster $cluster_name not found" };
            $c->forward('View::JSON');
            return;
        }
        
        my $result = $self->_run_kubectl($c, $cluster, $command);
        
        $c->stash->{json} = {
            success => $result->{exit_code} == 0 ? 1 : 0,
            output => $result->{stdout},
            error => $result->{stderr},
            exit_code => $result->{exit_code}
        };
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'exec_kubectl', 
            "Error executing kubectl: $_");
        $c->stash->{json} = { success => 0, error => "Error executing kubectl: $_" };
    };
    
    $c->forward('View::JSON');
}

sub _load_infrastructure_config {
    my ($self, $c) = @_;
    
    my $config_file = $c->path_to('config', 'infrastructure', 'clusters.json');
    
    if (-e $config_file) {
        try {
            my $json = read_file($config_file, { binmode => ':utf8' });
            return decode_json($json);
        } catch {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_load_infrastructure_config', 
                "Error loading config: $_");
        };
    }
    
    return { clusters => {} };
}

sub _save_infrastructure_config {
    my ($self, $c, $config) = @_;
    
    my $config_dir = $c->path_to('config', 'infrastructure');
    make_path($config_dir) unless -d $config_dir;
    
    my $config_file = $c->path_to('config', 'infrastructure', 'clusters.json');
    my $json = encode_json($config);
    write_file($config_file, { binmode => ':utf8' }, $json);
    
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_save_infrastructure_config', 
        "Config saved to $config_file");
}

sub _run_kubectl {
    my ($self, $c, $cluster, $command) = @_;
    
    my $kubeconfig = $cluster->{kubeconfig_path} || $ENV{HOME} . '/.kube/config';
    
    my @cmd = ('kubectl');
    push @cmd, '--kubeconfig', $kubeconfig if $kubeconfig;
    push @cmd, split(/\s+/, $command);
    
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_run_kubectl', 
        "Running: " . join(' ', @cmd));
    
    my ($stdout, $stderr);
    run3 \@cmd, \undef, \$stdout, \$stderr;
    my $exit_code = $? >> 8;
    
    return {
        stdout => $stdout || '',
        stderr => $stderr || '',
        exit_code => $exit_code
    };
}

sub _check_cluster_status {
    my ($self, $c, $cluster) = @_;
    
    my $result = $self->_run_kubectl($c, $cluster, 'cluster-info');
    
    return {
        connected => $result->{exit_code} == 0,
        message => $result->{exit_code} == 0 ? 'Connected' : 'Connection failed',
        monitoring_deployed => $self->_check_monitoring_deployed($c, $cluster)
    };
}

sub _check_monitoring_deployed {
    my ($self, $c, $cluster) = @_;
    
    my $result = $self->_run_kubectl($c, $cluster, 'get namespace monitoring');
    
    return $result->{exit_code} == 0;
}

sub _check_monitoring_status {
    my ($self, $c, $cluster) = @_;
    
    my $pods = $self->_run_kubectl($c, $cluster, 'get pods -n monitoring -o json');
    
    if ($pods->{exit_code} == 0) {
        try {
            my $data = decode_json($pods->{stdout});
            my @items = @{$data->{items} || []};
            
            my $total = scalar @items;
            my $running = grep { $_->{status}{phase} eq 'Running' } @items;
            
            return {
                deployed => 1,
                total_pods => $total,
                running_pods => $running,
                health => $running == $total ? 'healthy' : 'degraded',
                pods => \@items
            };
        } catch {
            return { deployed => 0, error => "Error parsing pod data: $_" };
        };
    }
    
    return { deployed => 0, message => 'Monitoring namespace not found' };
}

sub _deploy_monitoring_stack {
    my ($self, $c, $cluster_name, $cluster) = @_;
    
    my $monitoring_dir = $c->path_to('infrastructure', 'k8s-monitoring');
    
    unless (-d $monitoring_dir) {
        return {
            success => 0,
            error => "Monitoring deployment files not found at $monitoring_dir"
        };
    }
    
    my @steps;
    
    push @steps, {
        name => 'Add Helm repository',
        command => 'repo add prometheus-community https://prometheus-community.github.io/helm-charts',
        helm => 1
    };
    
    push @steps, {
        name => 'Update Helm repositories',
        command => 'repo update',
        helm => 1
    };
    
    push @steps, {
        name => 'Create monitoring namespace',
        command => 'create namespace monitoring',
        ignore_error => 1
    };
    
    push @steps, {
        name => 'Install Prometheus stack',
        command => "install kube-prometheus-stack prometheus-community/kube-prometheus-stack --namespace monitoring --values $monitoring_dir/prometheus-stack-values.yaml --timeout 10m",
        helm => 1,
        timeout => 600
    };
    
    push @steps, {
        name => 'Deploy Kubernetes Dashboard',
        command => "apply -f $monitoring_dir/kubernetes-dashboard.yaml"
    };
    
    my @results;
    foreach my $step (@steps) {
        my $cmd = $step->{helm} ? 'helm' : 'kubectl';
        my $result;
        
        if ($step->{helm}) {
            my @cmd_array = ('helm', split(/\s+/, $step->{command}));
            my ($stdout, $stderr);
            run3 \@cmd_array, \undef, \$stdout, \$stderr;
            my $exit_code = $? >> 8;
            $result = {
                stdout => $stdout,
                stderr => $stderr,
                exit_code => $exit_code
            };
        } else {
            $result = $self->_run_kubectl($c, $cluster, $step->{command});
        }
        
        push @results, {
            step => $step->{name},
            success => $result->{exit_code} == 0 || $step->{ignore_error},
            output => $result->{stdout},
            error => $result->{stderr}
        };
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_deploy_monitoring_stack', 
            "Step '$step->{name}': " . ($result->{exit_code} == 0 ? 'SUCCESS' : 'FAILED'));
        
        last if $result->{exit_code} != 0 && !$step->{ignore_error};
    }
    
    my $all_success = !grep { !$_->{success} } @results;
    
    return {
        success => $all_success,
        message => $all_success ? 'Monitoring stack deployed successfully' : 'Deployment encountered errors',
        steps => \@results
    };
}

__PACKAGE__->meta->make_immutable;

1;
