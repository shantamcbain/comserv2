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
    $SiteName = $c->session->{'SiteName'};
    $self->logging->log_with_details($c, __FILE__, __LINE__, 'get_top_todos', "Site name: $SiteName");

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

    $self->logging->log_with_details($c, __FILE__, __LINE__, 'get_top_todos','Visited the todo page');
    #$self->logging->log_with_details($c, __FILE__, __LINE__, "Number of todos fetched: " . scalar(@todos));

    $c->session(todos => \@todos);

    return \@todos;
}

sub get_todos_for_date {
    my ($self, $c, $date) = @_;
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
    $self->logging->log_with_details($c, __FILE__, __LINE__, "Fetched todo record");
    return $todo_record;
}

__PACKAGE__->meta->make_immutable;

1;
