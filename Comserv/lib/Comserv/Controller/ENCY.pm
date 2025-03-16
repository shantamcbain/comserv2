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
# Add this subroutine to handle the '/ENCY/add_herb' path

sub edit_herb : Path('/ENCY/edit_herb') : Args(0) {
    my ($self, $c) = @_;

    # Fetch the record_id from the session
    my $record_id = $c->session->{record_id};

    # Validate the record_id; if invalid, show error (stay on the HerbView page)
    unless (defined $record_id && $record_id =~ /^\d+$/) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'edit_herb',
            "Invalid or missing record_id in session.");
        $c->stash(
            error_msg => "Invalid or missing herb record for editing. Please try again.",
            template  => 'ENCY/HerbView.tt',
            edit_mode => 0, # Keep edit_mode off since no valid record is loaded
        );
        return; # Do not redirect; just render the view with an error message
    }

    # Retrieve the herb record
    my $herb = $c->model('ENCYModel')->get_herb_by_id($record_id);
    unless ($herb) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'edit_herb',
            "Herb record not found in the database for record_id: $record_id.");
        $c->stash(
            error_msg => "Herb not found in the database. Please try again.",
            template  => 'ENCY/HerbView.tt',
            edit_mode => 0, # Render view mode since no valid herb is loaded
        );
        return; # Do not redirect; just render the view
    }

    # Handle POST request for herb updates (if applicable)
    if ($c->request->method eq 'POST') {
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

        # Attempt to update the herb record and handle success or failure
        my ($status, $error_message) = $c->model('ENCYModel')->update_herb($c, $record_id, $form_data);

        if ($status) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_herb',
                "Herb updated successfully for record_id: $record_id.");
            $c->stash(
                success_msg => "Herb details updated successfully.",
                herb        => $herb,
                edit_mode   => 0, # Switch back to view mode after successful update
                template    => 'ENCY/HerbView.tt',
            );
            return; # Render the updated herb view
        } else {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'edit_herb',
                "Failed to update herb: $error_message.");
            $c->stash(
                error_msg => "Failed to update herb: $error_message",
                herb      => { %$herb, %$form_data }, # Combine original and submitted data for display
                edit_mode => 1, # Stay in edit mode for correction
                template  => 'ENCY/HerbView.tt',
            );
            return; # Re-render the form with an error message
        }
    }

    # Render the herb in edit mode when Edit Herb button is clicked
    $c->stash(
        herb      => $herb,
        edit_mode => 1, # Enable edit mode
        template  => 'ENCY/HerbView.tt',
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
sub add_herb :Path('/ENCY/add_herb') :Args(0) {
    my ( $self, $c ) = @_;

    if ($c->request->method eq 'POST') {
        # Handle form submission
        my $form_data = $c->request->body_parameters;

        # Use the existing logging system to log the form data
        $self->logging->log_with_details($c, __FILE__, __LINE__, 'add_herb', "Form data received: " . join(", ", map { "$_: $form_data->{$_}" } keys %$form_data));

        my $new_herb = {
            therapeutic_action => $form_data->{therapeutic_action},
            botanical_name => $form_data->{botanical_name},
            common_names => $form_data->{common_names},
            parts_used => $form_data->{parts_used},
            comments => $form_data->{comments},
            medical_uses => $form_data->{medical_uses},
            homiopathic => $form_data->{homiopathic},
            ident_character => $form_data->{ident_character},
            image => $form_data->{image},
            stem => $form_data->{stem},
            nectar => $form_data->{nectar},
            pollinator => $form_data->{pollinator},
            pollen => $form_data->{pollen},
            leaves => $form_data->{leaves},
            flowers => $form_data->{flowers},
            fruit => $form_data->{fruit},
            taste => $form_data->{taste},
            odour => $form_data->{odour},
            distribution => $form_data->{distribution},
            url => $form_data->{url},
            root => $form_data->{root},
            constituents => $form_data->{constituents},
            solvents => $form_data->{solvents},
            chinese => $form_data->{chinese},
            culinary => $form_data->{culinary},
            contra_indications => $form_data->{contra_indications},
            dosage => $form_data->{dosage},
            administration => $form_data->{administration},
            formulas => $form_data->{formulas},
            vetrinary => $form_data->{vetrinary},
            cultivation => $form_data->{cultivation},
            sister_plants => $form_data->{sister_plants},
            harvest => $form_data->{harvest},
            non_med => $form_data->{non_med},
            history => $form_data->{history},
            reference => $form_data->{reference},
            username_of_poster => $c->session->{username},
            group_of_poster => $c->session->{group},
            date_time_posted => \'NOW()',  # Assuming you want to set this to the current timestamp
        };

        # Use the existing logging system to log the new herb data
        $self->logging->log_with_details($c, __FILE__, __LINE__, 'add_herb', "New herb data: " . join(", ", map { "$_: $new_herb->{$_}" } keys %$new_herb));

        # Save the new herb using the ENCYModel
        $c->model('ENCYModel')->add_herb($new_herb);

        # Redirect or display a success message
        $c->flash->{success_message} = 'Herb added successfully';
        $c->res->redirect($c->uri_for($self->action_for('index')));
    } else {
        # Display the form
        $c->stash(
            template => 'ENCY/add_herb_form.tt',
            user_role => $c->session->{roles}  # Pass user role to the template
        );
    }
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