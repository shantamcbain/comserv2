package Comserv::Controller::Admin::DatabaseSync;
use Moose;
use namespace::autoclean;

BEGIN { extends 'Catalyst::Controller'; }

use Try::Tiny;
use JSON qw(decode_json encode_json);
use Comserv::Util::Logging;
use Comserv::Util::DatabaseEnv;
use IPC::Open3;
use Symbol 'gensym';
use File::Spec;
use FindBin;

sub logging {
    my ($self) = @_;
    return Comserv::Util::Logging->instance;
}

sub database_env {
    my ($self) = @_;
    return Comserv::Util::DatabaseEnv->new;
}

sub check_admin_auth {
    my ($self, $c) = @_;
    
    my $is_auth = 0;
    if ($c->session->{username} && $c->session->{user_id}) {
        if ($c->session->{is_admin} || 
            (ref($c->session->{roles}) eq 'ARRAY' && grep(/admin/i, @{$c->session->{roles}})) || 
            ($c->session->{roles} && $c->session->{roles} =~ /\badmin\b/i)) {
            $is_auth = 1;
        }
    } elsif ($c->user && $c->user->check_roles(qw/admin/)) {
        $is_auth = 1;
    }
    
    return $is_auth;
}

sub index :Path('/admin/database-sync') :Args(0) {
    my ($self, $c) = @_;
    
    unless ($self->check_admin_auth($c)) {
        $c->response->redirect($c->uri_for('/login'));
        $c->detach;
        return;
    }
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
        "Database sync management page accessed");
    
    my $available_envs = $self->database_env->get_available_environments($c, 'ency');
    my $active_env = $self->database_env->get_active_environment($c);
    
    my $last_sync = $self->get_last_sync_info($c);
    my $sync_config = $self->get_sync_config($c);
    
    $c->stash(
        template => 'admin/database-sync/index.tt',
        available_environments => $available_envs,
        active_environment => $active_env,
        last_sync => $last_sync,
        sync_config => $sync_config,
    );
}

sub trigger_sync :Path('/admin/database-sync/trigger') :Args(0) {
    my ($self, $c) = @_;
    
    unless ($self->check_admin_auth($c)) {
        $c->response->status(403);
        $c->stash(json => { success => 0, error => 'Access denied' });
        $c->forward('View::JSON');
        return;
    }
    
    
    
    my $json_data;
    try {
        my $body = $c->req->body;
        if ($body) {
            local $/;
            my $json_text = <$body>;
            $json_data = decode_json($json_text);
        } else {
            die "No request body provided";
        }
    } catch {
        $c->response->status(400);
        $c->stash(json => { success => 0, error => "Invalid JSON request: $_" });
        $c->forward('View::JSON');
        return;
    };
    
    my $source_env = $json_data->{source_env} || 'production';
    my $target_env = $json_data->{target_env} || 'dev';
    my $schema_only = $json_data->{schema_only} || 0;
    my $anonymize = $json_data->{anonymize} // 1;
    my $tables = $json_data->{tables} || '';
    my $dry_run = $json_data->{dry_run} || 0;
    
    unless ($self->database_env->validate_environment($source_env) && 
            $self->database_env->validate_environment($target_env)) {
        $c->response->status(400);
        $c->stash(json => { success => 0, error => 'Invalid source or target environment' });
        $c->forward('View::JSON');
        return;
    }
    
    if ($source_env eq $target_env) {
        $c->response->status(400);
        $c->stash(json => { success => 0, error => 'Source and target environments must be different' });
        $c->forward('View::JSON');
        return;
    }
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'trigger_sync',
        "Triggering database sync: $source_env -> $target_env");
    
    my $sync_result = $self->execute_sync($c, {
        source_env => $source_env,
        target_env => $target_env,
        schema_only => $schema_only,
        anonymize => $anonymize,
        tables => $tables,
        dry_run => $dry_run,
    });
    
    $self->save_sync_log($c, $sync_result);
    
    $c->stash(json => $sync_result);
    $c->forward('View::JSON');
}

sub sync_status :Path('/admin/database-sync/status') :Args(0) {
    my ($self, $c) = @_;
    
    unless ($self->check_admin_auth($c)) {
        $c->response->status(403);
        $c->stash(json => { success => 0, error => 'Access denied' });
        $c->forward('View::JSON');
        return;
    }
    
    my $status = {
        active => 0,
        message => 'No sync in progress',
        last_sync => $self->get_last_sync_info($c),
    };
    
    $c->stash(json => $status);
    $c->forward('View::JSON');
}

sub sync_history :Path('/admin/database-sync/history') :Args(0) {
    my ($self, $c) = @_;
    
    unless ($self->check_admin_auth($c)) {
        $c->response->redirect($c->uri_for('/login'));
        $c->detach;
        return;
    }
    
    my $history = $self->get_sync_history($c);
    
    $c->stash(
        template => 'admin/database-sync/history.tt',
        sync_history => $history,
    );
}

sub sync_config :Path('/admin/database-sync/config') :Args(0) {
    my ($self, $c) = @_;
    
    unless ($self->check_admin_auth($c)) {
        $c->response->redirect($c->uri_for('/login'));
        $c->detach;
        return;
    }
    
    if ($c->req->method eq 'POST') {
        
        
        my $json_data;
        try {
            my $body = $c->req->body;
            if ($body) {
                local $/;
                my $json_text = <$body>;
                $json_data = decode_json($json_text);
            }
        } catch {
            $c->response->status(400);
            $c->stash(json => { success => 0, error => "Invalid JSON request: $_" });
            $c->forward('View::JSON');
            return;
        };
        
        $self->save_sync_config($c, $json_data);
        
        $c->stash(json => { success => 1, message => 'Configuration saved' });
        $c->forward('View::JSON');
        return;
    }
    
    my $config = $self->get_sync_config($c);
    
    $c->stash(
        template => 'admin/database-sync/config.tt',
        sync_config => $config,
    );
}

sub execute_sync {
    my ($self, $c, $options) = @_;
    
    my $script_path = File::Spec->catfile($FindBin::Bin, '..', 'scripts', 'sync_dev_from_production.pl');
    
    my @cmd = ('perl', $script_path);
    
    push @cmd, '--dry-run' if $options->{dry_run};
    push @cmd, '--schema-only' if $options->{schema_only};
    push @cmd, '--no-anonymize' unless $options->{anonymize};
    push @cmd, '--tables=' . $options->{tables} if $options->{tables};
    
    my ($stdout, $stderr);
    my $pid = open3(undef, $stdout, $stderr, @cmd);
    
    my $output = '';
    my $errors = '';
    
    while (<$stdout>) {
        $output .= $_;
    }
    
    while (<$stderr>) {
        $errors .= $_;
    }
    
    waitpid($pid, 0);
    my $exit_code = $? >> 8;
    
    my $success = ($exit_code == 0);
    
    return {
        success => $success,
        exit_code => $exit_code,
        output => $output,
        errors => $errors,
        source_env => $options->{source_env},
        target_env => $options->{target_env},
        timestamp => time(),
        dry_run => $options->{dry_run},
    };
}

sub get_last_sync_info {
    my ($self, $c) = @_;
    
    return undef;
}

sub get_sync_history {
    my ($self, $c) = @_;
    
    return [];
}

sub save_sync_log {
    my ($self, $c, $sync_result) = @_;
    
}

sub get_sync_config {
    my ($self, $c) = @_;
    
    return {
        auto_sync_enabled => 0,
        sync_schedule => '0 2 * * *',
        default_source_env => 'production',
        default_target_env => 'dev',
        default_schema_only => 0,
        default_anonymize => 1,
    };
}

sub save_sync_config {
    my ($self, $c, $config) = @_;
    
}

__PACKAGE__->meta->make_immutable;

1;
