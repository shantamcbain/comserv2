package Comserv::Controller::Admin::EnvironmentVariables;

use Moose;
use namespace::autoclean;
use Try::Tiny;
use JSON;
use Comserv::Util::Logging;
use Comserv::Util::EnvFileManager;
use Comserv::Util::DockerManager;

BEGIN { extends 'Catalyst::Controller'; }

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

has 'env_manager' => (
    is => 'ro',
    default => sub { Comserv::Util::EnvFileManager->new }
);

has 'docker_manager' => (
    is => 'ro',
    default => sub { Comserv::Util::DockerManager->new }
);

sub begin : Private {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'begin',
        'EnvironmentVariables controller accessed');
    
    unless ($c->check_user_roles('admin')) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'begin',
            'Unauthorized access attempt to environment variables');
        $c->response->status(403);
        $c->stash(template => 'error/forbidden.tt');
        return;
    }
}

sub list : Path('') : Args(0) {
    my ($self, $c) = @_;
    
    try {
        my $schema = $c->model('Schema')->schema;
        my @variables = $schema->resultset('EnvVariable')->search(
            {},
            { order_by => 'key' }
        )->all();
        
        my @var_list;
        foreach my $var (@variables) {
            push @var_list, {
                id => $var->id,
                key => $var->key,
                value => $var->display_value,
                var_type => $var->var_type,
                is_secret => $var->is_secret,
                is_editable => $var->is_editable,
                editable_by_roles => $var->editable_by_roles,
                description => $var->description,
                created_at => $var->created_at,
                updated_at => $var->updated_at,
            };
        }
        
        $c->stash(
            env_variables => \@var_list,
            template => 'admin/environment_variables/list.tt'
        );
        
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'list', "Error listing variables: $_");
        $c->stash(error_message => "Error loading environment variables: $_");
    };
}

sub create : Path('create') : Args(0) {
    my ($self, $c) = @_;
    
    if ($c->req->method eq 'GET') {
        $c->stash(
            variable => {
                id => undef,
                key => '',
                value => '',
                var_type => 'string',
                is_secret => 0,
                description => '',
            },
            var_types => [qw(string int bool json list)],
            is_edit => 0,
            template => 'admin/environment_variables/edit.tt'
        );
        return;
    }
    
    my $key = $c->req->param('key');
    my $value = $c->req->param('value');
    my $var_type = $c->req->param('var_type') || 'string';
    my $is_secret = $c->req->param('is_secret') ? 1 : 0;
    my $description = $c->req->param('description');
    my $affected_services = $c->req->param('affected_services');
    
    unless ($key && $key =~ /^[A-Za-z_][A-Za-z0-9_]*$/) {
        $c->stash(error_message => 'Invalid variable name format');
        return;
    }
    
    try {
        my $schema = $c->model('Schema')->schema;
        
        my $existing = $schema->resultset('EnvVariable')->find({ key => $key });
        if ($existing) {
            $c->stash(error_message => "Variable '$key' already exists");
            return;
        }
        
        my $var = $schema->resultset('EnvVariable')->create({
            key => $key,
            value => $value,
            var_type => $var_type,
            is_secret => $is_secret,
            description => $description,
            affected_services => $affected_services ? JSON::to_json([ split /,/, $affected_services ]) : undef,
            created_by => $c->session->{user_id},
            updated_by => $c->session->{user_id},
        });
        
        $self->_log_audit($c, $var->id, 'create', undef, $value, 'success');
        
        $c->response->redirect($c->uri_for('/admin/environment_variables'));
        
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create', "Error creating variable: $_");
        $c->stash(error_message => "Error creating variable: $_");
    };
}

sub edit : Path('edit') : Args(1) {
    my ($self, $c, $var_id) = @_;
    
    try {
        my $schema = $c->model('Schema')->schema;
        my $var = $schema->resultset('EnvVariable')->find($var_id);
        
        unless ($var) {
            $c->response->status(404);
            $c->stash(error_message => 'Variable not found');
            return;
        }
        
        unless ($var->is_user_editable([$c->session->{roles} || 'user'])) {
            $c->response->status(403);
            $c->stash(error_message => 'You do not have permission to edit this variable');
            return;
        }
        
        if ($c->req->method eq 'GET') {
            my $services = [];
            if ($var->affected_services) {
                $services = JSON::from_json($var->affected_services);
            }
            
            $c->stash(
                variable => $var,
                affected_services => join(',', @$services),
                var_types => [qw(string int bool json list)],
                is_edit => 1,
                template => 'admin/environment_variables/edit.tt'
            );
            return;
        }
        
        my $old_value = $var->value;
        my $new_value = $c->req->param('value');
        my $var_type = $c->req->param('var_type') || $var->var_type;
        my $is_secret = $c->req->param('is_secret') ? 1 : 0;
        my $description = $c->req->param('description');
        my $affected_services = $c->req->param('affected_services');
        my $dry_run = $c->req->param('dry_run') ? 1 : 0;
        my $force_restart = $c->req->param('force_restart') ? 1 : 0;
        
        if ($dry_run) {
            my $preview = $self->_preview_changes($c, { $var->key => $new_value });
            $c->stash(
                dry_run_preview => $preview,
                message => 'Dry run preview (no changes applied)'
            );
            return;
        }
        
        $var->update({
            value => $new_value,
            var_type => $var_type,
            is_secret => $is_secret,
            description => $description,
            affected_services => $affected_services ? JSON::to_json([ split /,/, $affected_services ]) : undef,
            updated_by => $c->session->{user_id},
        });
        
        my $restart_result = $self->_handle_docker_restart(
            $c, $var_id, $old_value, $new_value,
            { force => $force_restart }
        );
        
        if ($restart_result->{success}) {
            $self->_log_audit($c, $var_id, 'update', $old_value, $new_value, 'success');
            $c->response->redirect($c->uri_for('/admin/environment_variables'));
        } else {
            $var->update({ value => $old_value });
            $self->_log_audit($c, $var_id, 'update', $old_value, $new_value, 'failed',
                { error => $restart_result->{error} });
            $c->stash(error_message => "Update failed: " . $restart_result->{error});
        }
        
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'edit', "Error updating variable: $_");
        $c->stash(error_message => "Error updating variable: $_");
    };
}

sub delete : Path('delete') : Args(1) {
    my ($self, $c, $var_id) = @_;
    
    try {
        my $schema = $c->model('Schema')->schema;
        my $var = $schema->resultset('EnvVariable')->find($var_id);
        
        unless ($var) {
            $c->response->status(404);
            $c->stash(error_message => 'Variable not found');
            return;
        }
        
        unless ($var->is_editable) {
            $c->response->status(403);
            $c->stash(error_message => 'This variable cannot be deleted');
            return;
        }
        
        my $key = $var->key;
        my $old_value = $var->value;
        
        $var->delete();
        $self->_log_audit($c, $var_id, 'delete', $old_value, undef, 'success');
        
        $c->response->redirect($c->uri_for('/admin/environment_variables'));
        
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'delete', "Error deleting variable: $_");
        $c->stash(error_message => "Error deleting variable: $_");
    };
}

sub export : Path('export') : Args(0) {
    my ($self, $c) = @_;
    
    try {
        my $schema = $c->model('Schema')->schema;
        my @variables = $schema->resultset('EnvVariable')->search(
            { is_editable => 1 },
            { order_by => 'key' }
        )->all();
        
        my %env_vars;
        foreach my $var (@variables) {
            $env_vars{$var->key} = $var->value;
        }
        
        my $content = $self->env_manager->_generate_env_content(\%env_vars);
        
        $c->response->content_type('text/plain');
        $c->response->header('Content-Disposition' => 'attachment; filename=.env');
        $c->response->body($content);
        
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'export', "Error exporting variables: $_");
        $c->stash(error_message => "Error exporting variables: $_");
    };
}

sub audit_log : Path('audit_log') : Args(0) {
    my ($self, $c) = @_;
    
    try {
        my $schema = $c->model('Schema')->schema;
        my $page = $c->req->param('page') || 1;
        my $per_page = 50;
        
        my $rs = $schema->resultset('EnvVariableAuditLog')->search(
            {},
            {
                order_by => { -desc => 'created_at' },
                page => $page,
                rows => $per_page,
            }
        );
        
        my @logs;
        while (my $log = $rs->next) {
            push @logs, {
                id => $log->id,
                variable_key => $log->env_variable->key,
                action => $log->action,
                status => $log->status,
                user => $log->user ? $log->user->username : 'System',
                ip_address => $log->ip_address,
                old_value => $log->masked_old_value,
                new_value => $log->masked_new_value,
                created_at => $log->created_at,
            };
        }
        
        $c->stash(
            audit_logs => \@logs,
            current_page => $page,
            total_pages => $rs->pager->last_page,
            template => 'admin/environment_variables/audit_log.tt'
        );
        
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'audit_log', "Error loading audit log: $_");
        $c->stash(error_message => "Error loading audit log: $_");
    };
}

sub _handle_docker_restart {
    my ($self, $c, $var_id, $old_value, $new_value, $opts) = @_;
    
    my $schema = $c->model('Schema')->schema;
    my $var = $schema->resultset('EnvVariable')->find($var_id);
    return { success => 1 } unless $var->affected_services;
    
    my $services = JSON::from_json($var->affected_services);
    
    sleep 3;
    
    my $restart_result = $self->docker_manager->restart_containers(
        services => $services,
        force => $opts->{force}
    );
    
    if (!$restart_result->{success}) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_handle_docker_restart',
            "Docker restart failed, rolling back");
        
        $var->update({ value => $old_value });
        $self->env_manager->write_env_file({ $var->key => $old_value });
        
        return {
            success => 0,
            error => "Container restart failed. Changes rolled back: " . ($restart_result->{stderr} || 'unknown error')
        };
    }
    
    return { success => 1, output => $restart_result->{stdout} };
}

sub _log_audit {
    my ($self, $c, $var_id, $action, $old_value, $new_value, $status, $extra) = @_;
    
    my $schema = $c->model('Schema')->schema;
    
    $extra ||= {};
    
    my $log_data = {
        env_variable_id => $var_id,
        user_id => $c->session->{user_id},
        action => $action,
        old_value => $old_value,
        new_value => $new_value,
        status => $status,
        ip_address => $c->req->address,
        error_message => $extra->{error},
    };
    
    $schema->resultset('EnvVariableAuditLog')->create($log_data);
}

sub _preview_changes {
    my ($self, $c, $changes) = @_;
    
    my $all_vars = $self->env_manager->read_env_file();
    foreach my $key (keys %$changes) {
        $all_vars->{$key} = $changes->{$key};
    }
    
    return $self->env_manager->_generate_env_content($all_vars);
}

1;
