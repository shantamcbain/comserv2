package Comserv::Controller::RemoteDB;

use Moose;
use namespace::autoclean;
use JSON;
use Try::Tiny;
use Data::Dumper;
use Comserv::Util::Logging;

BEGIN { extends 'Catalyst::Controller'; }

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

# Main page for remote database management
sub index :Path :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Accessing remote database management page");
    
    # Get list of configured remote connections
    my $remote_db = $c->model('RemoteDB');
    my $connections = $remote_db->connections;
    
    $c->stash(
        template => 'remotedb/index.tt',
        connections => $connections,
    );
}

# Add a new remote database connection
sub add_connection :Path('add') :Args(0) {
    my ($self, $c) = @_;
    
    if ($c->req->method eq 'POST') {
        my $params = $c->req->params;
        
        # Validate required parameters
        my @required = qw(conn_name db_type host port database username password);
        my @missing;
        foreach my $field (@required) {
            push @missing, $field unless defined $params->{$field} && length $params->{$field};
        }
        
        if (@missing) {
            $c->stash(
                error_msg => 'Missing required fields: ' . join(', ', @missing),
                form_data => $params,
            );
        } else {
            # Create connection config
            my $conn_config = {
                db_type  => $params->{db_type},
                host     => $params->{host},
                port     => $params->{port},
                database => $params->{database},
                username => $params->{username},
                password => $params->{password},
            };
            
            # Test the connection
            my $remote_db = $c->model('RemoteDB');
            $remote_db->add_connection($params->{conn_name}, $conn_config);
            
            my $dbh = $remote_db->get_connection($c, $params->{conn_name});
            
            if ($dbh) {
                # Connection successful, update the configuration file
                $self->update_config_file($c, $params->{conn_name}, $conn_config);
                
                $c->flash->{success_msg} = "Successfully added remote database connection: " . $params->{conn_name};
                $c->response->redirect($c->uri_for($self->action_for('index')));
                return;
            } else {
                $c->stash(
                    error_msg => "Failed to connect to the database. Please check your connection details.",
                    form_data => $params,
                );
            }
        }
    }
    
    $c->stash(
        template => 'remotedb/add.tt',
        db_types => ['mysql', 'Pg', 'SQLite', 'Oracle'],
    );
}

# View a remote database's tables and structure
sub view :Path('view') :Args(1) {
    my ($self, $c, $conn_name) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view', "Viewing remote database: $conn_name");
    
    my $remote_db = $c->model('RemoteDB');
    
    # Check if the connection exists
    unless (exists $remote_db->connections->{$conn_name}) {
        $c->flash->{error_msg} = "Remote connection '$conn_name' does not exist";
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }
    
    # Get the list of tables
    my $tables = $remote_db->list_tables($c, $conn_name);
    
    unless (defined $tables) {
        $c->flash->{error_msg} = "Failed to connect to remote database '$conn_name'";
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }
    
    $c->stash(
        template => 'remotedb/view.tt',
        conn_name => $conn_name,
        tables => $tables,
    );
}

# View a specific table in a remote database
sub table :Path('table') :Args(2) {
    my ($self, $c, $conn_name, $table_name) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'table', 
        "Viewing table '$table_name' in remote database: $conn_name");
    
    my $remote_db = $c->model('RemoteDB');
    
    # Get the table schema
    my $schema = $remote_db->get_table_schema($c, $conn_name, $table_name);
    
    unless (defined $schema) {
        $c->flash->{error_msg} = "Failed to get schema for table '$table_name'";
        $c->response->redirect($c->uri_for($self->action_for('view'), [$conn_name]));
        return;
    }
    
    # Get sample data (first 10 rows)
    my $data = $remote_db->execute_query($c, $conn_name, "SELECT * FROM $table_name LIMIT 10", []);
    
    $c->stash(
        template => 'remotedb/table.tt',
        conn_name => $conn_name,
        table_name => $table_name,
        schema => $schema,
        data => $data,
    );
}

# Execute a custom SQL query
sub query :Path('query') :Args(1) {
    my ($self, $c, $conn_name) = @_;
    
    my $remote_db = $c->model('RemoteDB');
    
    # Check if the connection exists
    unless (exists $remote_db->connections->{$conn_name}) {
        $c->flash->{error_msg} = "Remote connection '$conn_name' does not exist";
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }
    
    if ($c->req->method eq 'POST') {
        my $query = $c->req->param('query');
        
        if (defined $query && length $query) {
            my $result = $remote_db->execute_query($c, $conn_name, $query, []);
            
            if (ref $result eq 'ARRAY') {
                $c->stash(
                    query_result => $result,
                    result_type => 'select',
                );
            } elsif (ref $result eq 'HASH' && $result->{success}) {
                $c->stash(
                    query_result => $result,
                    result_type => 'update',
                );
            } else {
                $c->stash(
                    error_msg => "Query execution failed: " . ($result->{error} || "Unknown error"),
                );
            }
        } else {
            $c->stash(error_msg => "Query cannot be empty");
        }
    }
    
    $c->stash(
        template => 'remotedb/query.tt',
        conn_name => $conn_name,
    );
}

# Remove a remote database connection
sub remove :Path('remove') :Args(1) {
    my ($self, $c, $conn_name) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'remove', 
        "Removing remote database connection: $conn_name");
    
    # Remove from configuration file
    $self->remove_from_config($c, $conn_name);
    
    $c->flash->{success_msg} = "Successfully removed remote database connection: $conn_name";
    $c->response->redirect($c->uri_for($self->action_for('index')));
}

# Helper method to update the configuration file
sub update_config_file {
    my ($self, $c, $conn_name, $conn_config) = @_;
    
    try {
        # Read the current configuration
        local $/;
        open my $fh, "<", "db_config.json" or die "Could not open db_config.json: $!";
        my $json_text = <$fh>;
        close $fh;
        
        my $config = decode_json($json_text);
        
        # Initialize remote_connections if it doesn't exist
        $config->{remote_connections} ||= {};
        
        # Add or update the connection
        $config->{remote_connections}{$conn_name} = $conn_config;
        
        # Write the updated configuration back to the file
        open $fh, ">", "db_config.json" or die "Could not open db_config.json for writing: $!";
        print $fh encode_json($config);
        close $fh;
        
        return 1;
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'update_config_file', 
            "Failed to update configuration file: $_");
        return 0;
    };
}

# Helper method to remove a connection from the configuration file
sub remove_from_config {
    my ($self, $c, $conn_name) = @_;
    
    try {
        # Read the current configuration
        local $/;
        open my $fh, "<", "db_config.json" or die "Could not open db_config.json: $!";
        my $json_text = <$fh>;
        close $fh;
        
        my $config = decode_json($json_text);
        
        # Remove the connection if it exists
        if ($config->{remote_connections} && exists $config->{remote_connections}{$conn_name}) {
            delete $config->{remote_connections}{$conn_name};
        }
        
        # Write the updated configuration back to the file
        open $fh, ">", "db_config.json" or die "Could not open db_config.json for writing: $!";
        print $fh encode_json($config);
        close $fh;
        
        return 1;
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'remove_from_config', 
            "Failed to update configuration file: $_");
        return 0;
    };
}

__PACKAGE__->meta->make_immutable;
1;