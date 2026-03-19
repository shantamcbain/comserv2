package Comserv::Controller::AIAdmin;
use Moose;
use namespace::autoclean;
use Try::Tiny;
use JSON;
use Comserv::Util::Logging;

BEGIN { extends 'Catalyst::Controller'; }

has 'logging' => (
    is => 'ro',
    lazy => 1,
    default => sub { Comserv::Util::Logging->instance },
);

sub models :Path('/ai/admin/models') :Args(0) {
    my ($self, $c) = @_;
    
    my $_roles = $c->session->{roles} || []; my $_is_admin = (ref($_roles) ? grep { lc($_) eq 'admin' } @$_roles : 0) || $c->session->{is_admin}; unless ($_is_admin) {
        $c->response->redirect($c->uri_for('/'));
        return;
    }
    
    try {
        my $schema = $c->model('DBEncy')->schema;
        my @model_configs = $schema->resultset('AiModelConfig')->search(
            {},
            { order_by => ['role', 'agent_type', 'priority'] }
        )->all;
        
        my @models_data;
        foreach my $config (@model_configs) {
            push @models_data, {
                id => $config->id,
                site_id => $config->site_id,
                role => $config->role,
                agent_type => $config->agent_type,
                model_name => $config->model_name,
                enabled => $config->enabled,
                api_endpoint => $config->api_endpoint,
                temperature => $config->temperature,
                max_tokens => $config->max_tokens,
                priority => $config->priority,
                capabilities => $config->get_capabilities,
                has_api_key => $config->api_key_encrypted ? 1 : 0,
            };
        }
        
        $c->stash(
            template => 'ai/admin/models.tt',
            models => \@models_data,
            page_title => 'AI Model Configuration'
        );
        
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'models', "Error loading models: $_");
        $c->stash(
            template => 'error.tt',
            error => 'Failed to load AI model configurations'
        );
    };
}

sub add_model :Path('/ai/admin/add_model') :Args(0) {
    my ($self, $c) = @_;
    
    my $_roles = $c->session->{roles} || []; my $_is_admin = (ref($_roles) ? grep { lc($_) eq 'admin' } @$_roles : 0) || $c->session->{is_admin}; unless ($_is_admin) {
        $c->response->status(403);
        $c->response->body(encode_json({ success => 0, error => 'Unauthorized' }));
        return;
    }
    
    $c->response->content_type('application/json');
    
    my $params = $c->req->params;
    
    unless ($params->{model_name} && $params->{api_endpoint} && $params->{role} && $params->{agent_type}) {
        $c->response->status(400);
        $c->response->body(encode_json({
            success => 0,
            error => 'Missing required fields: model_name, api_endpoint, role, agent_type'
        }));
        return;
    }
    
    try {
        my $schema = $c->model('DBEncy')->schema;
        
        my %create_data = (
            site_id => $c->session->{SiteID} || 1,
            role => $params->{role},
            agent_type => $params->{agent_type},
            model_name => $params->{model_name},
            enabled => $params->{enabled} // 1,
            api_endpoint => $params->{api_endpoint},
            temperature => $params->{temperature} // 0.7,
            max_tokens => $params->{max_tokens} // 2048,
            search_docs_automatically => $params->{search_docs_automatically} // 1,
            allow_web_search => $params->{allow_web_search} // 0,
            allow_code_search => $params->{allow_code_search} // 0,
            priority => $params->{priority} // 1,
        );
        
        my $config = $schema->resultset('AiModelConfig')->create(\%create_data);
        
        if ($params->{api_key} && length($params->{api_key}) > 0) {
            my $encryption_key = $ENV{ENCRYPTION_KEY} || die "ENCRYPTION_KEY not configured";
            $config->set_encrypted_api_key($params->{api_key}, $encryption_key);
            $config->update;
        }
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
            'add_model', "Added AI model config: " . $params->{model_name});
        
        $c->response->body(encode_json({
            success => 1,
            model_id => $config->id,
            message => 'Model configuration added successfully'
        }));
        
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'add_model', "Error adding model: $_");
        $c->response->status(500);
        $c->response->body(encode_json({
            success => 0,
            error => 'Failed to add model configuration: ' . $_
        }));
    };
}

sub update_model :Path('/ai/admin/update_model') :Args(0) {
    my ($self, $c) = @_;
    
    my $_roles = $c->session->{roles} || []; my $_is_admin = (ref($_roles) ? grep { lc($_) eq 'admin' } @$_roles : 0) || $c->session->{is_admin}; unless ($_is_admin) {
        $c->response->status(403);
        $c->response->body(encode_json({ success => 0, error => 'Unauthorized' }));
        return;
    }
    
    $c->response->content_type('application/json');
    
    my $params = $c->req->params;
    my $model_id = $params->{id};
    
    unless ($model_id) {
        $c->response->status(400);
        $c->response->body(encode_json({ success => 0, error => 'Model ID required' }));
        return;
    }
    
    try {
        my $schema = $c->model('DBEncy')->schema;
        my $config = $schema->resultset('AiModelConfig')->find($model_id);
        
        unless ($config) {
            $c->response->status(404);
            $c->response->body(encode_json({ success => 0, error => 'Model not found' }));
            return;
        }
        
        my %update_data;
        foreach my $field (qw/model_name enabled api_endpoint temperature max_tokens 
                             search_docs_automatically allow_web_search allow_code_search priority/) {
            $update_data{$field} = $params->{$field} if defined $params->{$field};
        }
        
        $config->update(\%update_data) if %update_data;
        
        if ($params->{api_key} && length($params->{api_key}) > 0) {
            my $encryption_key = $ENV{ENCRYPTION_KEY} || die "ENCRYPTION_KEY not configured";
            $config->set_encrypted_api_key($params->{api_key}, $encryption_key);
            $config->update;
        }
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
            'update_model', "Updated AI model config ID: $model_id");
        
        $c->response->body(encode_json({
            success => 1,
            message => 'Model configuration updated successfully'
        }));
        
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'update_model', "Error updating model: $_");
        $c->response->status(500);
        $c->response->body(encode_json({
            success => 0,
            error => 'Failed to update model configuration: ' . $_
        }));
    };
}

sub delete_model :Path('/ai/admin/delete_model') :Args(0) {
    my ($self, $c) = @_;
    
    my $_roles = $c->session->{roles} || []; my $_is_admin = (ref($_roles) ? grep { lc($_) eq 'admin' } @$_roles : 0) || $c->session->{is_admin}; unless ($_is_admin) {
        $c->response->status(403);
        $c->response->body(encode_json({ success => 0, error => 'Unauthorized' }));
        return;
    }
    
    $c->response->content_type('application/json');
    
    my $model_id = $c->req->params->{id};
    
    unless ($model_id) {
        $c->response->status(400);
        $c->response->body(encode_json({ success => 0, error => 'Model ID required' }));
        return;
    }
    
    try {
        my $schema = $c->model('DBEncy')->schema;
        my $config = $schema->resultset('AiModelConfig')->find($model_id);
        
        unless ($config) {
            $c->response->status(404);
            $c->response->body(encode_json({ success => 0, error => 'Model not found' }));
            return;
        }
        
        $config->delete;
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
            'delete_model', "Deleted AI model config ID: $model_id");
        
        $c->response->body(encode_json({
            success => 1,
            message => 'Model configuration deleted successfully'
        }));
        
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'delete_model', "Error deleting model: $_");
        $c->response->status(500);
        $c->response->body(encode_json({
            success => 0,
            error => 'Failed to delete model configuration: ' . $_
        }));
    };
}

sub agents :Path('/ai/admin/agents') :Args(0) {
    my ($self, $c) = @_;
    
    my $_roles = $c->session->{roles} || []; my $_is_admin = (ref($_roles) ? grep { lc($_) eq 'admin' } @$_roles : 0) || $c->session->{is_admin}; unless ($_is_admin) {
        $c->response->redirect($c->uri_for('/'));
        return;
    }
    
    my $agents_config = {
        available_agents => [
            {
                id => 'helpdesk',
                name => 'HelpDesk Agent',
                description => 'General help and support for users',
                roles => ['user', 'admin'],
                icon => '🎧'
            },
            {
                id => 'ency',
                name => 'Encyclopedia Agent',
                description => 'Expert in looking up information and adding to knowledge base',
                roles => ['normal', 'developer', 'editor', 'admin'],
                icon => '📚'
            },
            {
                id => 'developer',
                name => 'Developer Agent',
                description => 'Code analysis, debugging, and development assistance',
                roles => ['developer', 'admin'],
                icon => '💻'
            },
            {
                id => 'coding',
                name => 'Coding Agent',
                description => 'Code generation and refactoring',
                roles => ['developer', 'admin'],
                icon => '⌨️'
            },
            {
                id => 'editor',
                name => 'Content Editor Agent',
                description => 'Help with content creation and documentation',
                roles => ['editor', 'admin'],
                icon => '✍️'
            },
            {
                id => 'documentation',
                name => 'Documentation Agent',
                description => 'Help with technical documentation',
                roles => ['editor', 'developer', 'admin'],
                icon => '📝'
            },
        ],
        role_definitions => {
            user => 'Not logged in - HelpDesk agent only',
            normal => 'Registered users - HelpDesk + Ency agents',
            developer => 'Developer access - all coding agents',
            editor => 'Content editors - documentation and editing agents',
            admin => 'Full access to all agents'
        }
    };
    
    $c->stash(
        template => 'ai/admin/agents.tt',
        agents => $agents_config->{available_agents},
        role_definitions => $agents_config->{role_definitions},
        page_title => 'AI Agent Management'
    );
}

__PACKAGE__->meta->make_immutable;
1;
