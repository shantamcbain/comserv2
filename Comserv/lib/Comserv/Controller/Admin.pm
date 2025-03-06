package Comserv::Controller::Admin;
use Moose;
use namespace::autoclean;
use Data::Dumper;
use DBIx::Class::Migration;
use Comserv::Util::Logging;
BEGIN { extends 'Catalyst::Controller'; }

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

# Authentication check at the beginning of each request

sub begin : Private {
    my ( $self, $c ) = @_;
    warn "Entering Comserv::Controller::Admin::begin\n";
    # Debug logging for begin action
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'begin', "Starting begin action");
    $c->stash->{debug_errors} //= []; # Ensure debug_errors is initialized

    # Add debug information to the stash
    $c->stash->{debug_info} = {
        user_exists => $c->user_exists ? 'Yes' : 'No',
        session_id => $c->sessionid,
        session_data => $c->session,
        roles => $c->session->{roles},
    };

    # Check if the user is logged in
#    if ( !$c->user_exists ) {
#        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'begin', "User not logged in, redirecting to home.");
#        $c->flash->{error} = 'You must be logged in to access the admin area.';
#        $c->response->redirect($c->uri_for('/'));
#        return;
#    }

    # Fetch the roles from the session
    my $roles = $c->session->{roles};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'begin', "Roles: " . Dumper($roles));

    # Check if roles is defined and is an array reference
    if ( defined $roles && ref $roles eq 'ARRAY' ) {
        # Log the roles being checked
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'begin', "Checking roles: " . join(", ", @$roles));

        # Directly check for 'admin' role using grep
        if ( grep { $_ eq 'admin' } @$roles ) {
            # User is admin, proceed with accessing the admin area
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'begin', "Admin user detected, proceeding.");
            return; # Important: Return to allow admin to proceed
        } else {
            # User is not admin, redirect to home
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'begin', "Non-admin user, redirecting to home. Roles found: " . join(", ", @$roles));
            $c->flash->{error} = 'You do not have permission to access the admin area. Required role: admin. Your roles: ' . join(", ", @$roles);
            $c->response->redirect($c->uri_for('/'));
            return;
        }
    } else {
        # Log that roles are not defined or not an array
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'begin', "No roles defined or roles is not an array, redirecting to home.");
        $c->flash->{error} = 'You do not have permission to access the admin area. No roles defined or roles is not an array.';
        $c->response->redirect($c->uri_for('/'));
        return;
    }
}

# Main admin page
sub index :Path :Args(0) {
    my ( $self, $c ) = @_;
    # Debug logging for index action
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Starting index action");

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Template path: " . $c->path_to('root'));
    $c->stash(template => 'admin/index.tt');
    $c->forward($c->view('TT'));
}

# Add a new schema
sub add_schema :Path('add_schema') :Args(0) {
    my ( $self, $c ) = @_;
    # Debug logging for add_schema action
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_schema', "Starting add_schema action");

    if ( $c->request->method eq 'POST' ) {
        my $migration = DBIx::Class::Migration->new(
            schema_class => 'Comserv::Model::Schema::Ency',
            target_dir   => $c->path_to('root', 'migrations')->stringify
        );

        my $schema_name        = $c->request->params->{schema_name} // '';
        my $schema_description = $c->request->params->{schema_description} // '';

        if ( $schema_name ne '' && $schema_description ne '' ) {
            eval {
                $migration->make_schema;
                $c->stash(message => 'Migration script created successfully.');
            };
            if ($@) {
                $c->stash(error_msg => 'Failed to create migration script: ' . $@);
            }
        } else {
            $c->stash(error_msg => 'Schema name and description cannot be empty.');
        }
    }

    $c->stash(template => 'admin/add_schema.tt');
    $c->forward($c->view('TT'));
}

sub schema_manager :Path('/admin/schema_manager') :Args(0) {
    my ($self, $c) = @_;

    # Log the beginning of the schema_manager action
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'schema_manager', "Starting schema_manager action");

    # Get the selected database (default to 'ENCY')
    my $selected_db = $c->req->param('database') || 'ENCY';
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'schema_manager', "Selected database: $selected_db");

    # Determine the model to use
    my $model = $selected_db eq 'FORAGER' ? 'DBForager' : 'DBEncy';

    # Attempt to fetch list of tables from the selected model
    my $tables;
    eval {
        # Corrected line to pass the selected database to list_tables
        $tables = $c->model('DBSchemaManager')->list_tables($c, $selected_db);
    };
    if ($@) {
        # Log the table retrieval error
        $self->logging->log_with_details(
            $c,
            'error',
            __FILE__,
            __LINE__,
            'schema_manager',
            "Failed to list tables for database '$selected_db': $@"
        );

        # Set error message in stash and render error template
        $c->stash(
            error_msg => "Failed to list tables for database '$selected_db': $@",
            template  => 'admin/SchemaManager.tt',
        );
        $c->forward($c->view('TT'));
        return;
    }

    # Log successful table retrieval
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'schema_manager', "Successfully retrieved tables for '$selected_db'");

    # Pass data to the stash for rendering the SchemaManager template
    $c->stash(
        database  => $selected_db,
        tables    => $tables,
        template  => 'admin/SchemaManager.tt',
    );

    $c->forward($c->view('TT'));
}

sub map_table_to_result :Path('/Admin/map_table_to_result') :Args(0) {
    my ($self, $c) = @_;

    my $database = $c->req->param('database');
    my $table    = $c->req->param('table');

    # Check if the result file exists
    my $result_file = "lib/Comserv/Model/Result/" . ucfirst($table) . ".pm";
    my $file_exists = -e $result_file;

    # Fetch table columns
    my $columns = $c->model('DBSchemaManager')->get_table_columns($database, $table);

    # Generate or update the result file based on the table schema
    if (!$file_exists || $c->req->param('update')) {
        $self->generate_result_file($table, $columns, $result_file);
    } else {
        # Here you could add logic to compare schema if both exist:
        # my $existing_schema = $self->read_schema_from_file($result_file);
        # my $current_schema = $columns;  # Assuming $columns represents current schema
        # if ($self->schemas_differ($existing_schema, $current_schema)) {
        #     # Log or display differences
        #     # Optionally offer to normalize (update file or suggest database change)
        # }
    }

    $c->flash->{success} = "Result file for table '$table' has been successfully updated!";
    $c->response->redirect('/Admin/schema_manager');
}

# Helper to generate or update a result file
sub generate_result_file {
    my ($self, $table, $columns, $file_path) = @_;

    my $content = <<"EOF";
package Comserv::Model::Result::${table};
use base qw/DBIx::Class::Core/;

__PACKAGE__->table('$table');

# Define columns
EOF

    foreach my $column (@$columns) {
        $content .= "__PACKAGE__->add_columns(q{$column->{name}});\n";
    }

    $content .= "\n1;\n";

    # Write the file
    open my $fh, '>', $file_path or die $!;
    print $fh $content;
    close $fh;
}

# Compare schema versions
sub compare_schema :Path('compare_schema') :Args(0) {
    my ($self, $c) = @_;
    # Debug logging for compare_schema action
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'compare_schema', "Starting compare_schema action");

    my $migration = DBIx::Class::Migration->new(
        schema_class => 'Comserv::Model::Schema::Ency',
        target_dir   => $c->path_to('root', 'migrations')->stringify
    );

    my $current_version = $migration->version;
    my $db_version;

    eval {
        $db_version = $migration->schema->resultset('dbix_class_schema_versions')->find({ version => { '!=' => '' } })->version;
    };

    $db_version ||= '0';  # Default if no migrations have been run
    my $changes = ( $current_version != $db_version )
        ? "Schema version mismatch detected. Check migration scripts for changes from $db_version to $current_version."
        : "No changes detected between schema and database.";

    $c->stash(
        current_version => $current_version,
        db_version      => $db_version,
        changes         => $changes,
        template        => 'admin/compare_schema.tt'
    );

    $c->forward($c->view('TT'));
}

# Migrate schema if changes are confirmed
sub migrate_schema :Path('migrate_schema') :Args(0) {
    my ($self, $c) = @_;
    # Debug logging for migrate_schema action
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'migrate_schema', "Starting migrate_schema action");

    if ( $c->request->method eq 'POST' ) {
        my $migration = DBIx::Class::Migration->new(
            schema_class => 'Comserv::Model::Schema::Ency',
            target_dir   => $c->path_to('root', 'migrations')->stringify
        );

        my $confirm = $c->request->params->{confirm};
        if ($confirm) {
            eval {
                $migration->install;
                $c->stash(message => 'Schema migration completed successfully.');
            };
            if ($@) {
                $c->stash(error_msg => "An error occurred during migration: $@");
            }
        } else {
            $c->res->redirect($c->uri_for($self->action_for('compare_schema')));
        }
    }

    $c->stash(
        message   => $c->stash->{message} || '',
        error_msg => $c->stash->{error_msg} || '',
        template  => 'admin/migrate_schema.tt'
    );

    $c->forward($c->view('TT'));
}

# Edit documentation action
sub edit_documentation :Path('admin/edit_documentation') :Args(0) {
    my ( $self, $c ) = @_;
    # Debug logging for edit_documentation action
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_documentation', "Starting edit_documentation action");
    $c->stash(template => 'admin/edit_documentation.tt');
    $c->forward($c->view('TT'));
}

# Run a script from the script directory
sub run_script :Path('/admin/run_script') :Args(0) {
    my ($self, $c) = @_;

    # Debug logging for run_script action
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'run_script', "Starting run_script action");

    # Check if the user has the admin role
    unless ($c->user_exists && grep { $_ eq 'admin' } @{$c->session->{roles}}) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'run_script', "Unauthorized access attempt by user: " . ($c->session->{username} || 'Guest'));
        $c->flash->{error} = "You must be an admin to perform this action";
        $c->response->redirect($c->uri_for('/'));
        return;
    }

    # Get the script name from the request parameters
    my $script_name = $c->request->params->{script};

    # Validate the script name
    unless ($script_name && $script_name =~ /^[\w\-\.]+\.pl$/) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'run_script', "Invalid script name: " . ($script_name || 'undefined'));
        $c->flash->{error} = "Invalid script name";
        $c->response->redirect($c->uri_for('/admin'));
        return;
    }

    # Path to the script
    my $script_path = $c->path_to('script', $script_name);

    # Check if the script exists
    unless (-e $script_path) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'run_script', "Script not found: $script_path");
        $c->flash->{error} = "Script not found: $script_name";
        $c->response->redirect($c->uri_for('/admin'));
        return;
    }

    if ($c->request->method eq 'POST' && $c->request->params->{confirm}) {
        # Execute the script
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'run_script', "Executing script: $script_path");
        my $output = qx{perl $script_path 2>&1};
        my $exit_code = $? >> 8;

        if ($exit_code == 0) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'run_script', "Script executed successfully. Output: $output");
            $c->flash->{message} = "Script executed successfully. Output: $output";
        } else {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'run_script', "Error executing script: $output");
            $c->flash->{error} = "Error executing script: $output";
        }

        $c->response->redirect($c->uri_for('/admin'));
        return;
    }

    # Display confirmation page
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'run_script', "Displaying confirmation page for script: $script_name");
    $c->stash(
        script_name => $script_name,
        template => 'admin/run_script.tt',
    );
    $c->forward($c->view('TT'));
}

# Get table information
sub view_log :Path('/admin/view_log') :Args(0) {
    my ($self, $c) = @_;

    # Debug logging for view_log action
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view_log', "Starting view_log action");

    # Path to the application log file
    my $log_file = $c->path_to('logs', 'application.log');

    # Check if the log file exists
    unless (-e $log_file) {
        $c->stash(
            error_msg => "Log file not found: $log_file",
            template  => 'admin/view_log.tt',
        );
        $c->forward($c->view('TT'));
        return;
    }

    # Read the log file
    my $log_content;
    {
        local $/; # Enable slurp mode
        open my $fh, '<', $log_file or die "Cannot open log file: $!";
        $log_content = <$fh>;
        close $fh;
    }

    # Pass the log content to the template
    $c->stash(
        log_content => $log_content,
        template    => 'admin/view_log.tt',
    );

    $c->forward($c->view('TT'));
}
__PACKAGE__->meta->make_immutable;
1;
