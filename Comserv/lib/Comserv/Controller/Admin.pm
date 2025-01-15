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
    $self->logging->log_with_details($c, __FILE__, __LINE__, 'begin', "Starting begin action");

    $c->stash->{debug_errors} //= [];  # Ensure debug_errors is initialized

    # Check if the user is logged in
    if ( !$c->user_exists ) {
        $self->index($c);
    } else {
        # Fetch the roles from the session
        my $roles = $c->session->{roles};
        $c->log->info("admin begin Roles: " . Dumper($roles));

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
    $self->logging->log_with_details($c, __FILE__, __LINE__, 'index', "Starting index action");
    $c->log->debug("Template path: " . $c->path_to('root'));
    $c->stash(template => 'admin/index.tt');
    $c->forward($c->view('TT'));
}

# Add a new schema
sub add_schema :Path('add_schema') :Args(0) {
    my ( $self, $c ) = @_;
    # Debug logging for add_schema action
    $self->logging->log_with_details($c, __FILE__, __LINE__, 'add_schema', "Starting add_schema action");

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

# Compare schema versions
sub compare_schema :Path('compare_schema') :Args(0) {
    my ($self, $c) = @_;
    # Debug logging for compare_schema action
    $self->logging->log_with_details($c, __FILE__, __LINE__, 'compare_schema', "Starting compare_schema action");

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
    $self->logging->log_with_details($c, __FILE__, __LINE__, 'migrate_schema', "Starting migrate_schema action");

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
    $self->logging->log_with_details($c, __FILE__, __LINE__, 'edit_documentation', "Starting edit_documentation action");
    $c->stash(template => 'admin/edit_documentation.tt');
    $c->forward($c->view('TT'));
}

# Get table information
sub get_table_info :Path('admin/get_table_info') :Args(1) {
    my ($self, $c, $table_name) = @_;
    # Debug logging for get_table_info action
    $self->logging->log_with_details($c, __FILE__, __LINE__, "Starting get_table_info action");

    my $table_info = $c->model('DBEncy')->get_table_info($table_name);
    $c->stash(
        table_info => $table_info,
        error      => $table_info ? undef : "The table $table_name does not exist.",
        template   => 'admin/get_table_info.tt'
    );

    $c->forward($c->view('TT'));
}

__PACKAGE__->meta->make_immutable;
1;
