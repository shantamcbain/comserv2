package Comserv::Controller::Setup;
use Moose;
use namespace::autoclean;
use JSON;
use DBI;
use Try::Tiny;

BEGIN { extends 'Catalyst::Controller'; }

# Check if setup is needed
sub auto :Private {
    my ($self, $c) = @_;
    
    # Skip setup check if we're already in setup
    return 1 if $c->action->name eq 'setup';
    
    # Check if db_config.json exists and has valid configuration
    if (!-f $c->path_to('db_config.json')) {
        $c->response->redirect($c->uri_for($self->action_for('setup')));
        return 0;
    }
    
    return 1;
}

# Main setup page
sub setup :Path('/setup') :Args(0) {
    my ($self, $c) = @_;
    
    if ($c->req->method eq 'POST') {
        my $params = $c->req->params;
        
        my $config = {
            db_type => $params->{db_type},
            host => $params->{host},
            port => $params->{port},
            database => $params->{database},
            username => $params->{username},
            password => $params->{password}
        };
        
        # Test connection
        if ($self->test_connection($config)) {
            # Save configuration
            $self->save_config($c, $config);
            
            # Initialize database
            $self->initialize_database($c, $config);
            
            $c->response->redirect($c->uri_for('/'));
            return;
        } else {
            $c->stash(error_msg => 'Failed to connect to database');
        }
    }
    
    $c->stash(template => 'setup/database.tt');
}

# Test database connection
sub test_connection {
    my ($self, $config) = @_;
    
    try {
        my $dsn = "DBI:$config->{db_type}:database=$config->{database};host=$config->{host};port=$config->{port}";
        my $dbh = DBI->connect($dsn, $config->{username}, $config->{password}, 
            { RaiseError => 1, AutoCommit => 1 });
        return 1 if $dbh;
    } catch {
        return 0;
    };
}

# Save configuration to db_config.json
sub save_config {
    my ($self, $c, $config) = @_;
    
    # Create config directory if it doesn't exist
    my $config_dir = $c->path_to('config');
    unless (-d $config_dir) {
        mkdir $config_dir or die "Cannot create config directory: $!";
    }
    
    open my $fh, '>', $c->path_to('config', 'db_config.json') or die $!;
    print $fh encode_json($config);
    close $fh;
}

# Initialize database schema
sub initialize_database {
    my ($self, $c, $config) = @_;
    
    my $schema_manager = $c->model('DBSchemaManager');
    $schema_manager->initialize_schema($config);
}

__PACKAGE__->meta->make_immutable;
1;
