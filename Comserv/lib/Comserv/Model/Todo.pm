package Comserv::Model::Todo;
use Moose;
use namespace::autoclean;
use Data::Dumper;

extends 'Catalyst::Model';
has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

sub get_top_todos {
    my ($self, $c, $SiteName) = @_;

    # Refactor line 16 to handle roles safely
    my $roles = $c->session->{roles} || [];

    # Validate that roles are an array reference
    if (ref $roles ne 'ARRAY') {
        # Log the error
        $c->log->error("Expected roles to be an ARRAY but got: " . ref($roles) || 'undef');

        # Set an error message and return gracefully
        $c->stash->{error_msg} = "Invalid roles format in session. Please log in again.";
        $c->res->redirect($c->uri_for('/login'));
        $c->detach;
    }

    # Safely dereference roles
    my @roles = @$roles;

    # Log the roles being used (debugging information)
    $c->log->debug("Roles available for Todo: " . join(', ', @roles));

    # Example: Check if user is an admin
    if (grep { $_ eq 'admin' } @roles) {
        $c->log->debug("User has admin privilege.");
        # Allow some admin-specific logic
    } else {
        $c->log->debug("User does not have admin privilege.");
        # Handle non-admin logic
    }

    $SiteName = $c->session->{'SiteName'};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_top_todos', "Site name: $SiteName");

    # Get a DBIx::Class::Schema object
    my $schema = $c->model('DBEncy');

    # Get a DBIx::Class::ResultSet object for the 'Todo' table
    my $rs = $schema->resultset('Todo');

    # Fetch the top 10 todos for the given site, ordered by priority and start_date
    # Add a condition to only fetch todos where status is not 3
    my @todos = $rs->search(
        { sitename => $SiteName, status => { '!=' => 3 } },
        { order_by => { -asc => ['priority', 'start_date'] }, rows => 10 }
    );

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_top_todos','Visited the todo page');
    $c->session(todos => \@todos);

    return \@todos;
}

sub get_todos_for_date {
    my ($self, $c, $date) = @_;

    # Check if the user has the 'admin' role
    unless (grep { $_ eq 'admin' } @{$c->session->{roles}}) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'get_todos_for_date', 'Unauthorized access attempt by non-admin user');
        return []; # Return an empty list if the user is not an admin
    }

    my $SiteName = $c->session->{SiteName};

    # Get a DBIx::Class::Schema object
    my $schema = $c->model('DBEncy');

    # Get a DBIx::Class::ResultSet object for the 'Todo' table
    my $rs = $schema->resultset('Todo');

    # Fetch todos whose start date is on or before the given date and status is not 3
    my @todos = $rs->search(
        { start_date => { '<=' => $date }, status => { '!=' => 3 }, sitename => $SiteName },
        { order_by => { -asc => ['priority', 'start_date'] } }
    );

    return \@todos;
}


sub fetch_todo_record {
    my ($self, $c, $record_id) = @_;
    my $schema = $c->model('DBEncy');

    # Get a DBIx::Class::ResultSet object for the 'Todo' table
    my $rs = $schema->resultset('Todo');

    # Fetch the todo record based on $record_id
    my $todo_record = $rs->find($record_id);
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, "Fetched todo record");
    return $todo_record;
}

__PACKAGE__->meta->make_immutable;

1;
