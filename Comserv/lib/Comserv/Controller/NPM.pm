package Comserv::Controller::NPM;
use Moose;
use namespace::autoclean;
use LWP::UserAgent;
use HTTP::Request;
use JSON;
use Config::General;
use Try::Tiny;
use Comserv::Util::Logging;

BEGIN { extends 'Catalyst::Controller' }

=head1 NAME

Comserv::Controller::NPM - Controller for NPM (Nginx Proxy Manager) API Integration

=head1 DESCRIPTION

This controller provides an interface to the NPM API for managing proxy hosts
and other NPM-related functionality. It uses environment-specific configuration
files to manage API keys securely across different environments.

=head1 METHODS

=cut

# Create a logging instance
has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->new() },
);

# Initialize the controller
sub BUILD {
    my ($self) = @_;
    $self->logging->log_with_details(undef, 'INFO', __FILE__, __LINE__, 'BUILD', "NPM Controller initialized");
}

=head2 index

The root page for the NPM controller

=cut

sub index :Path :Args(0) {
    my ($self, $c) = @_;
    
    # Check if user is logged in and has admin privileges
    unless ($c->user_exists && $c->check_user_roles('admin')) {
        $self->logging->log_with_details($c, 'WARN', __FILE__, __LINE__, 'index', "Unauthorized access attempt to NPM controller");
        $c->response->status(403);
        $c->stash(
            template => 'error/access_denied.tt',
            error_message => 'You do not have permission to access the NPM management interface.'
        );
        return;
    }
    
    # Load NPM configuration
    my $npm_config = $self->_load_npm_config($c);
    unless ($npm_config) {
        $c->stash(
            template => 'error/config_error.tt',
            error_message => 'NPM configuration could not be loaded.'
        );
        return;
    }
    
    # Set up the NPM dashboard page
    $c->stash(
        template => 'npm/dashboard.tt',
        npm_environment => $npm_config->{environment},
        npm_endpoint => $npm_config->{endpoint},
        access_scope => $npm_config->{access_scope},
    );
}

=head2 proxy_hosts

List all proxy hosts from NPM

=cut

sub proxy_hosts :Path('proxy-hosts') :Args(0) {
    my ($self, $c) = @_;
    
    # Check if user is logged in and has admin privileges
    unless ($c->user_exists && $c->check_user_roles('admin')) {
        $self->logging->log_with_details($c, 'WARN', __FILE__, __LINE__, 'proxy_hosts', "Unauthorized access attempt to NPM proxy hosts");
        $c->response->status(403);
        $c->stash(
            template => 'error/access_denied.tt',
            error_message => 'You do not have permission to access the NPM proxy hosts.'
        );
        return;
    }
    
    # Get proxy hosts from NPM API
    my ($success, $result) = $self->_call_npm_api($c, 'GET', '/api/nginx/proxy-hosts');
    
    if ($success) {
        $c->stash(
            template => 'npm/proxy_hosts.tt',
            proxy_hosts => $result,
        );
    } else {
        $c->stash(
            template => 'error/api_error.tt',
            error_message => 'Failed to retrieve proxy hosts from NPM API: ' . $result,
        );
    }
}

=head2 create_proxy_host

Create a new proxy host in NPM

=cut

sub create_proxy_host :Path('create-proxy-host') :Args(0) {
    my ($self, $c) = @_;
    
    # Check if user is logged in and has admin privileges
    unless ($c->user_exists && $c->check_user_roles('admin')) {
        $self->logging->log_with_details($c, 'WARN', __FILE__, __LINE__, 'create_proxy_host', "Unauthorized access attempt to create NPM proxy host");
        $c->response->status(403);
        $c->stash(
            template => 'error/access_denied.tt',
            error_message => 'You do not have permission to create NPM proxy hosts.'
        );
        return;
    }
    
    # Load NPM configuration
    my $npm_config = $self->_load_npm_config($c);
    unless ($npm_config) {
        $c->stash(
            template => 'error/config_error.tt',
            error_message => 'NPM configuration could not be loaded.'
        );
        return;
    }
    
    # Check if this is a read-only environment
    if ($npm_config->{access_scope} eq 'read-only') {
        $self->logging->log_with_details($c, 'WARN', __FILE__, __LINE__, 'create_proxy_host', "Attempted to create proxy host in read-only environment");
        $c->stash(
            template => 'error/access_denied.tt',
            error_message => 'This environment is read-only. You cannot create proxy hosts in this environment.'
        );
        return;
    }
    
    # Handle form submission
    if ($c->req->method eq 'POST') {
        my $domain_names = $c->req->params->{domain_names};
        my $forward_host = $c->req->params->{forward_host};
        my $forward_port = $c->req->params->{forward_port};
        my $ssl_enabled = $c->req->params->{ssl_enabled} ? JSON::true : JSON::false;
        
        # Validate input
        unless ($domain_names && $forward_host && $forward_port) {
            $c->stash(
                template => 'npm/create_proxy_host.tt',
                error_message => 'All fields are required.',
                form_data => $c->req->params,
            );
            return;
        }
        
        # Prepare data for API call
        my $data = {
            domain_names => [split(/\s*,\s*/, $domain_names)],
            forward_host => $forward_host,
            forward_port => int($forward_port),
            access_list_id => 0,
            certificate_id => 0,
            ssl_forced => $ssl_enabled,
            caching_enabled => JSON::false,
            block_exploits => JSON::true,
            advanced_config => "",
            meta => {
                letsencrypt_agree => JSON::false,
                dns_challenge => JSON::false,
            },
            allow_websocket_upgrade => JSON::true,
            http2_support => JSON::false,
            forward_scheme => "http",
            enabled => JSON::true,
            locations => [],
        };
        
        # Call NPM API to create proxy host
        my ($success, $result) = $self->_call_npm_api($c, 'POST', '/api/nginx/proxy-hosts', $data);
        
        if ($success) {
            $self->logging->log_with_details($c, 'INFO', __FILE__, __LINE__, 'create_proxy_host', "Successfully created proxy host: $domain_names");
            $c->response->redirect($c->uri_for($self->action_for('proxy_hosts')));
            return;
        } else {
            $c->stash(
                template => 'npm/create_proxy_host.tt',
                error_message => 'Failed to create proxy host: ' . $result,
                form_data => $c->req->params,
            );
            return;
        }
    }
    
    # Display the form
    $c->stash(
        template => 'npm/create_proxy_host.tt',
    );
}

=head2 edit_proxy_host

Edit an existing proxy host in NPM

=cut

sub edit_proxy_host :Path('edit-proxy-host') :Args(1) {
    my ($self, $c, $proxy_host_id) = @_;
    
    # Check if user is logged in and has admin privileges
    unless ($c->user_exists && $c->check_user_roles('admin')) {
        $self->logging->log_with_details($c, 'WARN', __FILE__, __LINE__, 'edit_proxy_host', "Unauthorized access attempt to edit NPM proxy host");
        $c->response->status(403);
        $c->stash(
            template => 'error/access_denied.tt',
            error_message => 'You do not have permission to edit NPM proxy hosts.'
        );
        return;
    }
    
    # Load NPM configuration
    my $npm_config = $self->_load_npm_config($c);
    unless ($npm_config) {
        $c->stash(
            template => 'error/config_error.tt',
            error_message => 'NPM configuration could not be loaded.'
        );
        return;
    }
    
    # Check if this is a read-only environment
    if ($npm_config->{access_scope} eq 'read-only') {
        $self->logging->log_with_details($c, 'WARN', __FILE__, __LINE__, 'edit_proxy_host', "Attempted to edit proxy host in read-only environment");
        $c->stash(
            template => 'error/access_denied.tt',
            error_message => 'This environment is read-only. You cannot edit proxy hosts in this environment.'
        );
        return;
    }
    
    # Get the proxy host details
    my ($success, $proxy_host) = $self->_call_npm_api($c, 'GET', "/api/nginx/proxy-hosts/$proxy_host_id");
    
    unless ($success) {
        $c->stash(
            template => 'error/api_error.tt',
            error_message => 'Failed to retrieve proxy host details: ' . $proxy_host,
        );
        return;
    }
    
    # Handle form submission
    if ($c->req->method eq 'POST') {
        my $domain_names = $c->req->params->{domain_names};
        my $forward_host = $c->req->params->{forward_host};
        my $forward_port = $c->req->params->{forward_port};
        my $ssl_enabled = $c->req->params->{ssl_enabled} ? JSON::true : JSON::false;
        
        # Validate input
        unless ($domain_names && $forward_host && $forward_port) {
            $c->stash(
                template => 'npm/edit_proxy_host.tt',
                error_message => 'All fields are required.',
                proxy_host => $proxy_host,
                form_data => $c->req->params,
            );
            return;
        }
        
        # Prepare data for API call
        my $data = {
            domain_names => [split(/\s*,\s*/, $domain_names)],
            forward_host => $forward_host,
            forward_port => int($forward_port),
            ssl_forced => $ssl_enabled,
            # Keep other fields from the original proxy host
            access_list_id => $proxy_host->{access_list_id} || 0,
            certificate_id => $proxy_host->{certificate_id} || 0,
            caching_enabled => $proxy_host->{caching_enabled} || JSON::false,
            block_exploits => $proxy_host->{block_exploits} || JSON::true,
            advanced_config => $proxy_host->{advanced_config} || "",
            meta => $proxy_host->{meta} || {},
            allow_websocket_upgrade => $proxy_host->{allow_websocket_upgrade} || JSON::true,
            http2_support => $proxy_host->{http2_support} || JSON::false,
            forward_scheme => $proxy_host->{forward_scheme} || "http",
            enabled => $proxy_host->{enabled} || JSON::true,
            locations => $proxy_host->{locations} || [],
        };
        
        # Call NPM API to update proxy host
        my ($update_success, $update_result) = $self->_call_npm_api($c, 'PUT', "/api/nginx/proxy-hosts/$proxy_host_id", $data);
        
        if ($update_success) {
            $self->logging->log_with_details($c, 'INFO', __FILE__, __LINE__, 'edit_proxy_host', "Successfully updated proxy host ID: $proxy_host_id");
            $c->response->redirect($c->uri_for($self->action_for('proxy_hosts')));
            return;
        } else {
            $c->stash(
                template => 'npm/edit_proxy_host.tt',
                error_message => 'Failed to update proxy host: ' . $update_result,
                proxy_host => $proxy_host,
                form_data => $c->req->params,
            );
            return;
        }
    }
    
    # Display the form with proxy host data
    $c->stash(
        template => 'npm/edit_proxy_host.tt',
        proxy_host => $proxy_host,
        domain_names => join(', ', @{$proxy_host->{domain_names}}),
    );
}

=head2 delete_proxy_host

Delete a proxy host from NPM

=cut

sub delete_proxy_host :Path('delete-proxy-host') :Args(1) {
    my ($self, $c, $proxy_host_id) = @_;
    
    # Check if user is logged in and has admin privileges
    unless ($c->user_exists && $c->check_user_roles('admin')) {
        $self->logging->log_with_details($c, 'WARN', __FILE__, __LINE__, 'delete_proxy_host', "Unauthorized access attempt to delete NPM proxy host");
        $c->response->status(403);
        $c->stash(
            template => 'error/access_denied.tt',
            error_message => 'You do not have permission to delete NPM proxy hosts.'
        );
        return;
    }
    
    # Load NPM configuration
    my $npm_config = $self->_load_npm_config($c);
    unless ($npm_config) {
        $c->stash(
            template => 'error/config_error.tt',
            error_message => 'NPM configuration could not be loaded.'
        );
        return;
    }
    
    # Check if this is a read-only environment
    if ($npm_config->{access_scope} eq 'read-only') {
        $self->logging->log_with_details($c, 'WARN', __FILE__, __LINE__, 'delete_proxy_host', "Attempted to delete proxy host in read-only environment");
        $c->stash(
            template => 'error/access_denied.tt',
            error_message => 'This environment is read-only. You cannot delete proxy hosts in this environment.'
        );
        return;
    }
    
    # Handle confirmation
    if ($c->req->method eq 'POST' && $c->req->params->{confirm} eq 'yes') {
        # Call NPM API to delete proxy host
        my ($success, $result) = $self->_call_npm_api($c, 'DELETE', "/api/nginx/proxy-hosts/$proxy_host_id");
        
        if ($success) {
            $self->logging->log_with_details($c, 'INFO', __FILE__, __LINE__, 'delete_proxy_host', "Successfully deleted proxy host ID: $proxy_host_id");
            $c->response->redirect($c->uri_for($self->action_for('proxy_hosts')));
            return;
        } else {
            $c->stash(
                template => 'npm/delete_proxy_host.tt',
                error_message => 'Failed to delete proxy host: ' . $result,
                proxy_host_id => $proxy_host_id,
            );
            return;
        }
    }
    
    # Get the proxy host details for confirmation
    my ($success, $proxy_host) = $self->_call_npm_api($c, 'GET', "/api/nginx/proxy-hosts/$proxy_host_id");
    
    unless ($success) {
        $c->stash(
            template => 'error/api_error.tt',
            error_message => 'Failed to retrieve proxy host details: ' . $proxy_host,
        );
        return;
    }
    
    # Display confirmation page
    $c->stash(
        template => 'npm/delete_proxy_host.tt',
        proxy_host => $proxy_host,
        proxy_host_id => $proxy_host_id,
        domain_names => join(', ', @{$proxy_host->{domain_names}}),
    );
}

=head2 rotate_api_key

Rotate the NPM API key (admin only)

=cut

sub rotate_api_key :Path('rotate-api-key') :Args(0) {
    my ($self, $c) = @_;
    
    # Check if user is logged in and has admin privileges
    unless ($c->user_exists && $c->check_user_roles('admin')) {
        $self->logging->log_with_details($c, 'WARN', __FILE__, __LINE__, 'rotate_api_key', "Unauthorized access attempt to rotate NPM API key");
        $c->response->status(403);
        $c->stash(
            template => 'error/access_denied.tt',
            error_message => 'You do not have permission to rotate the NPM API key.'
        );
        return;
    }
    
    # Load NPM configuration
    my $npm_config = $self->_load_npm_config($c);
    unless ($npm_config) {
        $c->stash(
            template => 'error/config_error.tt',
            error_message => 'NPM configuration could not be loaded.'
        );
        return;
    }
    
    # Handle confirmation
    if ($c->req->method eq 'POST' && $c->req->params->{confirm} eq 'yes') {
        # Call NPM API to rotate API key
        my ($success, $result) = $self->_call_npm_api($c, 'POST', "/api/tokens/rotate");
        
        if ($success) {
            $self->logging->log_with_details($c, 'INFO', __FILE__, __LINE__, 'rotate_api_key', "Successfully rotated NPM API key");
            
            # Display the new API key
            $c->stash(
                template => 'npm/api_key_rotated.tt',
                new_api_key => $result->{token},
                environment => $npm_config->{environment},
            );
            return;
        } else {
            $c->stash(
                template => 'npm/rotate_api_key.tt',
                error_message => 'Failed to rotate API key: ' . $result,
            );
            return;
        }
    }
    
    # Display confirmation page
    $c->stash(
        template => 'npm/rotate_api_key.tt',
        environment => $npm_config->{environment},
    );
}

=head2 _load_npm_config

Private method to load the NPM configuration based on the current environment

=cut

sub _load_npm_config {
    my ($self, $c) = @_;
    
    # Determine which environment we're in
    my $environment = $ENV{CATALYST_ENV} || 'development';
    $self->logging->log_with_details($c, 'DEBUG', __FILE__, __LINE__, '_load_npm_config', "Loading NPM config for environment: $environment");
    
    # Construct the path to the config file
    my $config_file = $c->path_to('config', "npm-$environment.conf");
    
    # Check if the config file exists
    unless (-e $config_file) {
        $self->logging->log_with_details($c, 'ERROR', __FILE__, __LINE__, '_load_npm_config', "NPM config file not found: $config_file");
        return undef;
    }
    
    # Load the config file
    my $config;
    try {
        my $conf = Config::General->new($config_file);
        my %config_hash = $conf->getall();
        $config = $config_hash{NPM};
    } catch {
        $self->logging->log_with_details($c, 'ERROR', __FILE__, __LINE__, '_load_npm_config', "Failed to parse NPM config: $_");
        return undef;
    };
    
    # Validate the config
    unless ($config && $config->{api_key} && $config->{endpoint}) {
        $self->logging->log_with_details($c, 'ERROR', __FILE__, __LINE__, '_load_npm_config', "Invalid NPM config: missing required fields");
        return undef;
    }
    
    return $config;
}

=head2 _call_npm_api

Private method to call the NPM API

=cut

sub _call_npm_api {
    my ($self, $c, $method, $path, $data) = @_;
    
    # Load NPM configuration
    my $npm_config = $self->_load_npm_config($c);
    unless ($npm_config) {
        return (0, "NPM configuration could not be loaded");
    }
    
    # Create a user agent
    my $ua = LWP::UserAgent->new;
    $ua->timeout(10);
    
    # Construct the full URL
    my $url = $npm_config->{endpoint} . $path;
    $self->logging->log_with_details($c, 'DEBUG', __FILE__, __LINE__, '_call_npm_api', "Calling NPM API: $method $url");
    
    # Create the request
    my $req = HTTP::Request->new($method => $url);
    $req->header('Authorization' => "Bearer " . $npm_config->{api_key});
    $req->header('Content-Type' => 'application/json');
    
    # Add the request body if provided
    if ($data) {
        $req->content(encode_json($data));
    }
    
    # Send the request
    my $res = $ua->request($req);
    
    # Check if the request was successful
    if ($res->is_success) {
        # Parse the response
        my $result;
        try {
            $result = decode_json($res->decoded_content);
        } catch {
            $self->logging->log_with_details($c, 'ERROR', __FILE__, __LINE__, '_call_npm_api', "Failed to parse NPM API response: $_");
            return (0, "Failed to parse API response: $_");
        };
        
        return (1, $result);
    } else {
        $self->logging->log_with_details($c, 'ERROR', __FILE__, __LINE__, '_call_npm_api', "NPM API error: " . $res->status_line . " - " . $res->decoded_content);
        return (0, $res->status_line . " - " . $res->decoded_content);
    }
}

=head2 proxy_api

Public method to proxy API requests to NPM

=cut

sub proxy_api :Path('api') :Args {
    my ($self, $c, @path_parts) = @_;
    
    # Check if user is logged in and has admin privileges
    unless ($c->user_exists && $c->check_user_roles('admin')) {
        $self->logging->log_with_details($c, 'WARN', __FILE__, __LINE__, 'proxy_api', "Unauthorized access attempt to NPM API proxy");
        $c->response->status(403);
        $c->response->body('Access denied');
        return;
    }
    
    # Load NPM configuration
    my $npm_config = $self->_load_npm_config($c);
    unless ($npm_config) {
        $c->response->status(500);
        $c->response->body('NPM configuration could not be loaded');
        return;
    }
    
    # Check if this is a read-only environment and the request is not GET
    if ($npm_config->{access_scope} eq 'read-only' && $c->req->method ne 'GET') {
        $self->logging->log_with_details($c, 'WARN', __FILE__, __LINE__, 'proxy_api', "Attempted to make non-GET request in read-only environment");
        $c->response->status(403);
        $c->response->body('This environment is read-only. Only GET requests are allowed.');
        return;
    }
    
    # Construct the API path
    my $api_path = '/api/' . join('/', @path_parts);
    
    # Get the request body
    my $data;
    if ($c->req->body && $c->req->content_length > 0) {
        try {
            $data = decode_json($c->req->body);
        } catch {
            $self->logging->log_with_details($c, 'ERROR', __FILE__, __LINE__, 'proxy_api', "Failed to parse request body: $_");
            $c->response->status(400);
            $c->response->body('Invalid request body');
            return;
        };
    }
    
    # Call the NPM API
    my ($success, $result) = $self->_call_npm_api($c, $c->req->method, $api_path, $data);
    
    # Set the response
    if ($success) {
        $c->response->status(200);
        $c->response->content_type('application/json');
        $c->response->body(encode_json($result));
    } else {
        $c->response->status(500);
        $c->response->body($result);
    }
}

__PACKAGE__->meta->make_immutable;

1;