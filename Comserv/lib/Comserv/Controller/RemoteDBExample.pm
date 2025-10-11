package Comserv::Controller::RemoteDBExample;

use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;
use Comserv::Util::RemoteDB;

BEGIN { extends 'Catalyst::Controller'; }

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

has 'remote_db_util' => (
    is => 'ro',
    default => sub { Comserv::Util::RemoteDB->new }
);

# Example of using the remote database utility
sub index :Path :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Starting remote DB example");
    
    # Get list of available connections
    my $connections = $self->remote_db_util->get_connections($c);
    
    if (@$connections == 0) {
        $c->stash(
            template => 'remotedb_example/index.tt',
            error_msg => "No remote database connections configured. Please add a connection first.",
        );
        return;
    }
    
    # Use the first available connection for this example
    my $conn_name = $connections->[0];
    
    # Example: Get data from a remote table
    my $example_data;
    if ($self->remote_db_util->connection_exists($c, $conn_name)) {
        # Get the list of tables first
        my $remote_db = $c->model('RemoteDB');
        my $tables = $remote_db->list_tables($c, $conn_name);
        
        if ($tables && @$tables > 0) {
            # Use the first table for the example
            my $table_name = $tables->[0];
            
            # Get sample data from the table
            $example_data = $self->remote_db_util->get_rows($c, $conn_name, $table_name, {}, { limit => 5 });
            
            $c->stash(
                connection => $conn_name,
                table => $table_name,
                data => $example_data,
            );
        } else {
            $c->stash(error_msg => "No tables found in the remote database.");
        }
    } else {
        $c->stash(error_msg => "Connection '$conn_name' does not exist.");
    }
    
    $c->stash(template => 'remotedb_example/index.tt');
}

__PACKAGE__->meta->make_immutable;
1;