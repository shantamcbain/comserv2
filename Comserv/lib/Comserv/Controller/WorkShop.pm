package Comserv::Controller::WorkShop;
use Moose;
use namespace::autoclean;
use Data::FormValidator;
BEGIN { extends 'Catalyst::Controller'; }

# In Workshop Controller
sub index :Path :Args(0) {
    my ( $self, $c ) = @_;

  # Try to get the active workshops and catch any exceptions
my ($workshops, $error);

    ($workshops, $error) = $c->model('WorkShop')->get_active_workshops($c);



# Continue with the rest of your code...
    # Get the file for each workshop and convert each workshop to a hash
    my @workshops_hash;
    for my $workshop (@$workshops) {
        my @file = $c->model('DBEncy::File')->search({ workshop_id => $workshop->id });

        # Convert the workshop object to a hash
        my %workshop_hash = $workshop->get_columns;
        $workshop_hash{file} = \@file;

        push @workshops_hash, \%workshop_hash;
    }

    # Pass the workshops and the error message to the view
    $c->stash(
        workshops => \@workshops_hash,
        error => $error,
        sitename => $c->session->{SiteName},
        template => 'WorkShops/workshops.tt',
    );
    if ($@) {
    $c->stash(error => "Error fetching active workshops: $@");
}
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

    # Get the start_time from the form data
    my $start_time_str = $c->request->body_parameters->{time};

    # Create a DateTime::Format::Strptime object for parsing the time strings
    my $strp = DateTime::Format::Strptime->new(
        pattern   => '%H:%M',
        time_zone => 'local',
    );

    # Convert the start_time string to a DateTime object
    my $time = $strp->parse_datetime($start_time_str);

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
            time => $time,
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
sub details :Local {
    my ( $self, $c ) = @_;

    # Get the ID from the POST parameters
    my $id = $c->request->body_parameters->{id};

    # Get a DBIx::Class::Schema object
    my $schema = $c->model('DBEncy');

    # Get a DBIx::Class::ResultSet object for the 'WorkShop' table
    my $rs = $schema->resultset('WorkShop');

    # Try to find the workshop by its ID
    my $workshop;
    eval {
        $workshop = $rs->find($id);
    };
    # Assuming $workshop->date is a DateTime object
my $formatted_date = $workshop->date->strftime('%Y-%m-%d');
    if ($@) {
        $c->stash->{error_msg} = 'Failed to find workshop: ' . $@;
        $c->stash->{template} = 'WorkShops/details.tt';

        return;
    }

    # Pass the workshop to the view
    $c->stash(
        workshop => $workshop,
        formatted_date => $formatted_date,
        template => 'WorkShops/details.tt',
    );
}
use DateTime::Format::Strptime;

sub edit :Local :Args(1) {
    my ($self, $c, $id) = @_;

    # Define the input validation rules
    my $validator = Data::FormValidator->check(
        $c->request->body_parameters,
        {
            required => [qw(date)],
            optional => [qw(other_form_fields)],
            filters  => ['trim'],
            constraint_methods => {
                date => qr/^\d{4}-\d{2}-\d{2}$/,
            },
        }
    );

    # Find the workshop in the database
    my $workshop = $c->model('DBEncy::Workshop')->find($id);

    if ($c->request->method eq 'POST') {
        # Check if the input is valid
        if ($validator->has_invalid || $validator->has_missing) {
            # Invalid or missing input
            $c->stash->{error_msg} = 'Invalid input: ' . join(', ', $validator->invalid, $validator->missing);
            $c->stash->{form_data} = $c->request->body_parameters;  # Add the form data to the stash
            $c->stash->{template} = 'WorkShops/edit.tt';
            return;
        }

        # Try to update the workshop record with the form data
        eval {
            $workshop->update($c->request->body_parameters);
        };

        if ($@) {
            # An error occurred during the update
            $c->stash->{error_msg} = 'Failed to update workshop: ' . $@;
            $c->stash(workshop => $workshop);
            $c->stash->{form_data} = $c->request->body_parameters;  # Add the form data to the stash
            $c->stash->{template} = 'WorkShops/edit.tt';
            return;
        }

        # Redirect to the workshop details page
        $c->res->redirect($c->uri_for($self->action_for('details'), [$id]));
    } else {
        # Pass the workshop data to the template
        $c->stash(workshop => $workshop);

        # Specify the template to use
        $c->stash->{template} = 'WorkShops/edit.tt';
    }
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
