package Comserv::Controller::Admin;
use Moose;
use namespace::autoclean;
use Data::Dumper;
use Comserv::Model::DBSchemaManager;

BEGIN { extends 'Catalyst::Controller'; }

sub begin : Private {
    my ( $self, $c ) = @_;

    # Check if the user is logged in
    if (!$c->user_exists) {
        # If the user isn't logged in, call the index method
        $self->index($c);
        return;
    }
    # Fetch the roles from the session
    my $roles = $c->session->{roles};
    # Log the roles
    $c->log->info("admin begin Roles: " . Dumper($roles));  # Change this line
    # Check if roles is defined and is an array reference
    if (defined $roles && ref $roles eq 'ARRAY') {
        # Check if the user has the 'admin' role
        if (grep { $_ eq 'admin' } @$roles) {
            # User is an admin, proceed with the request
        } else {
            # User is not an admin, call the index method
            $self->index($c);
            return;
        }
    } else {
        # Roles is not defined or not an array, call the index method
        $self->index($c);
        return;
    }
}

sub index :Path :Args(0) {
    my ($self, $c) = @_;

    # Check database connection
    my $schema = $c->model('DB');
    eval {
        $schema->storage->ensure_connected;
    };
    if ($@) {
        push @{$c->stash->{error_msg}}, "DBI error - DBI connect failed: $@";
    }

    # Set the TT template to use.
    $c->stash(template => 'admin/index.tt');

    # Forward to the view
    #$c->forward($c->view('TT'));
    $c->forward('View::TT');

}

sub edit_documentation :Path('/edit_documentation') :Args(0) {
    my ( $self, $c ) = @_;
    $c->stash(template => 'admin/edit_documentation.tt');
}

sub add_schema :Path('/add_schema') :Args(0) {
    my ( $self, $c ) = @_;

    if ($c->request->method eq 'POST') {
        # Get the schema name and description from the form
        my $schema_name = $c->request->params->{schema_name};
        my $schema_description = $c->request->params->{schema_description};

        # Run the create_migration_script.pl script
        my $output = `create_migration_script.pl $schema_name $schema_description`;

        # Check if the script ran successfully
        if ($? == 0) {
            $c->stash(message => 'Migration script created successfully.');
        } else {
            $c->stash(message => 'Failed to create migration script.');
        }

        # Add the output to the stash so it can be displayed in the template
        $c->stash(output => $output);
    }

    $c->stash(template => 'admin/add_schema.tt');
}

sub check_and_update_schema {
    my ($self) = @_;

    try {
        my $schema = Comserv::Model::DBEncy->new->schema;
        my $dbh = $schema->storage->dbh;

        # Check if the schema is up-to-date
        my $tables_exist = $dbh->selectrow_array("SHOW TABLES LIKE 'sitedomain'");

        if ($tables_exist) {
            my $differences = $self->compare_schemas();
            if (@$differences) {
                $self->{schema_needs_update} = 1;
            } else {
                $self->{schema_needs_update} = 0;
            }
        } else {
            $self->deploy_schema();
            $self->{schema_needs_update} = 0;
        }
    } catch {
        ERROR("Error in check_and_update_schema: $_");
        $self->{schema_needs_update} = 1;
    };
}

sub schema_needs_update {
    my ($self) = @_;
    return $self->{schema_needs_update};
}
sub toggle_debug :Path('/toggle_debug') :Args(0) {
    my ( $self, $c ) = @_;

    # Toggle the CATAYST_DEBUG environment variable
    if ($ENV{CATALYST_DEBUG} // 0) {
        $ENV{CATALYST_DEBUG} = 0;
    } else {
        $ENV{CATALYST_DEBUG} = 1;
    }

    # Redirect to the admin index page
    $c->response->redirect($c->uri_for('/admin'));
}

sub get_table_info :Path('/get_table_info') :Args(1) {
    my ($self, $c, $table_name) = @_;

    # Get the table info from the DBEncy model
    my $table_info = $c->model('DBEncy')->get_table_info($table_name);

    if ($table_info) {
        # The table exists, display its schema
        $c->stash(table_info => $table_info);
    } else {
        # The table does not exist, display an error message
        $c->stash(error => "The table $table_name does not exist.");
    }

    $c->stash(template => 'admin/get_table_info.tt');
}
sub schema_update :Local {
    my ($self, $c) = @_;

    my $db_schema_manager = Comserv::Model::DBSchemaManager->new();
    my $differences = $db_schema_manager->compare_schemas();

    $c->stash(
        differences => $differences,
        template    => 'admin/schema_update.tt2'
    );
}

sub apply_schema_update :Local {
    my ($self, $c) = @_;

    my $action = $c->req->params->{action};
    my $db_schema_manager = Comserv::Model::DBSchemaManager->new();

    if ($action eq 'deploy') {
        $db_schema_manager->deploy_schema();
    } elsif ($action eq 'update') {
        $db_schema_manager->update_schema();
    }

    $c->response->redirect($c->uri_for('/admin/schema_update'));
}

__PACKAGE__->meta->make_immutable;

1;