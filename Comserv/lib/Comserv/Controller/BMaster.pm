
package Comserv::Controller::BMaster;
use Moose;
use namespace::autoclean;
use DateTime;
use DateTime::Event::Recurrence;
use Comserv::Model::BMasterModel;
use Comserv::Model::DBForager;
BEGIN { extends 'Catalyst::Controller'; }
has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

sub base :Chained('/') :PathPart('BMaster') :CaptureArgs(0) {
    my ($self, $c) = @_;
    # This will be the root of the chained actions
    # You can put common setup code here if needed
}

sub index :Chained('base') :Path('') :Args(0) {

    my ( $self, $c ) = @_;
       $c->session->{MailServer} = "http://webmail.beemaster.ca";

    $c->stash(template => 'BMaster/BMaster.tt');
    $c->forward($c->view('TT'));
}

# In the BMaster controller
sub bee_pasture :Chained('base') :PathPart('bee_pasture') :Args(0) {
    my ($self, $c) = @_;

    # Use the DBForager model to fetch all the records from the herb table where the apis field has a value
    my @plants = @{$c->model('DBForager')->get_herbs_with_apis};

    # Pass the fetched records to the view
    $c->stash->{herbal_data} = \@plants;

    # Set the template
    $c->stash->{template} = 'ENCY/BeePastureView.tt';
}
sub generate_month_dates {
    my ($year, $month, $number_of_grafts) = @_;

    my $dt = DateTime->new(
        year  => $year,
        month => $month,
        day   => 1,
    );

    # Get the first day of the week for the first day of the month
    my $first_day_of_week = $dt->day_of_week;

    # Subtract the first day of the week from the first day of the month to get the first Sunday of the view
    $dt->subtract(days => $first_day_of_week % 7);

    my @dates;

    # Calculate the total number of days required for all grafts
    my $total_days = $number_of_grafts * 21;

    # Calculate the number of weeks required to cover all these days
    my $total_weeks = int(($total_days + 6) / 7);  # Add 6 before dividing to round up

    # Generate the dates for the current month's view
    for (1..($total_weeks * 7)) {  # Multiply by 7 to get the total number of days
        push @dates, $dt->clone;
        $dt->add(days => 1);
    }

    return \@dates;
}
sub add_graft :Chained('base') :PathPart('add_graft') :Args(0) {
    my ($self, $c) = @_;

    if ($c->request->method eq 'POST') {
        my $first_graft_date = $c->request->params->{first_graft_date};
        my $days_of_egg_laying = $c->request->params->{days_of_egg_laying};
        my $number_of_grafts = $c->request->params->{number_of_grafts};

        # Convert the graft date string to a DateTime object
        my ($year, $month, $day) = split /-/, $first_graft_date;
        my $graft_date = DateTime->new(
            year  => $year,
            month => $month,
            day   => $day,
        );

        # Calculate the dates for each graft and store them in an array
        my @graft_dates;
        for my $i (0..$number_of_grafts-1) {
            my $graft_date_clone = $graft_date->clone;  # The first graft is on the date submitted, subsequent grafts are 10 days before the queen pull date

            my $return_brood_date = $graft_date_clone->clone->add(days => 3);  # Return brood event is 3 days after each graft day
            my $queen_mated_and_start_laying_date = $graft_date_clone->clone->add(days => 20);  # Queen Mated and Start Laying event is 20 days after each graft day
            my $queen_pull_date = $queen_mated_and_start_laying_date->clone->add(days => $days_of_egg_laying);  # Queen pull date is days_of_egg_laying days after the queen starts laying
            my $cell_up_date = $graft_date_clone->clone->add(days => 10);  # Cell Up event is 10 days after the graft date

            push @graft_dates, { graft_date => $graft_date_clone, event_name => "Graft " . ($i + 1), graft_number => $i + 1 };  # Append the graft number to the event name
            push @graft_dates, { graft_date => $return_brood_date, event_name => "Return Brood " . ($i + 1), graft_number => $i + 1 };  # Append the graft number to the event name
            push @graft_dates, { graft_date => $cell_up_date, event_name => "Cell Up " . ($i + 1), graft_number => $i + 1 };  # Append the graft number to the event name
            push @graft_dates, { graft_date => $queen_mated_and_start_laying_date, event_name => "Queen Mated and Start Laying " . ($i + 1), graft_number => $i + 1 };  # Append the graft number to the event name
            push @graft_dates, { graft_date => $queen_pull_date, event_name => "Queen Pull " . ($i + 1), graft_number => $i + 1 };  # Append the graft number to the event name

            # Update the graft date for the next iteration
            $graft_date = $queen_pull_date->clone->subtract(days => 10);
        }

        # Store the graft dates in the session
        $c->session->{graft_dates} = \@graft_dates;
        $c->session->{first_graft_date} = $first_graft_date;
        $c->session->{days_of_egg_laying} = $days_of_egg_laying;
        $c->session->{number_of_grafts} = $number_of_grafts;
        # Redirect to the queens page
        $c->response->redirect($c->uri_for($self->action_for('queens')));
    } else {
        $c->response->redirect($c->uri_for($self->action_for('index')));
    }
}
sub frames :Chained('base') :PathPart('frames') :Args(1) {
    my ( $self, $c, $queen_tag_number ) = @_;

    # Get the frames for the given queen
    my $frames = $c->model('BMaster')->get_frames_for_queen($queen_tag_number);

    # Set the TT template to use
    $c->stash->{template} = 'BMaster/frames.tt';
    $c->stash->{frames} = $frames;
}
sub api_frames :Chained('base') :PathPart('api/frames') :Args(0) {
    my ( $self, $c ) = @_;

    # Fetch the data for the frames
    my $data = $c->model('BMaster')->get_frames_data();

    # Set the response body to the JSON representation of the data
    $c->response->body( $c->stash->{json}->($data) );
}
sub products :Chained('base') :PathPath('products') :Args(0) {
    my ( $self, $c ) = @_;
    $c->stash(template => 'BMaster/products.tt');
}

sub yards :Chained('base') :PathPart('yards') :Args(0) {
    my ( $self, $c ) = @_;

    # Get the yards
    my $yards = $c->model('BMaster')->get_yards();

    # Set the TT template to use
    $c->stash->{template} = 'BMaster/yards.tt';
    $c->stash->{yards} = $yards;
}
# Define an action for each link in BMaster.tt

sub apiary :Chained('base') :PathPart('apiary') :Args(0){
    my ( $self, $c ) = @_;
    $c->log->debug('Entered apiary');
    # Set the TT template to use
    $c->stash->{template} = 'BMaster/apiary.tt';
    $c->forward($c->view('TT'));
}

sub queens :Chained('base') :PathPart('Queens') :Args(0) {
    my ( $self, $c ) = @_;

    my $dt = DateTime->now; # current date
    my $month = $dt->month; # current month
    my $year = $dt->year; # current year

    # Retrieve the form data and graft dates from the session
    my $first_graft_date = $c->session->{first_graft_date};
    my $days_of_egg_laying = $c->session->{days_of_egg_laying};
    my $number_of_grafts = $c->session->{number_of_grafts};
    my $graft_dates_hashes = $c->session->{graft_dates};

    # Get all the dates for the current month's view
    my $dates = generate_month_dates($year, $month, $number_of_grafts);

    # Flatten the graft_dates array into a single array of hash references
    my @graft_dates = map { { graft_date => $_->{graft_date}, event_name => $_->{event_name} } } @$graft_dates_hashes;

    # Pass the dates, today's date, graft dates, and form data to the template
    $c->stash(
        dates => $dates,
        today => $dt,
        graft_dates => \@graft_dates,
        first_graft_date => $first_graft_date,
        days_of_egg_laying => $days_of_egg_laying,
        number_of_grafts => $number_of_grafts,
        template => 'BMaster/Queens.tt',
    );
}

sub hive :Chained('base') :PathPart('hive') :Args(0){
    my ( $self, $c ) = @_;
    $c->stash->{template} = 'BMaster/hive.tt';
}

sub honey :Chained('base') :PathPart('honey') :Args(0){
    my ( $self, $c ) = @_;
    $c->stash->{template} = 'BMaster/honey.tt';
}

sub beehealth :Chained('base') :PathPart('beehealth') :Args(0){
    my ( $self, $c ) = @_;
    $c->stash->{template} = 'BMaster/beehealth.tt';
}

sub environment :Chained('base') :PathPart('environment') :Args(0){
    my ( $self, $c ) = @_;
    $c->stash->{template} = 'BMaster/environment.tt';
}

sub education :Chained('base') :PathPart('education') :Args(0){
    my ( $self, $c ) = @_;
    $c->stash->{template} = 'BMaster/education.tt';
}


__PACKAGE__->meta->make_immutable;

1;
