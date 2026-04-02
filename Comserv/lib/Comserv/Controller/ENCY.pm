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

sub _stash_image_files {
    my ($self, $c) = @_;
    my @image_files;
    eval {
        my $schema   = $c->model('DBEncy');
        my $sitename = $c->session->{SiteName} // '';
        my $roles    = $c->session->{roles} || [];
        my $is_csc   = (grep { $_ eq 'admin' } (ref $roles ? @$roles : split /\s*,\s*/, $roles))
                       && lc($sitename) eq 'csc';
        my %where = (
            file_format => { -like => 'image/%' },
            file_status => 'active',
        );
        $where{sitename} = $sitename unless $is_csc;
        @image_files = $schema->resultset('File')->search(
            \%where,
            { order_by => { -desc => 'upload_date' }, rows => 200 }
        )->all;
    };
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, '_stash_image_files',
            "Could not fetch image files: $@");
    }
    $c->stash(ency_image_files => \@image_files);
}

sub _resolve_image_value {
    my ($self, $c, $image_val) = @_;
    return $image_val unless defined $image_val && length $image_val;
    return $image_val if $image_val =~ m{^https?://};
    return $image_val if $image_val =~ m{^/};
    if ($image_val =~ /^\d+$/) {
        eval {
            my $file = $c->model('DBEncy')->resultset('File')->find($image_val);
            $image_val = $file->nfs_path || $file->file_path || $file->external_url || $image_val if $file;
        };
    }
    return $image_val;
}

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

    unless ($c->session->{username}) {
        $c->response->redirect($c->uri_for('/user/login', { return_to => '/ENCY/edit_herb' }));
        return;
    }

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
    $self->_stash_image_files($c);
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
    my $herbal_data = $forager_data;  # Add 'my' here
    $c->stash(herbal_data => $herbal_data, template => 'ENCY/BotanicalNameView.tt');
}
sub herb_detail :Path('/ENCY/herb_detail') :Args(1) {
    my ( $self, $c, $id ) = @_;

    unless (defined $id && $id =~ /^\d+$/) {
        $c->response->status(400);
        $c->response->body('Invalid herb ID');
        return;
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'herb_detail', "Fetching herb details for ID: $id");
    my $herb = $c->model('DBForager')->get_herb_by_id($id);

    unless ($herb) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'herb_detail', "Herb not found for ID: $id");
        $c->response->status(404);
        $c->stash(
            error_message => "Herb record #$id was not found.",
            template      => 'error.tt',
        );
        return;
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'herb_detail', "Herb details fetched successfully for ID: $id");
    $c->session->{record_id} = $id;

    $self->_stash_image_files($c);
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

    unless ($c->session->{username}) {
        $c->response->redirect($c->uri_for('/user/login', { return_to => '/ENCY/add_herb' }));
        return;
    }

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
        $c->flash->{success_msg} = 'Herb added successfully';
        $c->res->redirect($c->uri_for($self->action_for('index')));
    } else {
        # Display the form
        $self->_stash_image_files($c);
        $c->stash(
            template => 'ENCY/add_herb_form.tt',
            user_role => $c->session->{roles}  # Pass user role to the template
        );
    }
}





sub animal_list : Path('/ENCY/Animal') : Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'animal_list', 'Entered animal_list');
    my $animals = $c->model('ENCYModel')->list_animals($c, {});
    $c->stash(
        animals  => $animals,
        template => 'ENCY/AnimalList.tt',
    );
}

sub animal_detail : Path('/ENCY/Animal') : Args(1) {
    my ($self, $c, $id) = @_;

    unless (defined $id && $id =~ /^\d+$/) {
        $c->response->status(400);
        $c->response->body('Invalid animal ID');
        return;
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'animal_detail', "Fetching animal ID: $id");
    my $animal = $c->model('ENCYModel')->get_animal_by_id($c, $id);

    unless ($animal) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'animal_detail', "Animal not found for ID: $id");
        $c->response->status(404);
        $c->stash(
            error_message => "Animal record #$id was not found.",
            template      => 'error.tt',
        );
        return;
    }

    $c->session->{record_id} = $id;
    my $related = $c->model('ENCYModel')->get_animal_related($c, $id);
    $c->stash(
        animal          => $animal,
        related_herbs   => $related->{herbs}    // [],
        related_diseases => $related->{diseases} // [],
        edit_mode       => 0,
        template        => 'ENCY/AnimalDetail.tt',
    );
}

sub add_animal : Path('/ENCY/Animal/add') : Args(0) {
    my ($self, $c) = @_;

    unless ($c->session->{username}) {
        $c->response->redirect($c->uri_for('/user/login', { return_to => '/ENCY/Animal/add' }));
        return;
    }

    my $roles = $c->session->{roles} || [];
    my @role_list = ref $roles ? @$roles : split /\s*,\s*/, $roles;
    unless (grep { $_ eq 'admin' } @role_list) {
        $c->stash(
            error_msg => "You do not have permission to add animals.",
            template  => 'ENCY/AnimalList.tt',
        );
        return;
    }

    if ($c->request->method eq 'POST') {
        my $p = $c->request->body_parameters;
        my $data = {
            common_name          => $p->{common_name}          // '',
            scientific_name      => $p->{scientific_name}      // '',
            kingdom              => $p->{kingdom}              // '',
            phylum               => $p->{phylum}               // '',
            class_name           => $p->{class_name}           // '',
            order_name           => $p->{order_name}           // '',
            family_name          => $p->{family_name}          // '',
            genus                => $p->{genus}                // '',
            species              => $p->{species}              // '',
            habitat              => $p->{habitat}              // '',
            diet                 => $p->{diet}                 // '',
            behavior             => $p->{behavior}             // '',
            ecological_role      => $p->{ecological_role}      // '',
            therapeutic_uses     => $p->{therapeutic_uses}     // '',
            veterinary_uses      => $p->{veterinary_uses}      // '',
            distribution         => $p->{distribution}         // '',
            conservation_status  => $p->{conservation_status}  // '',
            constituents         => $p->{constituents}         // '',
            image                => $p->{image}                // '',
            url                  => $p->{url}                  // '',
            history              => $p->{history}              // '',
            reference            => $p->{reference}            // '',
            sitename             => $p->{sitename}             // 'ENCY',
            username_of_poster   => $c->session->{username},
            group_of_poster      => $c->session->{group},
            date_time_posted     => \'NOW()',
        };

        unless ($data->{common_name}) {
            $c->stash(
                error_msg => "Common name is required.",
                animal    => $data,
                edit_mode => 1,
                template  => 'ENCY/AnimalDetail.tt',
            );
            return;
        }

        $c->model('ENCYModel')->add_animal($c, $data);
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_animal', "Animal added: $data->{common_name}");
        $c->flash->{success_msg} = 'Animal added successfully.';
        $c->response->redirect($c->uri_for('/ENCY/Animal'));
        return;
    }

    $self->_stash_image_files($c);
    $c->stash(
        edit_mode => 1,
        template  => 'ENCY/AnimalDetail.tt',
    );
}

sub edit_animal : Path('/ENCY/Animal/edit') : Args(0) {
    my ($self, $c) = @_;

    unless ($c->session->{username}) {
        $c->response->redirect($c->uri_for('/user/login', { return_to => '/ENCY/Animal/edit' }));
        return;
    }

    my $roles = $c->session->{roles} || [];
    my @role_list = ref $roles ? @$roles : split /\s*,\s*/, $roles;
    unless (grep { $_ eq 'admin' } @role_list) {
        $c->stash(
            error_msg => "You do not have permission to edit animals.",
            template  => 'ENCY/AnimalList.tt',
        );
        return;
    }

    my $record_id = $c->session->{record_id};

    unless (defined $record_id && $record_id =~ /^\d+$/) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'edit_animal',
            "Invalid or missing record_id in session.");
        $c->stash(
            error_msg => "Invalid or missing animal record for editing. Please try again.",
            template  => 'ENCY/AnimalList.tt',
        );
        return;
    }

    my $animal = $c->model('ENCYModel')->get_animal_by_id($c, $record_id);
    unless ($animal) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'edit_animal',
            "Animal not found for record_id: $record_id");
        $c->stash(
            error_msg => "Animal not found in the database. Please try again.",
            template  => 'ENCY/AnimalList.tt',
        );
        return;
    }

    if ($c->request->method eq 'POST') {
        my $p = $c->request->body_parameters;
        my $data = {
            common_name          => $p->{common_name}          // '',
            scientific_name      => $p->{scientific_name}      // '',
            kingdom              => $p->{kingdom}              // '',
            phylum               => $p->{phylum}               // '',
            class_name           => $p->{class_name}           // '',
            order_name           => $p->{order_name}           // '',
            family_name          => $p->{family_name}          // '',
            genus                => $p->{genus}                // '',
            species              => $p->{species}              // '',
            habitat              => $p->{habitat}              // '',
            diet                 => $p->{diet}                 // '',
            behavior             => $p->{behavior}             // '',
            ecological_role      => $p->{ecological_role}      // '',
            therapeutic_uses     => $p->{therapeutic_uses}     // '',
            veterinary_uses      => $p->{veterinary_uses}      // '',
            distribution         => $p->{distribution}         // '',
            conservation_status  => $p->{conservation_status}  // '',
            constituents         => $p->{constituents}         // '',
            image                => $p->{image}                // '',
            url                  => $p->{url}                  // '',
            history              => $p->{history}              // '',
            reference            => $p->{reference}            // '',
        };

        my ($status, $msg) = $c->model('ENCYModel')->update_animal($c, $record_id, $data);

        if ($status) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_animal',
                "Animal updated successfully for record_id: $record_id");
            $c->flash->{success_msg} = "Animal details updated successfully.";
            $c->response->redirect($c->uri_for('/ENCY/Animal', $record_id));
            return;
        } else {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'edit_animal',
                "Failed to update animal: $msg");
            $c->stash(
                error_msg => "Failed to update animal: $msg",
                animal    => { %{ $animal->get_columns }, %$data },
                edit_mode => 1,
                template  => 'ENCY/AnimalDetail.tt',
            );
            return;
        }
    }

    $self->_stash_image_files($c);
    $c->stash(
        animal    => $animal,
        edit_mode => 1,
        template  => 'ENCY/AnimalDetail.tt',
    );
}

sub animals_redirect : Path('/ENCY/animals') : Args(0) {
    my ($self, $c) = @_;
    $c->response->redirect($c->uri_for('/ENCY/Animal'), 301);
}

sub insects_redirect : Path('/ENCY/insects') : Args(0) {
    my ($self, $c) = @_;
    $c->response->redirect($c->uri_for('/ENCY/Insect'), 301);
}

sub insect_list : Path('/ENCY/Insect') : Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'insect_list', 'Entered insect_list');
    my $insects = $c->model('ENCYModel')->list_insects($c, {});
    $c->stash(
        insects  => $insects,
        template => 'ENCY/InsectList.tt',
    );
}

sub insect_detail : Path('/ENCY/Insect') : Args(1) {
    my ($self, $c, $id) = @_;

    unless (defined $id && $id =~ /^\d+$/) {
        $c->response->status(400);
        $c->response->body('Invalid insect ID');
        return;
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'insect_detail', "Fetching insect ID: $id");
    my $insect = $c->model('ENCYModel')->get_insect_by_id($c, $id);

    unless ($insect) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'insect_detail', "Insect not found for ID: $id");
        $c->response->status(404);
        $c->stash(
            error_message => "Insect record #$id was not found.",
            template      => 'error.tt',
        );
        return;
    }

    $c->session->{record_id} = $id;
    my $related = $c->model('ENCYModel')->get_insect_related($c, $id);
    $c->stash(
        insect           => $insect,
        related_herbs    => $related->{herbs}    // [],
        related_diseases => $related->{diseases} // [],
        edit_mode        => 0,
        template         => 'ENCY/InsectDetail.tt',
    );
}

sub add_insect : Path('/ENCY/Insect/add') : Args(0) {
    my ($self, $c) = @_;

    unless ($c->session->{username}) {
        $c->response->redirect($c->uri_for('/user/login', { return_to => '/ENCY/Insect/add' }));
        return;
    }

    my $roles = $c->session->{roles} || [];
    my @role_list = ref $roles ? @$roles : split /\s*,\s*/, $roles;
    unless (grep { $_ eq 'admin' } @role_list) {
        $c->stash(
            error_msg => "You do not have permission to add insects.",
            template  => 'ENCY/InsectList.tt',
        );
        return;
    }

    if ($c->request->method eq 'POST') {
        my $p = $c->request->body_parameters;
        my $data = {
            common_name       => $p->{common_name}       // '',
            scientific_name   => $p->{scientific_name}   // '',
            order_name        => $p->{order_name}        // '',
            family_name       => $p->{family_name}       // '',
            genus             => $p->{genus}             // '',
            species           => $p->{species}           // '',
            ecological_role   => $p->{ecological_role}   // '',
            plants_foraged    => $p->{plants_foraged}    // '',
            plants_damaged    => $p->{plants_damaged}    // '',
            habitat           => $p->{habitat}           // '',
            lifecycle         => $p->{lifecycle}         // '',
            behavior          => $p->{behavior}          // '',
            distribution      => $p->{distribution}      // '',
            honey_production  => $p->{honey_production}  // '',
            pollination_notes => $p->{pollination_notes} // '',
            pest_notes        => $p->{pest_notes}        // '',
            beneficial_notes  => $p->{beneficial_notes}  // '',
            image             => $p->{image}             // '',
            url               => $p->{url}               // '',
            history           => $p->{history}           // '',
            reference         => $p->{reference}         // '',
            sitename          => $p->{sitename}          // 'ENCY',
            username_of_poster => $c->session->{username},
            group_of_poster    => $c->session->{group},
            date_time_posted   => \'NOW()',
        };

        unless ($data->{common_name}) {
            $c->stash(
                error_msg => "Common name is required.",
                insect    => $data,
                edit_mode => 1,
                template  => 'ENCY/InsectDetail.tt',
            );
            return;
        }

        $c->model('ENCYModel')->add_insect($c, $data);
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_insect', "Insect added: $data->{common_name}");
        $c->flash->{success_msg} = 'Insect added successfully.';
        $c->response->redirect($c->uri_for('/ENCY/Insect'));
        return;
    }

    $self->_stash_image_files($c);
    $c->stash(
        edit_mode => 1,
        template  => 'ENCY/InsectDetail.tt',
    );
}

sub edit_insect : Path('/ENCY/Insect/edit') : Args(0) {
    my ($self, $c) = @_;

    unless ($c->session->{username}) {
        $c->response->redirect($c->uri_for('/user/login', { return_to => '/ENCY/Insect/edit' }));
        return;
    }

    my $roles = $c->session->{roles} || [];
    my @role_list = ref $roles ? @$roles : split /\s*,\s*/, $roles;
    unless (grep { $_ eq 'admin' } @role_list) {
        $c->stash(
            error_msg => "You do not have permission to edit insects.",
            template  => 'ENCY/InsectList.tt',
        );
        return;
    }

    my $record_id = $c->session->{record_id};

    unless (defined $record_id && $record_id =~ /^\d+$/) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'edit_insect',
            "Invalid or missing record_id in session.");
        $c->stash(
            error_msg => "Invalid or missing insect record for editing. Please try again.",
            template  => 'ENCY/InsectList.tt',
        );
        return;
    }

    my $insect = $c->model('ENCYModel')->get_insect_by_id($c, $record_id);
    unless ($insect) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'edit_insect',
            "Insect not found for record_id: $record_id");
        $c->stash(
            error_msg => "Insect not found in the database. Please try again.",
            template  => 'ENCY/InsectList.tt',
        );
        return;
    }

    if ($c->request->method eq 'POST') {
        my $p = $c->request->body_parameters;
        my $data = {
            common_name       => $p->{common_name}       // '',
            scientific_name   => $p->{scientific_name}   // '',
            order_name        => $p->{order_name}        // '',
            family_name       => $p->{family_name}       // '',
            genus             => $p->{genus}             // '',
            species           => $p->{species}           // '',
            ecological_role   => $p->{ecological_role}   // '',
            plants_foraged    => $p->{plants_foraged}    // '',
            plants_damaged    => $p->{plants_damaged}    // '',
            habitat           => $p->{habitat}           // '',
            lifecycle         => $p->{lifecycle}         // '',
            behavior          => $p->{behavior}          // '',
            distribution      => $p->{distribution}      // '',
            honey_production  => $p->{honey_production}  // '',
            pollination_notes => $p->{pollination_notes} // '',
            pest_notes        => $p->{pest_notes}        // '',
            beneficial_notes  => $p->{beneficial_notes}  // '',
            image             => $p->{image}             // '',
            url               => $p->{url}               // '',
            history           => $p->{history}           // '',
            reference         => $p->{reference}         // '',
        };

        my ($status, $msg) = $c->model('ENCYModel')->update_insect($c, $record_id, $data);

        if ($status) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_insect',
                "Insect updated successfully for record_id: $record_id");
            $c->flash->{success_msg} = "Insect details updated successfully.";
            $c->response->redirect($c->uri_for('/ENCY/Insect', $record_id));
            return;
        } else {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'edit_insect',
                "Failed to update insect: $msg");
            $c->stash(
                error_msg => "Failed to update insect: $msg",
                insect    => { %{ $insect->get_columns }, %$data },
                edit_mode => 1,
                template  => 'ENCY/InsectDetail.tt',
            );
            return;
        }
    }

    $self->_stash_image_files($c);
    $c->stash(
        insect    => $insect,
        edit_mode => 1,
        template  => 'ENCY/InsectDetail.tt',
    );
}

sub diseases_redirect : Path('/ENCY/diseases') : Args(0) {
    my ($self, $c) = @_;
    $c->response->redirect($c->uri_for('/ENCY/Disease'), 301);
}

sub disease_list : Path('/ENCY/Disease') : Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'disease_list', 'Entered disease_list');
    my $host_type = $c->request->parameters->{host_type} // '';
    my $opts = $host_type ? { where => { host_type => $host_type } } : {};
    my $diseases = $c->model('ENCYModel')->list_diseases($c, $opts);
    $c->stash(
        diseases  => $diseases,
        host_type => $host_type,
        template  => 'ENCY/DiseaseList.tt',
    );
}

sub disease_detail : Path('/ENCY/Disease') : Args(1) {
    my ($self, $c, $id) = @_;

    unless (defined $id && $id =~ /^\d+$/) {
        $c->response->status(400);
        $c->response->body('Invalid disease ID');
        return;
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'disease_detail', "Fetching disease ID: $id");
    my $disease = $c->model('ENCYModel')->get_disease_by_id($c, $id);

    unless ($disease) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'disease_detail', "Disease not found for ID: $id");
        $c->response->status(404);
        $c->stash(
            error_message => "Disease record #$id was not found.",
            template      => 'error.tt',
        );
        return;
    }

    $c->session->{record_id} = $id;
    my $related = $c->model('ENCYModel')->get_disease_related($c, $id);
    $c->stash(
        disease           => $disease,
        related_symptoms  => $related->{symptoms}  // [],
        related_herbs     => $related->{herbs}     // [],
        related_animals   => $related->{animals}   // [],
        related_insects   => $related->{insects}   // [],
        edit_mode         => 0,
        template          => 'ENCY/DiseaseDetail.tt',
    );
}

sub add_disease : Path('/ENCY/Disease/add') : Args(0) {
    my ($self, $c) = @_;

    unless ($c->session->{username}) {
        $c->response->redirect($c->uri_for('/user/login', { return_to => '/ENCY/Disease/add' }));
        return;
    }

    my $roles = $c->session->{roles} || [];
    my @role_list = ref $roles ? @$roles : split /\s*,\s*/, $roles;
    unless (grep { $_ eq 'admin' } @role_list) {
        $c->stash(
            error_msg => "You do not have permission to add diseases.",
            template  => 'ENCY/DiseaseList.tt',
        );
        return;
    }

    if ($c->request->method eq 'POST') {
        my $p = $c->request->body_parameters;
        my $data = {
            common_name              => $p->{common_name}              // '',
            scientific_name          => $p->{scientific_name}          // '',
            disease_type             => $p->{disease_type}             // '',
            host_type                => $p->{host_type}                // '',
            causative_agent          => $p->{causative_agent}          // '',
            transmission             => $p->{transmission}             // '',
            symptoms_description     => $p->{symptoms_description}     // '',
            diagnosis                => $p->{diagnosis}                // '',
            treatment_conventional   => $p->{treatment_conventional}   // '',
            treatment_herbal         => $p->{treatment_herbal}         // '',
            prevention               => $p->{prevention}               // '',
            prognosis                => $p->{prognosis}                // '',
            icd_code                 => $p->{icd_code}                 // '',
            distribution             => $p->{distribution}             // '',
            image                    => $p->{image}                    // '',
            url                      => $p->{url}                      // '',
            history                  => $p->{history}                  // '',
            reference                => $p->{reference}                // '',
            sitename                 => $p->{sitename}                 // 'ENCY',
            username_of_poster       => $c->session->{username},
            group_of_poster          => $c->session->{group},
            date_time_posted         => \'NOW()',
        };

        unless ($data->{common_name}) {
            $c->stash(
                error_msg => "Common name is required.",
                disease   => $data,
                edit_mode => 1,
                template  => 'ENCY/DiseaseDetail.tt',
            );
            return;
        }

        $c->model('ENCYModel')->add_disease($c, $data);
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_disease', "Disease added: $data->{common_name}");
        $c->flash->{success_msg} = 'Disease added successfully.';
        $c->response->redirect($c->uri_for('/ENCY/Disease'));
        return;
    }

    $self->_stash_image_files($c);
    $c->stash(
        edit_mode => 1,
        template  => 'ENCY/DiseaseDetail.tt',
    );
}

sub edit_disease : Path('/ENCY/Disease/edit') : Args(0) {
    my ($self, $c) = @_;

    unless ($c->session->{username}) {
        $c->response->redirect($c->uri_for('/user/login', { return_to => '/ENCY/Disease/edit' }));
        return;
    }

    my $roles = $c->session->{roles} || [];
    my @role_list = ref $roles ? @$roles : split /\s*,\s*/, $roles;
    unless (grep { $_ eq 'admin' } @role_list) {
        $c->stash(
            error_msg => "You do not have permission to edit diseases.",
            template  => 'ENCY/DiseaseList.tt',
        );
        return;
    }

    my $record_id = $c->session->{record_id};

    unless (defined $record_id && $record_id =~ /^\d+$/) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'edit_disease',
            "Invalid or missing record_id in session.");
        $c->stash(
            error_msg => "Invalid or missing disease record for editing. Please try again.",
            template  => 'ENCY/DiseaseList.tt',
        );
        return;
    }

    my $disease = $c->model('ENCYModel')->get_disease_by_id($c, $record_id);
    unless ($disease) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'edit_disease',
            "Disease not found for record_id: $record_id");
        $c->stash(
            error_msg => "Disease not found in the database. Please try again.",
            template  => 'ENCY/DiseaseList.tt',
        );
        return;
    }

    if ($c->request->method eq 'POST') {
        my $p = $c->request->body_parameters;
        my $data = {
            common_name              => $p->{common_name}              // '',
            scientific_name          => $p->{scientific_name}          // '',
            disease_type             => $p->{disease_type}             // '',
            host_type                => $p->{host_type}                // '',
            causative_agent          => $p->{causative_agent}          // '',
            transmission             => $p->{transmission}             // '',
            symptoms_description     => $p->{symptoms_description}     // '',
            diagnosis                => $p->{diagnosis}                // '',
            treatment_conventional   => $p->{treatment_conventional}   // '',
            treatment_herbal         => $p->{treatment_herbal}         // '',
            prevention               => $p->{prevention}               // '',
            prognosis                => $p->{prognosis}                // '',
            icd_code                 => $p->{icd_code}                 // '',
            distribution             => $p->{distribution}             // '',
            image                    => $p->{image}                    // '',
            url                      => $p->{url}                      // '',
            history                  => $p->{history}                  // '',
            reference                => $p->{reference}                // '',
        };

        my ($status, $msg) = $c->model('ENCYModel')->update_disease($c, $record_id, $data);

        if ($status) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_disease',
                "Disease updated successfully for record_id: $record_id");
            $c->flash->{success_msg} = "Disease details updated successfully.";
            $c->response->redirect($c->uri_for('/ENCY/Disease', $record_id));
            return;
        } else {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'edit_disease',
                "Failed to update disease: $msg");
            $c->stash(
                error_msg => "Failed to update disease: $msg",
                disease   => { %{ $disease->get_columns }, %$data },
                edit_mode => 1,
                template  => 'ENCY/DiseaseDetail.tt',
            );
            return;
        }
    }

    $self->_stash_image_files($c);
    $c->stash(
        disease   => $disease,
        edit_mode => 1,
        template  => 'ENCY/DiseaseDetail.tt',
    );
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

    # Determine which template to use based on the referer
    my $template = 'ENCY/BotanicalNameView.tt';
    if ($referer && $referer =~ /BeePastureView/) {
        $template = 'ENCY/BeePastureView.tt';
    }

    # Set the template
    $c->stash(template => $template);
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

sub bee_pasture_view :Path('/ENCY/BeePastureView') :Args(0) {
    my ( $self, $c ) = @_;

    # Initialize debug_errors array
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};

    # Log entry into the bee_pasture_view method
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'bee_pasture_view', 'Entered bee_pasture_view method');
    push @{$c->stash->{debug_errors}}, "Entered bee_pasture_view method";

    # Fetch bee forage plants data
    my $bee_plants = $c->model('DBForager')->get_bee_forage_plants();

    # If no specific bee forage plants method exists, use the general herbal data
    if (!$bee_plants || !@$bee_plants) {
        $bee_plants = $c->model('DBForager')->get_herbal_data();
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'bee_pasture_view', 'Using general herbal data for bee pasture view');
        push @{$c->stash->{debug_errors}}, "Using general herbal data for bee pasture view";
    }

    # Pass the data to the template
    $c->stash(
        herbal_data => $bee_plants,
        template => 'ENCY/BeePastureView.tt',
        debug_msg => "Bee Pasture View loaded with " . scalar(@$bee_plants) . " plants"
    );
}

sub legacy : Path('/ENCY/legacy') : Args(1) {
    my ($self, $c, $filename) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'legacy',
        "Legacy page request: $filename");

    $filename =~ s|[^A-Za-z0-9._-]||g;

    my %migrations = (
    );

    if (my $new_url = $migrations{lc($filename)}) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'legacy',
            "Redirecting migrated page $filename -> $new_url");
        $c->response->redirect($c->uri_for($new_url), 301);
        return;
    }

    $c->response->redirect(
        $c->uri_for('/LegacyStaticPages/ency/' . $filename)
    );
}

__PACKAGE__->meta->make_immutable;

1;