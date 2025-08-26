package Comserv::Controller::ApiCredentials;
use Moose;
use namespace::autoclean;
use JSON;
use Try::Tiny;
use File::Spec;
use Comserv::Util::Logging;

BEGIN { extends 'Catalyst::Controller'; }

# Set the base path for this controller
__PACKAGE__->config(namespace => 'ApiCredentials');

=head1 NAME

Comserv::Controller::ApiCredentials - Controller for managing API credentials

=head1 DESCRIPTION

This controller handles the management of API credentials stored in a JSON file.
It provides functionality to view, edit, and update API credentials for various services.

=cut

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

# Path to the credentials file
has 'credentials_file' => (
    is => 'ro',
    default => sub {
        my ($self) = @_;
        return File::Spec->catfile('config', 'api_credentials.json');
    }
);

# Auto method to check authorization for all actions
sub auto :Private {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', 
        "ApiCredentials controller auto method called by user: " . ($c->session->{username} || 'unknown'));
    
    # Check if user has admin privileges
    my $root_controller = $c->controller('Root');
    unless ($root_controller->check_user_roles($c, 'admin')) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'auto', 
            "Unauthorized access attempt to ApiCredentials by user: " . ($c->session->{username} || 'unknown'));
        
        # Store a message for the user
        $c->flash->{error_message} = "You must be an administrator to access API credentials management.";
        
        # Redirect to the home page
        $c->response->redirect($c->uri_for('/'));
        $c->detach();
        return 0;
    }
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', 
        "Admin access granted to ApiCredentials for user: " . $c->session->{username});
    
    return 1;
}

# Index page - displays the form to manage API credentials
sub index :Path :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', 
        "Starting ApiCredentials index action");
    
    # Load current credentials
    my $credentials = $self->_load_credentials($c);
    
    # Stash the credentials for the template
    $c->stash(
        template => 'ApiCredentials/index.tt',
        credentials => $credentials,
        title => 'API Credentials Management',
        success_message => $c->flash->{success_message},
        error_message => $c->flash->{error_message}
    );
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', 
        "Completed ApiCredentials index action, rendering template: ApiCredentials/index.tt");
}

# Update credentials
sub update :Path('update') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update', 
        "Starting ApiCredentials update action");
    
    # Only process POST requests
    unless ($c->req->method eq 'POST') {
        $c->flash->{error_message} = "Invalid request method";
        $c->response->redirect($c->uri_for('/ApiCredentials'));
        $c->detach();
        return;
    }
    
    # Load current credentials
    my $credentials = $self->_load_credentials($c);
    
    # Get form parameters
    my $params = $c->req->params;
    
    # Update credentials based on form input
    foreach my $service (keys %$credentials) {
        foreach my $key (keys %{$credentials->{$service}}) {
            my $param_name = "${service}_${key}";
            if (defined $params->{$param_name} && $params->{$param_name} ne '') {
                $credentials->{$service}->{$key} = $params->{$param_name};
            }
        }
    }
    
    # Save updated credentials
    my $success = $self->_save_credentials($c, $credentials);
    
    if ($success) {
        $c->flash->{success_message} = "API credentials updated successfully";
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update', 
            "API credentials updated successfully");
    } else {
        $c->flash->{error_message} = "Failed to update API credentials";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'update', 
            "Failed to update API credentials");
    }
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update', 
        "Completed ApiCredentials update action, redirecting to: /ApiCredentials");
        
    $c->response->redirect($c->uri_for('/ApiCredentials'));
    $c->detach();
}

# Helper method to load credentials from JSON file
sub _load_credentials {
    my ($self, $c) = @_;
    
    my $file_path = $c->path_to($self->credentials_file);
    my $credentials = {};
    
    try {
        if (-e $file_path) {
            open my $fh, '<:encoding(UTF-8)', $file_path or die "Cannot open $file_path: $!";
            my $json_content = do { local $/; <$fh> };
            close $fh;
            
            $credentials = decode_json($json_content);
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_load_credentials', 
                "Successfully loaded API credentials from $file_path");
        } else {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, '_load_credentials', 
                "Credentials file not found at $file_path");
        }
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_load_credentials', 
            "Error loading credentials: $_");
    };
    
    return $credentials;
}

# Helper method to save credentials to JSON file
sub _save_credentials {
    my ($self, $c, $credentials) = @_;
    
    my $file_path = $c->path_to($self->credentials_file);
    my $success = 0;
    
    try {
        # Create JSON with pretty formatting
        my $json = JSON->new->pretty->encode($credentials);
        
        # Write to file
        open my $fh, '>:encoding(UTF-8)', $file_path or die "Cannot open $file_path for writing: $!";
        print $fh $json;
        close $fh;
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_save_credentials', 
            "Successfully saved API credentials to $file_path");
        $success = 1;
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_save_credentials', 
            "Error saving credentials: $_");
    };
    
    return $success;
}

# Default action for any other paths under this namespace
sub default :Path :Args {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'default', 
        "Invalid path requested under ApiCredentials: " . $c->req->path);
    
    # Redirect to the index action
    $c->response->redirect($c->uri_for('/ApiCredentials'));
    $c->detach();
}

__PACKAGE__->meta->make_immutable;

1;