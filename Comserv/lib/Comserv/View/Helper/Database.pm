package Comserv::View::Helper::Database;

use strict;
use warnings;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;

has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

# Execute a query on a database
sub execute_query {
    my ($self, $c, $database, $query, $params) = @_;
    
    $params ||= [];
    
    # Log the query
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'execute_query', 
        "Executing query on $database: $query");
    
    # Determine which database to use
    if ($database =~ /^ency$/i) {
        # Use the DBEncy model
        my $dbh = $c->model('DBEncy')->schema->storage->dbh;
        my $sth = $dbh->prepare($query);
        $sth->execute(@$params);
        
        # For SELECT queries, fetch and return the results
        if ($query =~ /^\s*SELECT/i) {
            my @results;
            while (my $row = $sth->fetchrow_hashref) {
                push @results, $row;
            }
            return \@results;
        }
        
        # For non-SELECT queries, return success
        return { success => 1, rows_affected => $sth->rows };
    }
    elsif ($database =~ /^forager$/i) {
        # Use the DBForager model
        my $dbh = $c->model('DBForager')->schema->storage->dbh;
        my $sth = $dbh->prepare($query);
        $sth->execute(@$params);
        
        # For SELECT queries, fetch and return the results
        if ($query =~ /^\s*SELECT/i) {
            my @results;
            while (my $row = $sth->fetchrow_hashref) {
                push @results, $row;
            }
            return \@results;
        }
        
        # For non-SELECT queries, return success
        return { success => 1, rows_affected => $sth->rows };
    }
    else {
        # Use the RemoteDB model for other databases
        my $remote_db = $c->model('RemoteDB');
        return $remote_db->execute_query($c, $database, $query, $params);
    }
}

# Get data from a model
sub get_model_data {
    my ($self, $c, $model_name, $method_name, $params) = @_;
    
    # Log the request
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_model_data', 
        "Getting data from $model_name->$method_name");
    
    # Get the model
    my $model = $c->model($model_name);
    
    # Call the method
    my $result;
    eval {
        if (ref $params eq 'HASH') {
            $result = $model->$method_name(%$params);
        }
        elsif (ref $params eq 'ARRAY') {
            $result = $model->$method_name(@$params);
        }
        else {
            $result = $model->$method_name($params);
        }
    };
    
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_model_data', 
            "Error calling $model_name->$method_name: $@");
        return;
    }
    
    return $result;
}

# Get a list of tables from a database
sub list_tables {
    my ($self, $c, $database) = @_;
    
    # Log the request
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'list_tables', 
        "Listing tables in $database");
    
    # Determine which database to use
    if ($database =~ /^ency$/i) {
        # Use the DBEncy model
        return $c->model('DBEncy')->list_tables();
    }
    elsif ($database =~ /^forager$/i) {
        # Use the DBForager model
        return $c->model('DBForager')->list_tables();
    }
    else {
        # Use the RemoteDB model for other databases
        my $remote_db = $c->model('RemoteDB');
        return $remote_db->list_tables($c, $database);
    }
}

# Get a list of available databases
sub list_databases {
    my ($self, $c) = @_;
    
    # Log the request
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'list_databases', 
        "Listing available databases");
    
    # Start with the local databases
    my @databases = ('ency', 'forager');
    
    # Add remote databases
    my $remote_db = $c->model('RemoteDB');
    push @databases, keys %{$remote_db->connections};
    
    return \@databases;
}

__PACKAGE__->meta->make_immutable;
1;