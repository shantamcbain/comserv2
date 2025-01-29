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
    # Debug logging for begin action
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'begin', "Starting begin action");

    $c->stash->{debug_errors} //= [];  # Ensure debug_errors is initialized

    # Check if the user is logged in
    if ( !$c->user_exists ) {
        $self->index($c);
    } else {
        # Fetch the roles from the session
        my $roles = $c->session->{roles};

        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'begin', "Roles: " . Dumper($roles));

        # Check if roles is defined and is an array reference
        if ( defined $roles && ref $roles eq 'ARRAY' ) {
            if ( !grep { $_ eq 'admin' } @$roles ) {
                $self->index($c);
            }
        } else {
            $self->index($c);
        }
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

sub edit_documentation :Path('edit_documentation') :Args(0) {
    my ( $self, $c ) = @_;

    if ($c->req->method eq 'POST') {
        my $params = $c->req->params;
        my $schema = $c->model('DBEncy');

        $schema->resultset('Documentation')->create({
            title => $params->{title}, content => $params->{content}, section => $params->{section}, version => $params->{version}, created_by => $c->user->id, updated_by => $c->user->id,
        });
    }

    $c->stash(template => 'admin/edit_documentation.tt');
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

sub map_table_to_result :Path('/admin/map_table_to_result') :Args(0) {
    my ($self, $c) = @_;

    # Get database and table from request
    my $selected_db = $c->req->param('database') || 'ENCY';
    my $table       = $c->req->param('table');
    my $model       = $selected_db eq 'FORAGER' ? 'DBForager' : 'DBEncy';

    # Fetch table columns
    my $columns;
    eval {
        $columns = $c->model($model)->get_table_columns($table);
    };
    if ($@) {
        # Handle error if column retrieval fails
        $c->stash(
            error_msg => "Failed to fetch columns for table '$table': $@",
            template  => 'admin/SchemaManager.tt',
        );
        return;
    }

    # Generate or update result file for the table
    my $result_file = "lib/Comserv/Model/Result/" . ucfirst($table) . ".pm";
    if (!-e $result_file || $c->req->param('update')) {
        $self->generate_result_file($table, $columns, $result_file);
    }

    # Set success message and redirect
    $c->flash->{success} = "Result file for table '$table' updated successfully!";
    $c->response->redirect('/Admin/schema_manager?database=' . $selected_db);
}

# Generate or update a result file
sub generate_result_file {
    my ($self, $table, $columns, $file_path) = @_;

    my $content = <<"EOF";
package Comserv::Model::Result::${table};
use base qw/DBIx::Class::Core/;

__PACKAGE__->table('$table');

# Define columns
EOF

    foreach my $column (@$columns) {
        my $nullable = $column->{nullable} eq 'YES' ? '1' : '0';
        $content .= "__PACKAGE__->add_columns(q{$column->{name}}, { data_type => q{$column->{type}}, is_nullable => $nullable });\n";
    }

    $content .= "\n1;\n";

    # Write the result file
    open my $fh, '>', $file_path or die $!;
    print $fh $content;
    close $fh;
}

# Action to handle table-to-result mapping
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

# Get table information
sub get_table_info :Path('admin/get_table_info') :Args(1) {
    my ($self, $c, $table_name) = @_;
    # Debug logging for get_table_info action
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, "Starting get_table_info action");

    my $table_info = $c->model('DBEncy')->get_table_info($table_name);
    $c->stash(
        table_info => $table_info,
        error      => $table_info ? undef : "The table $table_name does not exist.",
        template   => 'admin/get_table_info.tt'
    );

    $c->forward($c->view('TT'));
}

# Add AutoCRUD actions
sub autocrud_list :Local :Args(1) {
    my ($self, $c, $table) = @_;
    $c->stash(
        template => 'admin/autocrud_list.tt',
        table => $table,
        records => $c->model('DBEncy')->resultset($table)->all
    );
}

sub autocrud_edit :Local :Args(2) {
    my ($self, $c, $table, $id) = @_;
    my $record = $id eq 'new' ? undef :
        $c->model('DBEncy')->resultset($table)->find($id);

    $c->stash(
        template => 'admin/autocrud_edit.tt',
        table => $table,
        record => $record
    );
}

sub list_migrations :Path('list_migrations') :Args(0) {
    my ($self, $c) = @_;
    my $migrations_dir = $c->path_to('script', 'migrations');

    my @migration_files;
    if (-d $migrations_dir) {
        opendir(my $dh, $migrations_dir) || die "Can't open directory: $!";
        @migration_files = sort grep { /^\d{4}_.*\.pl$/ } readdir($dh);
        closedir $dh;
    }

    $c->stash(
        migration_files => \@migration_files,
        migrations_dir => $migrations_dir,
        template => 'admin/list_migrations.tt'
    );
    $c->forward($c->view('TT'));
}

sub view_migration :Path('view_migration') :Args(1) {
    my ($self, $c, $filename) = @_;
    my $migrations_dir = $c->path_to('script', 'migrations');
    my $file_path = "$migrations_dir/$filename";

    if (-f $file_path) {
        open my $fh, '<', $file_path or die "Cannot open $file_path: $!";
        my $content = do { local $/; <$fh> };
        close $fh;

        $c->stash(
            migration_content => $content,
            template => 'admin/view_migration.tt'
        );
    } else {
        $c->stash(error_msg => "Migration file not found");
    }
}

sub run_migration :Path('run_migration') :Args(1) {
    my ($self, $c, $filename) = @_;
    my $migrations_dir = $c->path_to('script', 'migrations');
    system("perl $migrations_dir/$filename") == 0
        or $c->stash(error_msg => "Failed to run migration: $!");
    $c->response->redirect($c->uri_for($self->action_for('list_migrations')));
}

__PACKAGE__->meta->make_immutable;
1;
