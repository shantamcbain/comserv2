package Comserv::Controller::RemoteDB;

use Moose;
use namespace::autoclean -except => [qw(try catch finally)];  # keep Try::Tiny subs (Perl 5.40)
use JSON;
use Try::Tiny;
use Data::Dumper;
use Comserv::Util::Logging;
use Comserv::Util::AdminAuth;
use Comserv::Util::DbConfigPassword;
use Catalyst::Utils;  # For path_to

BEGIN { extends 'Catalyst::Controller'; }

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

has 'admin_auth' => (
    is => 'ro',
    default => sub { Comserv::Util::AdminAuth->new }
);

has 'db_pw' => (
    is => 'ro',
    default => sub { Comserv::Util::DbConfigPassword->new }
);

# RemoteDB is a plain Moose class, not Catalyst::Model.
# $c->model('RemoteDB') therefore returns the class NAME string; Moose
# accessors then die: Can't use string ("Comserv::Model::RemoteDB") as a HASH ref.
sub _remote_db {
    my ($self, $c) = @_;
    my $m = eval { $c->model('RemoteDB') };
    if ($@) {
        $self->logging->log_with_details($c, 'warning', __FILE__, __LINE__, '_remote_db',
            "model('RemoteDB') threw: $@ — instantiating Comserv::Model::RemoteDB->new");
    }
    return $m if ref $m;
    require Comserv::Model::RemoteDB;
    return Comserv::Model::RemoteDB->new();
}

# Main page for remote database management
sub index :Path :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Accessing remote database management page");
    
    my $remote_db = $self->_remote_db($c);
    my $connections = $remote_db->get_all_connections();
    
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
            my $remote_db = $self->_remote_db($c);
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
    
    my $remote_db = $self->_remote_db($c);
    
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
    
    my $remote_db = $self->_remote_db($c);
    
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
    
    my $remote_db = $self->_remote_db($c);
    
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

# Connection details (no password value shown)
sub detail :Path('detail') :Args(1) {
    my ($self, $c, $conn_name) = @_;
    return unless $self->admin_auth->require_admin_access($c, 'remotedb_detail');

    unless ($conn_name && $conn_name =~ /\A[A-Za-z0-9_]+\z/) {
        $c->flash->{error_msg} = 'Invalid connection name';
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }

    my $all = $self->_remote_db($c)->get_all_connections();
    unless ($all && $all->{$conn_name}) {
        $c->flash->{error_msg} = "Remote connection '$conn_name' does not exist";
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }

    $c->stash(
        template  => 'remotedb/detail.tt',
        conn_name => $conn_name,
        conn      => $all->{$conn_name},
    );
}

# Change stored (and optionally server) password for one connection slot
sub change_password :Path('change_password') :Args(1) {
    my ($self, $c, $conn_name) = @_;
    return unless $self->admin_auth->require_admin_access($c, 'remotedb_change_password');

    unless ($conn_name && $conn_name =~ /\A[A-Za-z0-9_]+\z/) {
        $c->flash->{error_msg} = 'Invalid connection name';
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }

    my $remote_db = $self->_remote_db($c);
    my $all = $remote_db->get_all_connections();
    unless ($all && $all->{$conn_name}) {
        $c->flash->{error_msg} = "Remote connection '$conn_name' does not exist";
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }
    my $cfg = $all->{$conn_name}{config} || {};

    my $home = $ENV{HOME} || '/tmp';
    my @paths = $self->db_pw->collect_sources(
        db_config_path => $c->path_to('db_config.json') . '',
        secrets_dir    => "$home/.comserv/secrets/dbi",
    );

    my @siblings;
    for my $path (@paths) {
        try {
            push @siblings, $self->db_pw->sibling_slot_names(
                $self->db_pw->load_json_file($path), $conn_name
            );
        } catch {
            $self->logging->log_with_details($c, 'warning', __FILE__, __LINE__, 'change_password',
                "Could not inspect $path for sibling slots: $_");
        };
    }
    my %seen;
    @siblings = grep { !$seen{$_}++ } @siblings;

    if ($c->req->method eq 'POST') {
        my $current = $c->req->param('current_password') // '';
        my $new     = $c->req->param('new_password') // '';
        my $confirm = $c->req->param('new_password_confirm') // '';
        my $rotate  = $c->req->param('rotate_server') ? 1 : 0;
        my $sibs    = $c->req->param('apply_siblings') ? 1 : 0;

        my $form_error;
        if (!length $current) {
            $form_error = 'Current password is required';
        } elsif (length $new < 12) {
            $form_error = 'New password must be at least 12 characters';
        } elsif ($new ne $confirm) {
            $form_error = 'New password and confirmation do not match';
        } elsif ($new eq $current) {
            $form_error = 'New password must be different from the current password';
        } else {
            my $stored;
            for my $path (@paths) {
                $stored = eval { $self->db_pw->stored_password_for($path, $conn_name) };
                last if defined $stored && length $stored;
            }
            if (defined $stored && length $stored && $stored ne $current) {
                $form_error = 'Current password does not match the stored value';
            }
        }

        if ($form_error) {
            $c->stash(error_msg => $form_error);
        } else {
            my $ok = 1;
            try {
                if ($rotate) {
                    my $probe = $self->db_pw->test_login($cfg, $current);
                    $self->db_pw->alter_current_user_password($probe->{dbh}, $new);
                    $probe->{dbh}->disconnect if $probe->{dbh};
                    my $verify = $self->db_pw->test_login($cfg, $new);
                    $verify->{dbh}->disconnect if $verify->{dbh};
                }
                my $updated = $self->db_pw->apply_password(
                    slot            => $conn_name,
                    new_password    => $new,
                    apply_siblings  => $sibs,
                    paths           => \@paths,
                );
                # Refresh in-memory RemoteDB so this worker does not keep the old pw
                try {
                    my $live = $remote_db->config;
                    if (ref $live eq 'HASH' && ref $live->{$conn_name} eq 'HASH') {
                        $live->{$conn_name}{password} = $new;
                    }
                    if ($sibs) {
                        for my $s (@siblings) {
                            $live->{$s}{password} = $new if ref $live eq 'HASH' && ref $live->{$s} eq 'HASH';
                        }
                    }
                } catch {
                    $self->logging->log_with_details($c, 'warning', __FILE__, __LINE__, 'change_password',
                        "Config files written but in-memory cache refresh failed: $_");
                };
                my $nfiles = scalar @$updated;
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'change_password',
                    "Password updated for slot $conn_name (files=$nfiles rotate_server=$rotate siblings=$sibs) — value not logged");
                $c->flash->{success_msg} = $rotate
                    ? "Password changed on the database server and stored for $conn_name."
                    : "Stored password updated for $conn_name. Server user was not changed.";
                $c->response->redirect($c->uri_for($self->action_for('detail'), [$conn_name]));
                return;
            } catch {
                $ok = 0;
                my $err = $_;
                $err =~ s/\s+at \S+ line \d+.*//s;
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'change_password',
                    "Password change failed for $conn_name: $err");
                $c->stash(error_msg => "Password change failed: $err");
            };
        }
    }

    $c->stash(
        template       => 'remotedb/change_password.tt',
        conn_name      => $conn_name,
        conn           => $all->{$conn_name},
        sibling_slots  => \@siblings,
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
        # Get the path to the config file
        my $config_file = $c->path_to('db_config.json');
        
        # Read the current configuration
        local $/;
        open my $fh, "<", $config_file or die "Could not open $config_file: $!";
        my $json_text = <$fh>;
        close $fh;
        
        my $config = decode_json($json_text);
        
        # Initialize remote_connections if it doesn't exist
        $config->{remote_connections} ||= {};
        
        # Add or update the connection
        $config->{remote_connections}{$conn_name} = $conn_config;
        
        # Write the updated configuration back to the file
        open $fh, ">", $config_file or die "Could not open $config_file for writing: $!";
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
        # Get the path to the config file
        my $config_file = $c->path_to('db_config.json');
        
        # Read the current configuration
        local $/;
        open my $fh, "<", $config_file or die "Could not open $config_file: $!";
        my $json_text = <$fh>;
        close $fh;
        
        my $config = decode_json($json_text);
        
        # Remove the connection if it exists
        if ($config->{remote_connections} && exists $config->{remote_connections}{$conn_name}) {
            delete $config->{remote_connections}{$conn_name};
        }
        
        # Write the updated configuration back to the file
        open $fh, ">", $config_file or die "Could not open $config_file for writing: $!";
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