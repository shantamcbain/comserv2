package Comserv::Util::RemoteDB;

use strict;
use warnings;
use Moose;
use namespace::autoclean;
use Try::Tiny;
use Data::Dumper;
use Comserv::Util::Logging;

has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

# Execute a query on a remote database
sub execute_query {
    my ($self, $c, $conn_name, $query, $params) = @_;
    
    # Get the RemoteDB model
    my $remote_db = $c->model('RemoteDB');
    
    # Check if the connection exists
    unless (exists $remote_db->connections->{$conn_name}) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'execute_query', 
            "Remote connection '$conn_name' does not exist");
        return { error => "Connection '$conn_name' does not exist" };
    }
    
    # Execute the query
    return $remote_db->execute_query($c, $conn_name, $query, $params || []);
}

# Get a single row from a remote database
sub get_row {
    my ($self, $c, $conn_name, $table, $where, $params) = @_;
    
    # Build the query
    my $query = "SELECT * FROM $table WHERE ";
    my @conditions;
    my @bind_params;
    
    foreach my $key (keys %$where) {
        push @conditions, "$key = ?";
        push @bind_params, $where->{$key};
    }
    
    $query .= join(' AND ', @conditions) . " LIMIT 1";
    
    # Execute the query
    my $result = $self->execute_query($c, $conn_name, $query, \@bind_params);
    
    # Return the first row if found
    if (ref $result eq 'ARRAY' && @$result > 0) {
        return $result->[0];
    }
    
    return;
}

# Get multiple rows from a remote database
sub get_rows {
    my ($self, $c, $conn_name, $table, $where, $params) = @_;
    
    # Build the query
    my $query = "SELECT * FROM $table";
    my @bind_params;
    
    if ($where && %$where) {
        my @conditions;
        
        foreach my $key (keys %$where) {
            push @conditions, "$key = ?";
            push @bind_params, $where->{$key};
        }
        
        $query .= " WHERE " . join(' AND ', @conditions);
    }
    
    # Add order by if specified
    if ($params && $params->{order_by}) {
        $query .= " ORDER BY $params->{order_by}";
    }
    
    # Add limit if specified
    if ($params && $params->{limit}) {
        $query .= " LIMIT $params->{limit}";
        
        # Add offset if specified
        if ($params->{offset}) {
            $query .= " OFFSET $params->{offset}";
        }
    }
    
    # Execute the query
    return $self->execute_query($c, $conn_name, $query, \@bind_params);
}

# Insert a row into a remote database
sub insert_row {
    my ($self, $c, $conn_name, $table, $data) = @_;
    
    # Build the query
    my $query = "INSERT INTO $table (";
    my @columns;
    my @placeholders;
    my @values;
    
    foreach my $key (keys %$data) {
        push @columns, $key;
        push @placeholders, '?';
        push @values, $data->{$key};
    }
    
    $query .= join(', ', @columns) . ") VALUES (" . join(', ', @placeholders) . ")";
    
    # Execute the query
    return $self->execute_query($c, $conn_name, $query, \@values);
}

# Update a row in a remote database
sub update_row {
    my ($self, $c, $conn_name, $table, $data, $where) = @_;
    
    # Build the query
    my $query = "UPDATE $table SET ";
    my @set_clauses;
    my @values;
    
    foreach my $key (keys %$data) {
        push @set_clauses, "$key = ?";
        push @values, $data->{$key};
    }
    
    $query .= join(', ', @set_clauses) . " WHERE ";
    
    my @where_clauses;
    foreach my $key (keys %$where) {
        push @where_clauses, "$key = ?";
        push @values, $where->{$key};
    }
    
    $query .= join(' AND ', @where_clauses);
    
    # Execute the query
    return $self->execute_query($c, $conn_name, $query, \@values);
}

# Delete a row from a remote database
sub delete_row {
    my ($self, $c, $conn_name, $table, $where) = @_;
    
    # Build the query
    my $query = "DELETE FROM $table WHERE ";
    my @conditions;
    my @values;
    
    foreach my $key (keys %$where) {
        push @conditions, "$key = ?";
        push @values, $where->{$key};
    }
    
    $query .= join(' AND ', @conditions);
    
    # Execute the query
    return $self->execute_query($c, $conn_name, $query, \@values);
}

# Get a list of available remote connections
sub get_connections {
    my ($self, $c) = @_;
    
    my $remote_db = $c->model('RemoteDB');
    return [sort keys %{$remote_db->connections}];
}

# Check if a remote connection exists
sub connection_exists {
    my ($self, $c, $conn_name) = @_;
    
    my $remote_db = $c->model('RemoteDB');
    return exists $remote_db->connections->{$conn_name};
}

# Get a database handle for a remote connection
sub get_dbh {
    my ($self, $c, $conn_name) = @_;
    
    my $remote_db = $c->model('RemoteDB');
    return $remote_db->get_connection($c, $conn_name);
}

__PACKAGE__->meta->make_immutable;
1;