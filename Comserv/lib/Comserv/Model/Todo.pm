package Comserv::Model::Todo;
use Moose;
use namespace::autoclean;
use Data::Dumper;  # Add this line
extends 'Catalyst::Model';


# In your Todo.pm file
# In your Todo.pm file
# In your Todo.pm file
sub get_top_todos {
    my ($self, $c, $SiteName) = @_;
    $SiteName = $c -> session -> {'SiteName'};
    $c->log->debug("Site name: $SiteName");

    # Get a DBIx::Class::Schema object
    my $schema = $c->model('DBEncy');

    # Get a DBIx::Class::ResultSet object for the 'Todo' table
    my $rs = $schema->resultset('Todo');

    # Fetch the top 10 todos for the given site, ordered by priority and due_date
    # Add a condition to only fetch todos where status is not 3
    # Order by priority and start_date
    my @todos = $rs->search(
        { sitename => $SiteName, status => { '!=' => 3 } },
        { order_by => { -asc => ['priority', 'start_date'] }, rows => 10 }
    );

    $c->log->debug('Visited the todo page');
    # Log the number of todos fetched
    $c->log->debug("Number of todos fetched: " . scalar(@todos));

    # Log the actual data of the todos
    foreach my $todo (@todos) {
        #$c->log->debug("Todo: " . Dumper($todo));
    }

    $c->session(todos => \@todos);
    # Fetch the todos from the session

    my $todos = $c->session->{todos};

    return \@todos;
}
sub get_todos_for_date {
    my ($self, $c, $date) = @_;
   # Get the SiteName from the session
    my $SiteName = $c->session->{SiteName};

    # Get a DBIx::Class::Schema object
    my $schema = $c->model('DBEncy');

    # Get a DBIx::Class::ResultSet object for the 'Todo' table
    my $rs = $schema->resultset('Todo');

    # Fetch todos whose start date is on or before the given date and status is not 3
    # Order by priority and start_date
    my @todos = $rs->search(
        { start_date => { '<=' => $date }, status => { '!=' => 3 }, sitename => $SiteName },
        { order_by => { -asc => ['priority', 'start_date'] } }
    );

    return \@todos;
}
sub fetch_todo_record {
    my ($self, $c, $record_id) = @_;
    # Get a DBIx::Class::Schema object
    my $schema = $c->model('DBEncy');

    # Get a DBIx::Class::ResultSet object for the 'Todo' table
    my $rs = $schema->resultset('Todo');

    # Fetch the todo record based on $record_id
    my $todo_record = $rs->find($record_id);
    return $todo_record;
}
__PACKAGE__->meta->make_immutable;

1;
