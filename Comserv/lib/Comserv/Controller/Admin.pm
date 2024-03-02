package Comserv::Controller::Admin;
use Moose;
use namespace::autoclean;
use Data::Dumper;
BEGIN { extends 'Catalyst::Controller'; }

sub begin : Private {
    my ( $self, $c ) = @_;

    # Check if the user is logged in
    if (!$c->user_exists) {
        $c->response->redirect($c->uri_for('/user/login'));
        $c->detach();
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
            # User is not an admin, redirect to error page
        #    $c->response->redirect($c->uri_for('/error'));
            $c->detach();
        }
    } else {
        # Roles is not defined or not an array, redirect to error page
       # $c->response->redirect($c->uri_for('/index'));
        $c->detach();
    }
}

sub index :Path :Args(0) {
    my ( $self, $c ) = @_;

    # Log the application's configured template path
    $c->log->debug("Template path: " . $c->path_to('root'));

    # Set the TT template to use.
    $c->stash(template => 'Admin/index.tt');

    # Forward to the view
    $c->forward($c->view('TT'));
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
sub migrate_schema :Path('/migrate_schema') :Args(0) {
    my ( $self, $c ) = @_;

    if ($c->request->method eq 'POST') {
        # Run the migration script
        my $output = `perl Comserv/script/migrate_schema.pl`;

        # Add the output to the stash so it can be displayed in the template
        $c->stash(output => $output);
    }
{
        # Run the migration script
        my $output = `perl Comserv/script/migrate_schema.pl`;

        # Check if the script ran successfully
        if ($? == 0) {
            $c->stash(message => 'Schema migrated successfully.');
        } else {
            $c->stash(message => 'Failed to migrate schema.');
        }
    }

    $c->stash(template => 'admin/add_schema.tt');
}
__PACKAGE__->meta->make_immutable;

1;
