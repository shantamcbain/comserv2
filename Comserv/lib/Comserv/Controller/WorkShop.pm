package Comserv::Controller::WorkShop;
use Moose;
use namespace::autoclean;

BEGIN { extends 'Catalyst::Controller'; }

# In Workshop Controller
sub index :Path :Args(0) {
    my ( $self, $c ) = @_;

    # Get the active workshops and any error message
    my ($workshops, $error) = $c->model('WorkShop')->get_active_workshops($c);

      # Get the file for each workshop
    for my $workshop (@$workshops) {
        my @file = $c->model('DBEncy::File')->search({ workshop_id => $workshop->id });
        $workshop->{file} = \@file;
    }

    # Pass the workshops and the error message to the view
    $c->stash(
        workshops => $workshops,
        error => $error,
        sitename => $c->session->{SiteName},
        template => 'WorkShops/workshops.tt',
    );# Pass the workshops and the error message to the view

$c->stash(
        workshops => $workshops, error => $error,
        sitename => $c->session->{SiteName},
        template => 'WorkShops/workshops.tt',

    );
 }
sub add :Local {
    my ( $self, $c ) = @_;

    # Set the TT template to use
    $c->stash->{template} = 'WorkShops/addworkshop.tt';
}
sub addworkshop :Local {
    my ( $self, $c ) = @_;

    # Retrieve the form data from the request
    my $params = $c->request->parameters;

    # Validate the form data
    if (!validate_form_data($params)) {
        $c->stash->{error_msg} = 'Invalid form data';
        $c->stash->{form_data} = $params;  # Add the form data to the stash
        $c->stash->{template} = 'WorkShops/addworkshop.tt';
        return;
    }

    # Get a DBIx::Class::Schema object
    my $schema = $c->model('DBEncy');

    # Get a DBIx::Class::ResultSet object
    my $rs = $schema->resultset('WorkShop');

    # Try to create a new workshop record
    my $workshop;
    eval {
        $workshop = $rs->create({
            sitename => $params->{sitename},
            title => $params->{title},
            description => $params->{description},
            date => $params->{dateOfWorkshop},
            location => $params->{location},
            instructor => $params->{instructor},
            max_participants => $params->{maxMinAttendees},
            share => $params->{share},
            end_time => $params->{end_time},
            time => $params->{time},
        });
    };
    if ($@) {
        $c->stash->{error_msg} = 'Failed to create workshop: ' . $@;
        $c->stash->{form_data} = $params;  # Add the form data to the stash
        $c->stash->{template} = 'WorkShops/addworkshop.tt';
        return;
    }



    # Redirect the user to the index action
    $c->response->redirect($c->uri_for($self->action_for('index')));
}

sub validate_form_data {
    my ($params) = @_;

    # Initialize an errors hash
    my %errors;

    # Check if sitename is defined and not empty
    if (!defined $params->{sitename} || $params->{sitename} eq '') {
        $errors{sitename} = 'Sitename is required';
    }

    # Check if title is defined and not empty
    if (!defined $params->{title} || $params->{title} eq '') {
        $errors{title} = 'Title is required';
    }

    # Check if description is defined and not empty
    if (!defined $params->{description} || $params->{description} eq '') {
        $errors{description} = 'Description is required';
    }

    # Check if date is a valid date
    if (!defined $params->{dateOfWorkshop} || $params->{dateOfWorkshop} !~ /^\d{4}-\d{2}-\d{2}$/) {
        $errors{dateOfWorkshop} = 'Invalid date';
    }
    # Check if time is a valid time
    if (!defined $params->{time} || $params->{time} !~ /^\d{2}:\d{2}$/) {
        $errors{time} = 'Invalid time';
    }
   # Add more checks for the other fields...

    # If there are any errors, return 0 and the errors hash
    if (%errors) {
        return (0, \%errors);
    }

    # If there are no errors, return 1
    return 1;
}

__PACKAGE__->meta->make_immutable;

1;
