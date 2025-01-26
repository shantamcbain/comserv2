package Comserv::Controller::ENCY;
use Moose;
use namespace::autoclean;
use Comserv::Model::ENCYModel;
use Comserv::Util::Logging;

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);
BEGIN { extends 'Catalyst::Controller'; }

sub index :Path('/ENCY') :Args(0) {
    my ( $self, $c ) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', 'Entered index method');
    $c->session->{MailServer} = "http://webmail.usbm.ca";

    # The index action will display the 'index.tt' template
    $c->stash(template => 'ENCY/index.tt');
}

sub edit_herb : Path('/ENCY/edit_herb') : Args(0) {
    my ($self, $c) = @_;

    # Fetch the record_id from the session
    my $record_id = $c->session->{record_id};
    unless ($record_id) {
        # Log an error if record_id is missing from the session
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'edit_herb',
            "Missing record_id in session. Cannot proceed with editing.");
        $c->flash->{error} = "No herb record selected for editing.";
        $c->response->redirect('/ENCY/edit_herb'); # Redirect back to self in error
        return;
    }

    # Retrieve the herb record from the database using the model
    my $herb = $c->model('ENCYModel')->get_herb_by_id($record_id);
    unless ($herb) {
        # Log if the herb record cannot be found
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'edit_herb',
            "Herb record not found in the database for record_id: $record_id.");
        $c->flash->{error} = "Herb not found in the database.";
        $c->response->redirect('/ENCY/edit_herb'); # Redirect back to self in error
        return;
    }

    # If the request is a POST, attempt to update the record
    if ($c->request->method eq 'POST') {
        # Collect form data from the request
        my $form_data = {
            botanical_name      => $c->request->params->{botanical_name} // '',
            common_names        => $c->request->params->{common_names} // '',
            homiopathic         => $c->request->params->{homiopathic} // '',
            culinary            => $c->request->params->{culinary} // '',
            comments            => $c->request->params->{comments} // '',
            preparation         => $c->request->params->{preparation} // '',
            chinese             => $c->request->params->{chinese} // '',
            history             => $c->request->params->{history} // '',
            contra_indications  => $c->request->params->{contra_indications} // '',
            reference           => $c->request->params->{reference} // '',
            parts_used          => $c->request->params->{parts_used} // '',
            key_name            => $c->request->params->{key_name} // '',
        };

        # Log the submitted form data for debugging
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_herb',
            "Form data received for update: " . join(", ", map { "$_: $form_data->{$_}" } keys %$form_data));

        # Perform the update operation
        my ($status, $error_message) = $c->model('ENCYModel')->update_herb($c, $record_id, $form_data);

        if ($status) {
            # Log success of the update
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_herb',
                "Herb updated successfully. record_id: $record_id");

            # Redirect to the HerbView.tt in view mode to confirm changes
            $c->flash->{success} = "Herb details updated successfully.";
            $c->response->redirect('/ENCY/edit_herb'); # Show updated data in view mode
            return;
        } else {
            # Log failure of the update
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'edit_herb',
                "Failed to update herb: $error_message");

            # Pass errors and form data back to the stash
            $c->stash(
                herb      => { %$herb, %$form_data }, # Merge submitted data with original herb data
                error_msg => "Failed to update herb: $error_message",
                edit_mode => 1, # Stay in edit mode with the submitted data
                template  => 'ENCY/HerbView.tt',
            );

            return; # Re-render the template in edit mode
        }
    }

    # Render the HerbView.tt in view mode by default if no data submission
    $c->stash(
        herb     => $herb,
        template => 'ENCY/HerbView.tt',
        edit_mode => 0, # Default to view mode
    );

    return;
}
sub botanical_name_view :Path('/ENCY/BotanicalNameView') :Args(0) {
    my ( $self, $c ) = @_;

    # Fetch the herbal data
    my $forager_data = $c->model('DBForager')->get_herbal_data();

    # Pass the data to the template
    my $herbal_data = $forager_data;
    $c->stash(herbal_data => $herbal_data, template => 'ENCY/BotanicalNameView.tt');
}
sub herb_detail :Path('/ENCY/herb_detail') :Args(1) {
    my ( $self, $c, $id ) = @_;
    my $herb = $c->model('DBForager')->get_herb_by_id($id);
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'herb_detail', "Fetching herb details for ID: $id");
   if ($herb) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'herb_detail', "Herb details fetched successfully for ID: $id");
    } else {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'herb_detail', "Herb not found for ID: $id");
    }
    $c->session->{record_id} = $id;  # Store the id in the session

    $c->stash(
        herb => $herb,
        mode => 'view',
        template => 'ENCY/HerbView.tt');
}
sub get_reference_by_id :Local {
    my ( $self, $c, $id ) = @_;
    # Implement the logic to display the form for getting a reference by its id
    # Fetch the reference using the ENCY model
    my $reference = $c->model('ENCY')->get_reference_by_id($id);
    $c->stash(reference => $reference);
    $c->stash(template => 'ency/get_reference_form.tt');
    my $herb = $c->model('DBForager')->get_herb_by_id($id);
    $c->stash(herb => $herb, record_id => $id, template => 'ENCY/HerbView.tt');
}

sub create_reference :Local {
    my ( $self, $c ) = @_;
    # Implement the logic to display the form for creating a new reference
    $c->stash(template => 'ency/create_reference_form.tt');
}
sub search :Path('/ENCY/search') :Args(0) {
    my ($self, $c) = @_;

    my $search_string = $c->request->parameters->{search_string};

    # Call the searchHerbs method in the DBForager model
    my $results = $c->model('DBForager')->searchHerbs($c, $search_string);

    # Stash the results for the view
    $c->stash(herbal_data => $results);

    # Get the referer from the request headers
    my $referer = $c->req->headers->referer;

    # Extract the template name from the referer
    $c->stash(template => 'ENCY/BotanicalNameView.tt');
}
sub get_category_by_id :Local {
    my ( $self, $c, $id ) = @_;
    # Implement the logic to display the form for getting a category by its id
    # Fetch the category using the ENCY model
    my $category = $c->model('ENCY')->get_category_by_id($id);
    $c->stash(category => $category);
    $c->stash(template => 'ency/get_category_form.tt');
}

sub create_category :Local {
    my ( $self, $c ) = @_;
    # Implement the logic to display the form for creating a new category
    $c->stash(template => 'ency/create_category_form.tt');
}

__PACKAGE__->meta->make_immutable;

1;