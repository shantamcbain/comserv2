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

sub auto : Private {
    my ($self, $c) = @_;
    my $roles     = $c->session->{roles} || [];
    my @role_list = ref $roles ? @$roles : split(/\s*,\s*/, $roles);
    $c->stash(
        is_admin  => (grep { $_ eq 'admin'                                         } @role_list) ? 1 : 0,
        is_editor => (grep { $_ eq 'admin' || $_ eq 'editor' || $_ eq 'developer' } @role_list) ? 1 : 0,
    );
    return 1;
}

sub index :Path('/ENCY') :Args(0) {
    my ( $self, $c ) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', 'Entered index method');
    $c->session->{MailServer} = "http://webmail.usbm.ca";

    my $sitename   = $c->stash->{SiteName} || $c->session->{SiteName} || 'ENCY';
    my $roles      = $c->session->{roles} || [];
    my @role_list  = ref $roles ? @$roles : split(/\s*,\s*/, $roles);
    my $is_admin   = (grep { $_ eq 'admin'                                          } @role_list) ? 1 : 0;
    my $is_editor  = (grep { $_ eq 'admin' || $_ eq 'editor' || $_ eq 'developer'  } @role_list) ? 1 : 0;

    $c->stash(
        SiteName   => $sitename,
        is_admin   => $is_admin,
        is_editor  => $is_editor,
        template   => 'ENCY/index.tt',
    );
}

sub plants             : Path('/ENCY/plants')              : Args(0) { $_[1]->response->redirect($_[1]->uri_for('/ENCY/BotanicalNameView')) }
sub herbs_alias        : Path('/ENCY/herbs')               : Args(0) { $_[1]->response->redirect($_[1]->uri_for('/ENCY/BotanicalNameView')) }
sub animals_alias      : Path('/ENCY/animals')             : Args(0) { $_[1]->response->redirect($_[1]->uri_for('/ENCY/Animal')) }
sub insects_alias      : Path('/ENCY/insects')             : Args(0) { $_[1]->response->redirect($_[1]->uri_for('/ENCY/Insect')) }
sub constituents_alias : Path('/ENCY/constituents')        : Args(0) { $_[1]->response->redirect($_[1]->uri_for('/ENCY/Constituent')) }
sub diseases_alias     : Path('/ENCY/diseases')            : Args(0) { $_[1]->response->redirect($_[1]->uri_for('/ENCY/Disease')) }
sub symptoms_alias     : Path('/ENCY/symptoms')            : Args(0) { $_[1]->response->redirect($_[1]->uri_for('/ENCY/Symptom')) }
sub drugs_alias        : Path('/ENCY/drugs')               : Args(0) { $_[1]->response->redirect($_[1]->uri_for('/ENCY/Drug')) }
sub formulas_alias     : Path('/ENCY/formulas')            : Args(0) { $_[1]->response->redirect($_[1]->uri_for('/ENCY/Formula')) }
sub glossary_alias     : Path('/ENCY/glossary')            : Args(0) { $_[1]->response->redirect($_[1]->uri_for('/ENCY/Glossary')) }
sub recipes_alias      : Path('/ENCY/recipes')             : Args(0) { $_[1]->response->redirect($_[1]->uri_for('/ENCY/Formula')) }
sub pollinators_alias  : Path('/ENCY/pollinators')         : Args(0) { $_[1]->response->redirect($_[1]->uri_for('/ENCY/BeePastureView')) }
sub bee_pasture_alias  : Path('/ENCY/bee_pasture_view')    : Args(0) { $_[1]->response->redirect($_[1]->uri_for('/ENCY/BeePastureView')) }
sub therapeutic_alias  : Path('/ENCY/therapeutic_actions') : Args(0) { $_[1]->response->redirect($_[1]->uri_for('/ENCY/Constituent')) }
sub medicinal_alias    : Path('/ENCY/medicinal_properties'): Args(0) { $_[1]->response->redirect($_[1]->uri_for('/ENCY/search', { q => 'medicinal' })) }
sub birds_alias        : Path('/ENCY/birds')               : Args(0) { $_[1]->response->redirect($_[1]->uri_for('/ENCY/Animal', { kingdom => 'Aves' })) }
sub fungi_alias        : Path('/ENCY/fungi')               : Args(0) { $_[1]->response->redirect($_[1]->uri_for('/ENCY/search', { q => 'fungi' })) }
sub ecosystems_alias   : Path('/ENCY/ecosystems')          : Args(0) { $_[1]->response->redirect($_[1]->uri_for('/ENCY/search', { q => 'ecosystem' })) }
sub conservation_alias : Path('/ENCY/conservation')        : Args(0) { $_[1]->response->redirect($_[1]->uri_for('/ENCY/search', { q => 'conservation' })) }
sub cultivation_alias  : Path('/ENCY/cultivation')         : Args(0) { $_[1]->response->redirect($_[1]->uri_for('/ENCY/search', { q => 'cultivation' })) }
# Add this subroutine to handle the '/ENCY/add_herb' path

sub edit_herb : Path('/ENCY/edit_herb') : Args(0) {
    my ($self, $c) = @_;

    unless ($c->session->{username}) {
        $c->response->redirect($c->uri_for('/user/login', { return_to => '/ENCY/edit_herb' }));
        return;
    }

    # Fetch the record_id from the session
    my $record_id = $c->request->param("record_id") || $c->session->{record_id};

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

    # Retrieve the herb record (use DBForager directly, same as herb_detail)
    my $herb = $c->model('DBForager')->get_herb_by_id($record_id);
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
        my $p = $c->request->params;
        my $_clean_url = sub {
            my $u = shift // '';
            return '' if $u =~ m{workstation\.local|bmast\.local|localhost|127\.0\.0\.1|/ENCY/entry/}i;
            return $u;
        };
        my $form_data = {
            botanical_name     => $p->{botanical_name}     // '',
            common_names       => $p->{common_names}       // '',
            key_name           => $p->{key_name}           // '',
            parts_used         => $p->{parts_used}         // '',
            sister_plants      => $p->{sister_plants}      // '',
            comments           => $p->{comments}           // '',
            ident_character    => $p->{ident_character}    // '',
            stem               => $p->{stem}               // '',
            leaves             => $p->{leaves}             // '',
            flowers            => $p->{flowers}            // '',
            fruit              => $p->{fruit}              // '',
            taste              => $p->{taste}              // '',
            odour              => $p->{odour}              // '',
            root               => $p->{root}               // '',
            image              => $p->{image}              // '',
            url                => $_clean_url->($p->{url}),
            distribution       => $p->{distribution}       // '',
            cultivation        => $p->{cultivation}        // '',
            harvest            => $p->{harvest}            // '',
            therapeutic_action => $p->{therapeutic_action} // '',
            medical_uses       => $p->{medical_uses}       // '',
            constituents       => $p->{constituents}       // '',
            solvents           => $p->{solvents}           // '',
            dosage             => $p->{dosage}             // '',
            administration     => $p->{administration}     // '',
            formulas           => $p->{formulas}           // '',
            contra_indications => $p->{contra_indications} // '',
            preparation        => $p->{preparation}        // '',
            chinese            => $p->{chinese}            // '',
            vetrinary          => $p->{vetrinary}          // '',
            homiopathic        => $p->{homiopathic}        // '',
            apis               => $p->{apis}               // 0,
            pollinator         => $p->{pollinator}         // '',
            pollen             => $p->{pollen}             // 0,
            pollennotes        => $p->{pollennotes}        // '',
            nectar             => $p->{nectar}             // 0,
            nectarnotes        => $p->{nectarnotes}        // '',
            non_med            => $p->{non_med}            // '',
            culinary           => $p->{culinary}           // '',
            history            => $p->{history}            // '',
            reference          => $p->{reference}          // '',
            share              => $p->{share}              // 0,
        };

        # Attempt to update the herb record and handle success or failure
        my ($status, $error_message) = $c->model('ENCYModel')->update_herb($c, $record_id, $form_data);

        if ($status) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_herb',
                "Herb updated successfully for record_id: $record_id.");
            my ($auto_linked, $unresolved) = $c->model('ENCYModel')->auto_link_herb_data($c, $record_id, $form_data);
            my $updated_herb = $c->model('DBForager')->get_herb_by_id($record_id) || $herb;
            my $link_msg = $auto_linked ? " Auto-linked $auto_linked record(s)." : '';
            my $todo_msg = $unresolved   ? " $unresolved unresolved term(s) logged as todos." : '';
            $c->stash(
                success_msg => "Herb updated successfully.$link_msg$todo_msg",
                herb        => $updated_herb,
                edit_mode   => 0,
                template    => 'ENCY/HerbView.tt',
            );
            return;
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
    my $is_admin  = grep { $_ eq 'admin' || $_ eq 'developer' } @{$c->session->{roles} || []};
    my $is_editor = $is_admin || grep { $_ eq 'editor' } @{$c->session->{roles} || []};
    $c->stash(
        herb            => $herb,
        edit_mode       => 1,
        is_admin        => $is_admin,
        is_editor       => $is_editor,
        ency_ai_prompt  => 'botanical_name, common_names, key_name, parts_used, sister_plants, comments, '
                         . 'ident_character, stem, leaves, flowers, fruit, taste, odour, root, image, url, '
                         . 'distribution, cultivation, harvest, '
                         . 'therapeutic_action, medical_uses, constituents, solvents, dosage, administration, '
                         . 'formulas, contra_indications, preparation, chinese, vetrinary, homiopathic, '
                         . 'pollinator, pollennotes, nectarnotes, non_med, culinary, history, reference. '
                         . 'IMPORTANT for url field: use a real external URL (Wikipedia, Plants.USDA.gov, '
                         . 'Botanical.com, etc.) — NEVER generate internal application URLs like '
                         . 'workstation.local, localhost, or /ENCY/entry/... — leave url blank if unknown. '
                         . 'For integrative fields (therapeutic_action, medical_uses, preparation) include '
                         . 'conventional, herbal, TCM, Ayurvedic, and naturopathic perspectives where known.',
        template        => 'ENCY/HerbView.tt',
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
        herb      => $herb,
        edit_mode => 0,
        template  => 'ENCY/HerbView.tt',
    );
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
    unless (grep { $_ eq 'admin' || $_ eq 'editor' || $_ eq 'developer' } @role_list) {
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
        edit_mode       => 1,
        ency_ai_prompt  => 'common_name, scientific_name, kingdom, phylum, class_name, order_name, family_name, genus, species, habitat, diet, behavior, ecological_role, therapeutic_uses, veterinary_uses, distribution, conservation_status, constituents, history, reference, url',
        template        => 'ENCY/AnimalDetail.tt',
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
    unless (grep { $_ eq 'admin' || $_ eq 'editor' || $_ eq 'developer' } @role_list) {
        $c->stash(
            error_msg => "You do not have permission to edit animals.",
            template  => 'ENCY/AnimalList.tt',
        );
        return;
    }

    my $record_id = $c->request->param("record_id") || $c->session->{record_id};

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
        my $_clean_url = sub {
            my $u = shift // '';
            return '' if $u =~ m{workstation\.local|bmast\.local|localhost|127\.0\.0\.1|/ENCY/entry/}i;
            return $u;
        };
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
            url                  => $_clean_url->($p->{url}),
            history              => $p->{history}              // '',
            reference            => $p->{reference}            // '',
        };

        my ($status, $msg) = $c->model('ENCYModel')->update_animal($c, $record_id, $data);

        if ($status) {
            my $resolve  = $c->model('ENCYModel')->auto_resolve_text_fields($c, 'animal', $record_id, $data);
            my $n_linked = scalar @{ $resolve->{linked}     || [] };
            my $n_unres  = scalar @{ $resolve->{unresolved} || [] };
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_animal',
                "Animal updated successfully for record_id: $record_id");
            $c->flash->{success_msg} = "Animal updated. Auto-linked $n_linked record(s). $n_unres unresolved term(s) logged as todos.";
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
        animal          => $animal,
        edit_mode       => 1,
        ency_ai_prompt  => 'common_name, scientific_name, kingdom, phylum, class_name, order_name, family_name, genus, species, habitat, diet, behavior, ecological_role, therapeutic_uses, veterinary_uses, distribution, conservation_status, constituents, history, reference, url',
        template        => 'ENCY/AnimalDetail.tt',
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
    unless (grep { $_ eq 'admin' || $_ eq 'editor' || $_ eq 'developer' } @role_list) {
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
        edit_mode       => 1,
        ency_ai_prompt  => 'common_name, scientific_name, order_name, family_name, genus, species, ecological_role, plants_foraged, plants_damaged, habitat, lifecycle, behavior, distribution, honey_production, pollination_notes, pest_notes, beneficial_notes, history, reference, url',
        template        => 'ENCY/InsectDetail.tt',
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
    unless (grep { $_ eq 'admin' || $_ eq 'editor' || $_ eq 'developer' } @role_list) {
        $c->stash(
            error_msg => "You do not have permission to edit insects.",
            template  => 'ENCY/InsectList.tt',
        );
        return;
    }

    my $record_id = $c->request->param("record_id") || $c->session->{record_id};

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
        my $_clean_url = sub {
            my $u = shift // '';
            return '' if $u =~ m{workstation\.local|bmast\.local|localhost|127\.0\.0\.1|/ENCY/entry/}i;
            return $u;
        };
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
            url               => $_clean_url->($p->{url}),
            history           => $p->{history}           // '',
            reference         => $p->{reference}         // '',
        };

        my ($status, $msg) = $c->model('ENCYModel')->update_insect($c, $record_id, $data);

        if ($status) {
            my $resolve  = $c->model('ENCYModel')->auto_resolve_text_fields($c, 'insect', $record_id, $data);
            my $n_linked = scalar @{ $resolve->{linked}     || [] };
            my $n_unres  = scalar @{ $resolve->{unresolved} || [] };
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_insect',
                "Insect updated successfully for record_id: $record_id");
            $c->flash->{success_msg} = "Insect updated. Auto-linked $n_linked record(s). $n_unres unresolved term(s) logged as todos.";
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
        insect          => $insect,
        edit_mode       => 1,
        ency_ai_prompt  => 'common_name, scientific_name, order_name, family_name, genus, species, ecological_role, plants_foraged, plants_damaged, habitat, lifecycle, behavior, distribution, honey_production, pollination_notes, pest_notes, beneficial_notes, history, reference, url',
        template        => 'ENCY/InsectDetail.tt',
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
    unless (grep { $_ eq 'admin' || $_ eq 'editor' || $_ eq 'developer' } @role_list) {
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
        edit_mode       => 1,
        ency_ai_prompt  => 'common_name, scientific_name, disease_type, host_type, causative_agent, transmission, symptoms_description, diagnosis, treatment_conventional, treatment_herbal, prevention, prognosis, icd_code, distribution, history, reference, url',
        template        => 'ENCY/DiseaseDetail.tt',
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
    unless (grep { $_ eq 'admin' || $_ eq 'editor' || $_ eq 'developer' } @role_list) {
        $c->stash(
            error_msg => "You do not have permission to edit diseases.",
            template  => 'ENCY/DiseaseList.tt',
        );
        return;
    }

    my $record_id = $c->request->param("record_id") || $c->session->{record_id};

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
        my $_clean_url = sub {
            my $u = shift // '';
            return '' if $u =~ m{workstation\.local|bmast\.local|localhost|127\.0\.0\.1|/ENCY/entry/}i;
            return $u;
        };
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
            url                      => $_clean_url->($p->{url}),
            history                  => $p->{history}                  // '',
            reference                => $p->{reference}                // '',
        };

        my ($status, $msg) = $c->model('ENCYModel')->update_disease($c, $record_id, $data);

        if ($status) {
            my $resolve  = $c->model('ENCYModel')->auto_resolve_text_fields($c, 'disease', $record_id, $data);
            my $n_linked = scalar @{ $resolve->{linked}     || [] };
            my $n_unres  = scalar @{ $resolve->{unresolved} || [] };
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_disease',
                "Disease updated successfully for record_id: $record_id");
            $c->flash->{success_msg} = "Disease updated. Auto-linked $n_linked record(s). $n_unres unresolved term(s) logged as todos.";
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
        disease         => $disease,
        edit_mode       => 1,
        ency_ai_prompt  => 'common_name, scientific_name, disease_type, host_type, causative_agent, transmission, symptoms_description, diagnosis, treatment_conventional, treatment_herbal, prevention, prognosis, icd_code, distribution, history, reference, url',
        template        => 'ENCY/DiseaseDetail.tt',
    );
}

sub symptoms_redirect : Path('/ENCY/symptoms') : Args(0) {
    my ($self, $c) = @_;
    $c->response->redirect($c->uri_for('/ENCY/Symptom'), 301);
}

sub symptom_list : Path('/ENCY/Symptom') : Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'symptom_list', 'Entered symptom_list');
    my $body_system = $c->request->parameters->{body_system} // '';
    my $host_type   = $c->request->parameters->{host_type}   // '';
    my %where;
    $where{body_system} = $body_system if $body_system;
    $where{host_type}   = $host_type   if $host_type;
    my $opts = %where ? { where => \%where } : {};
    my $symptoms = $c->model('ENCYModel')->list_symptoms($c, $opts);
    $c->stash(
        symptoms    => $symptoms,
        body_system => $body_system,
        host_type   => $host_type,
        template    => 'ENCY/SymptomList.tt',
    );
}

sub symptom_detail : Path('/ENCY/Symptom') : Args(1) {
    my ($self, $c, $id) = @_;

    unless (defined $id && $id =~ /^\d+$/) {
        $c->response->status(400);
        $c->response->body('Invalid symptom ID');
        return;
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'symptom_detail', "Fetching symptom ID: $id");
    my $symptom = $c->model('ENCYModel')->get_symptom_by_id($c, $id);

    unless ($symptom) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'symptom_detail', "Symptom not found for ID: $id");
        $c->response->status(404);
        $c->stash(
            error_message => "Symptom record #$id was not found.",
            template      => 'error.tt',
        );
        return;
    }

    $c->session->{record_id} = $id;
    my $related = $c->model('ENCYModel')->get_symptom_related($c, $id);
    $c->stash(
        symptom               => $symptom,
        related_diseases      => $related->{diseases}     // [],
        related_herbs         => $related->{herbs}        // [],
        related_constituents  => $related->{constituents} // [],
        edit_mode             => 0,
        template              => 'ENCY/SymptomDetail.tt',
    );
}

sub add_symptom : Path('/ENCY/Symptom/add') : Args(0) {
    my ($self, $c) = @_;

    unless ($c->session->{username}) {
        $c->response->redirect($c->uri_for('/user/login', { return_to => '/ENCY/Symptom/add' }));
        return;
    }

    my $roles = $c->session->{roles} || [];
    my @role_list = ref $roles ? @$roles : split /\s*,\s*/, $roles;
    unless (grep { $_ eq 'admin' || $_ eq 'editor' || $_ eq 'developer' } @role_list) {
        $c->stash(
            error_msg => "You do not have permission to add symptoms.",
            template  => 'ENCY/SymptomList.tt',
        );
        return;
    }

    if ($c->request->method eq 'POST') {
        my $p = $c->request->body_parameters;
        my $data = {
            name                => $p->{name}                // '',
            common_name         => $p->{common_name}         // '',
            description         => $p->{description}         // '',
            body_system         => $p->{body_system}         // '',
            severity            => $p->{severity}            // '',
            acute_chronic       => $p->{acute_chronic}       // '',
            host_type           => $p->{host_type}           // '',
            image               => $p->{image}               // '',
            url                 => $p->{url}                 // '',
            reference           => $p->{reference}           // '',
            sitename            => $p->{sitename}            // 'ENCY',
            username_of_poster  => $c->session->{username},
            group_of_poster     => $c->session->{group},
            date_time_posted    => \'NOW()',
        };

        unless ($data->{name}) {
            $c->stash(
                error_msg => "Name is required.",
                symptom   => $data,
                edit_mode => 1,
                template  => 'ENCY/SymptomDetail.tt',
            );
            return;
        }

        $c->model('ENCYModel')->add_symptom($c, $data);
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_symptom', "Symptom added: $data->{name}");
        $c->flash->{success_msg} = 'Symptom added successfully.';
        $c->response->redirect($c->uri_for('/ENCY/Symptom'));
        return;
    }

    $self->_stash_image_files($c);
    $c->stash(
        edit_mode       => 1,
        ency_ai_prompt  => 'name, common_name, description, body_system, severity, acute_chronic, host_type, reference, url',
        template        => 'ENCY/SymptomDetail.tt',
    );
}

sub edit_symptom : Path('/ENCY/Symptom/edit') : Args(0) {
    my ($self, $c) = @_;

    unless ($c->session->{username}) {
        $c->response->redirect($c->uri_for('/user/login', { return_to => '/ENCY/Symptom/edit' }));
        return;
    }

    my $roles = $c->session->{roles} || [];
    my @role_list = ref $roles ? @$roles : split /\s*,\s*/, $roles;
    unless (grep { $_ eq 'admin' || $_ eq 'editor' || $_ eq 'developer' } @role_list) {
        $c->stash(
            error_msg => "You do not have permission to edit symptoms.",
            template  => 'ENCY/SymptomList.tt',
        );
        return;
    }

    my $record_id = $c->request->param("record_id") || $c->session->{record_id};

    unless (defined $record_id && $record_id =~ /^\d+$/) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'edit_symptom',
            "Invalid or missing record_id in session.");
        $c->stash(
            error_msg => "Invalid or missing symptom record for editing. Please try again.",
            template  => 'ENCY/SymptomList.tt',
        );
        return;
    }

    my $symptom = $c->model('ENCYModel')->get_symptom_by_id($c, $record_id);
    unless ($symptom) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'edit_symptom',
            "Symptom not found for record_id: $record_id");
        $c->stash(
            error_msg => "Symptom not found in the database. Please try again.",
            template  => 'ENCY/SymptomList.tt',
        );
        return;
    }

    if ($c->request->method eq 'POST') {
        my $p = $c->request->body_parameters;
        my $_clean_url = sub {
            my $u = shift // '';
            return '' if $u =~ m{workstation\.local|bmast\.local|localhost|127\.0\.0\.1|/ENCY/entry/}i;
            return $u;
        };
        my $data = {
            name          => $p->{name}          // '',
            common_name   => $p->{common_name}   // '',
            description   => $p->{description}   // '',
            body_system   => $p->{body_system}   // '',
            severity      => $p->{severity}      // '',
            acute_chronic => $p->{acute_chronic} // '',
            host_type     => $p->{host_type}     // '',
            image         => $p->{image}         // '',
            url           => $_clean_url->($p->{url}),
            reference     => $p->{reference}     // '',
        };

        my ($status, $msg) = $c->model('ENCYModel')->update_symptom($c, $record_id, $data);

        if ($status) {
            my $resolve  = $c->model('ENCYModel')->auto_resolve_text_fields($c, 'symptom', $record_id, $data);
            my $n_linked = scalar @{ $resolve->{linked}     || [] };
            my $n_unres  = scalar @{ $resolve->{unresolved} || [] };
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_symptom',
                "Symptom updated successfully for record_id: $record_id");
            $c->flash->{success_msg} = "Symptom updated. Auto-linked $n_linked record(s). $n_unres unresolved term(s) logged as todos.";
            $c->response->redirect($c->uri_for('/ENCY/Symptom', $record_id));
            return;
        } else {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'edit_symptom',
                "Failed to update symptom: $msg");
            $c->stash(
                error_msg => "Failed to update symptom: $msg",
                symptom   => { %{ $symptom->get_columns }, %$data },
                edit_mode => 1,
                template  => 'ENCY/SymptomDetail.tt',
            );
            return;
        }
    }

    $self->_stash_image_files($c);
    $c->stash(
        symptom         => $symptom,
        edit_mode       => 1,
        ency_ai_prompt  => 'name, common_name, description, body_system, severity, acute_chronic, host_type, reference, url',
        template        => 'ENCY/SymptomDetail.tt',
    );
}

sub constituents_redirect : Path('/ENCY/constituents') : Args(0) {
    my ($self, $c) = @_;
    $c->response->redirect($c->uri_for('/ENCY/Constituent'), 301);
}

sub constituent_list : Path('/ENCY/Constituent') : Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'constituent_list', 'Entered constituent_list');
    my $chemical_class = $c->request->parameters->{chemical_class} // '';
    my $opts = $chemical_class ? { where => { chemical_class => $chemical_class } } : {};
    my $constituents = $c->model('ENCYModel')->list_constituents($c, $opts);
    $c->stash(
        constituents   => $constituents,
        chemical_class => $chemical_class,
        template       => 'ENCY/ConstituentList.tt',
    );
}

sub constituent_detail : Path('/ENCY/Constituent') : Args(1) {
    my ($self, $c, $id) = @_;

    unless (defined $id && $id =~ /^\d+$/) {
        $c->response->status(400);
        $c->response->body('Invalid constituent ID');
        return;
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'constituent_detail', "Fetching constituent ID: $id");
    my $constituent = $c->model('ENCYModel')->get_constituent_by_id($c, $id);

    unless ($constituent) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'constituent_detail', "Constituent not found for ID: $id");
        $c->response->status(404);
        $c->stash(
            error_message => "Constituent record #$id was not found.",
            template      => 'error.tt',
        );
        return;
    }

    $c->session->{record_id} = $id;
    my $related = $c->model('ENCYModel')->get_constituent_related($c, $id);
    my $linked_herbs = $c->model('ENCYModel')->resolve_names_to_herbs($c, $constituent->found_in_herbs);
    my $linked_drugs = $c->model('ENCYModel')->resolve_names_to_drugs($c, $constituent->found_in_drugs);
    $c->stash(
        constituent      => $constituent,
        related_diseases => $related->{diseases}  // [],
        related_symptoms => $related->{symptoms}  // [],
        linked_herbs     => $linked_herbs,
        linked_drugs     => $linked_drugs,
        edit_mode        => 0,
        template         => 'ENCY/ConstituentDetail.tt',
    );
}

sub add_constituent : Path('/ENCY/Constituent/add') : Args(0) {
    my ($self, $c) = @_;

    unless ($c->session->{username}) {
        $c->response->redirect($c->uri_for('/user/login', { return_to => '/ENCY/Constituent/add' }));
        return;
    }

    my $roles = $c->session->{roles} || [];
    my @role_list = ref $roles ? @$roles : split /\s*,\s*/, $roles;
    unless (grep { $_ eq 'admin' || $_ eq 'editor' || $_ eq 'developer' } @role_list) {
        $c->stash(
            error_msg => "You do not have permission to add constituents.",
            template  => 'ENCY/ConstituentList.tt',
        );
        return;
    }

    if ($c->request->method eq 'POST') {
        my $p = $c->request->body_parameters;
        my $data = {
            name                   => $p->{name}                   // '',
            common_name            => $p->{common_name}            // '',
            chemical_formula       => $p->{chemical_formula}       // '',
            chemical_class         => $p->{chemical_class}         // '',
            iupac_name             => $p->{iupac_name}             // '',
            cas_number             => $p->{cas_number}             // '',
            therapeutic_action     => $p->{therapeutic_action}     // '',
            toxicity               => $p->{toxicity}               // '',
            solubility             => $p->{solubility}             // '',
            found_in_herbs         => $p->{found_in_herbs}         // '',
            found_in_foods         => $p->{found_in_foods}         // '',
            found_in_drugs         => $p->{found_in_drugs}         // '',
            pharmacological_effects => $p->{pharmacological_effects} // '',
            research_notes         => $p->{research_notes}         // '',
            image                  => $p->{image}                  // '',
            url                    => $p->{url}                    // '',
            reference              => $p->{reference}              // '',
            sitename               => $p->{sitename}               // 'ENCY',
            username_of_poster     => $c->session->{username},
            group_of_poster        => $c->session->{group},
            date_time_posted       => \'NOW()',
        };

        my $mw_add = $p->{molecular_weight} // '';
        ($mw_add) = ($mw_add =~ /(\d+(?:\.\d+)?)/);
        $data->{molecular_weight} = defined $mw_add ? $mw_add : undef;

        unless ($data->{name}) {
            $c->stash(
                error_msg    => "Name is required.",
                constituent  => $data,
                edit_mode    => 1,
                template     => 'ENCY/ConstituentDetail.tt',
            );
            return;
        }

        my ($ok, $new_id) = $c->model('ENCYModel')->add_constituent($c, $data);
        if ($ok && $new_id) {
            if ($data->{found_in_herbs}) {
                $c->model('ENCYModel')->auto_link_herb_constituent($c, $new_id, $data->{found_in_herbs});
            }
            my $resolve = $c->model('ENCYModel')->auto_resolve_text_fields($c, 'constituent', $new_id, $data);
            my $n_linked = scalar @{ $resolve->{linked} || [] };
            my $n_unres  = scalar @{ $resolve->{unresolved} || [] };
            $c->flash->{success_msg} = "Constituent added. Auto-linked $n_linked record(s). $n_unres unresolved term(s) logged as todos.";
        } else {
            $c->flash->{success_msg} = 'Constituent added successfully.';
        }
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_constituent', "Constituent added: $data->{name}");
        $c->response->redirect($c->uri_for('/ENCY/Constituent'));
        return;
    }

    $self->_stash_image_files($c);
    $c->stash(
        edit_mode       => 1,
        ency_ai_prompt  => 'name, common_name, chemical_formula, chemical_class, iupac_name, cas_number, molecular_weight, therapeutic_action, toxicity, solubility, found_in_herbs (comma-separated herb names), found_in_foods (comma-separated food names), found_in_drugs (comma-separated drug/medication names), pharmacological_effects, research_notes, image (Wikipedia or PubChem image URL if available), url (PubChem or authoritative source URL), reference (PubChem CID, Wikipedia article, or citation)',
        template        => 'ENCY/ConstituentDetail.tt',
    );
}

sub edit_constituent : Path('/ENCY/Constituent/edit') : Args(0) {
    my ($self, $c) = @_;

    unless ($c->session->{username}) {
        $c->response->redirect($c->uri_for('/user/login', { return_to => '/ENCY/Constituent/edit' }));
        return;
    }

    my $roles = $c->session->{roles} || [];
    my @role_list = ref $roles ? @$roles : split /\s*,\s*/, $roles;
    unless (grep { $_ eq 'admin' || $_ eq 'editor' || $_ eq 'developer' } @role_list) {
        $c->stash(
            error_msg => "You do not have permission to edit constituents.",
            template  => 'ENCY/ConstituentList.tt',
        );
        return;
    }

    my $record_id = $c->request->param('record_id') || $c->session->{record_id};

    unless (defined $record_id && $record_id =~ /^\d+$/) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'edit_constituent',
            "Invalid or missing record_id in session.");
        $c->stash(
            error_msg => "Invalid or missing constituent record for editing. Please try again.",
            template  => 'ENCY/ConstituentList.tt',
        );
        return;
    }

    my $constituent = $c->model('ENCYModel')->get_constituent_by_id($c, $record_id);
    unless ($constituent) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'edit_constituent',
            "Constituent not found for record_id: $record_id");
        $c->stash(
            error_msg => "Constituent not found in the database. Please try again.",
            template  => 'ENCY/ConstituentList.tt',
        );
        return;
    }

    if ($c->request->method eq 'POST') {
        my $p = $c->request->body_parameters;
        my $data = {
            name                   => $p->{name}                   // '',
            common_name            => $p->{common_name}            // '',
            chemical_formula       => $p->{chemical_formula}       // '',
            chemical_class         => $p->{chemical_class}         // '',
            iupac_name             => $p->{iupac_name}             // '',
            cas_number             => $p->{cas_number}             // '',
            therapeutic_action     => $p->{therapeutic_action}     // '',
            toxicity               => $p->{toxicity}               // '',
            solubility             => $p->{solubility}             // '',
            found_in_herbs         => $p->{found_in_herbs}         // '',
            found_in_foods         => $p->{found_in_foods}         // '',
            found_in_drugs         => $p->{found_in_drugs}         // '',
            pharmacological_effects => $p->{pharmacological_effects} // '',
            research_notes         => $p->{research_notes}         // '',
            image                  => $p->{image}                  // '',
            url                    => $p->{url}                    // '',
            reference              => $p->{reference}              // '',
        };

        my $mw_raw = $p->{molecular_weight} // '';
        ($mw_raw) = ($mw_raw =~ /(\d+(?:\.\d+)?)/);
        $data->{molecular_weight} = defined $mw_raw ? $mw_raw : undef;

        my ($status, $msg) = $c->model('ENCYModel')->update_constituent($c, $record_id, $data);

        if ($status) {
            if ($data->{found_in_herbs}) {
                $c->model('ENCYModel')->auto_link_herb_constituent($c, $record_id, $data->{found_in_herbs});
            }
            my $resolve = $c->model('ENCYModel')->auto_resolve_text_fields($c, 'constituent', $record_id, $data);
            my $n_linked = scalar @{ $resolve->{linked} || [] };
            my $n_unres  = scalar @{ $resolve->{unresolved} || [] };
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_constituent',
                "Constituent updated successfully for record_id: $record_id");
            $c->flash->{success_msg} = "Constituent updated. Auto-linked $n_linked record(s). $n_unres unresolved term(s) logged as todos.";
            $c->response->redirect($c->uri_for('/ENCY/Constituent', $record_id));
            return;
        } else {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'edit_constituent',
                "Failed to update constituent: $msg");
            $c->stash(
                error_msg   => "Failed to update constituent: $msg",
                constituent => { $constituent->get_columns, %$data },
                edit_mode   => 1,
                template    => 'ENCY/ConstituentDetail.tt',
            );
            return;
        }
    }

    $self->_stash_image_files($c);
    $c->stash(
        constituent     => $constituent,
        edit_mode       => 1,
        ency_ai_prompt  => 'name, common_name, chemical_formula, chemical_class, iupac_name, cas_number, molecular_weight, therapeutic_action, toxicity, solubility, found_in_herbs (comma-separated herb names), found_in_foods (comma-separated food names), found_in_drugs (comma-separated drug/medication names), pharmacological_effects, research_notes, image (Wikipedia or PubChem image URL if available), url (PubChem or authoritative source URL), reference (PubChem CID, Wikipedia article, or citation)',
        template        => 'ENCY/ConstituentDetail.tt',
    );
}

sub glossary_list : Path('/ENCY/Glossary') : Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'glossary_list', 'Entered glossary_list');
    my $letter = $c->request->parameters->{letter} // '';
    my $opts = {};
    $opts->{letter} = $letter if $letter && $letter =~ /^[A-Za-z]$/;
    my $terms = $c->model('ENCYModel')->list_glossary($c, $opts);

    my %glossary_by_letter;
    for my $entry (@$terms) {
        my $first = uc(substr($entry->term, 0, 1));
        $first = '#' unless $first =~ /^[A-Z]$/;
        push @{ $glossary_by_letter{$first} }, $entry;
    }

    $c->stash(
        terms              => $terms,
        glossary_by_letter => \%glossary_by_letter,
        letter             => $letter,
        template           => 'ENCY/GlossaryList.tt',
    );
}

sub glossary_detail : Path('/ENCY/Glossary') : Args(1) {
    my ($self, $c, $id) = @_;

    unless (defined $id && $id =~ /^\d+$/) {
        $c->response->status(400);
        $c->response->body('Invalid glossary ID');
        return;
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'glossary_detail', "Fetching glossary term ID: $id");
    my $term = $c->model('ENCYModel')->get_glossary_by_id($c, $id);

    unless ($term) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'glossary_detail', "Glossary term not found for ID: $id");
        $c->response->status(404);
        $c->stash(
            error_message => "Glossary term #$id was not found.",
            template      => 'error.tt',
        );
        return;
    }

    $c->session->{record_id} = $id;
    $c->stash(
        term      => $term,
        edit_mode => 0,
        template  => 'ENCY/GlossaryDetail.tt',
    );
}

sub add_glossary : Path('/ENCY/Glossary/add') : Args(0) {
    my ($self, $c) = @_;

    unless ($c->session->{username}) {
        $c->response->redirect($c->uri_for('/user/login', { return_to => '/ENCY/Glossary/add' }));
        return;
    }

    my $roles = $c->session->{roles} || [];
    my @role_list = ref $roles ? @$roles : split /\s*,\s*/, $roles;
    unless (grep { $_ eq 'admin' || $_ eq 'editor' || $_ eq 'developer' } @role_list) {
        $c->stash(
            error_msg => "You do not have permission to add glossary terms.",
            template  => 'ENCY/GlossaryList.tt',
        );
        return;
    }

    if ($c->request->method eq 'POST') {
        my $p = $c->request->body_parameters;
        my $data = {
            term                => $p->{term}                // '',
            alternate_terms     => $p->{alternate_terms}     // '',
            definition          => $p->{definition}          // '',
            category            => $p->{category}            // '',
            context             => $p->{context}             // '',
            etymology           => $p->{etymology}           // '',
            examples            => $p->{examples}            // '',
            related_terms       => $p->{related_terms}       // '',
            url                 => $p->{url}                 // '',
            sitename            => $p->{sitename}            // 'ENCY',
            username_of_poster  => $c->session->{username},
            group_of_poster     => $c->session->{group},
            date_time_posted    => \'NOW()',
        };

        unless ($data->{term}) {
            $c->stash(
                error_msg => "Term is required.",
                term      => $data,
                edit_mode => 1,
                template  => 'ENCY/GlossaryDetail.tt',
            );
            return;
        }

        unless ($data->{definition}) {
            $c->stash(
                error_msg => "Definition is required.",
                term      => $data,
                edit_mode => 1,
                template  => 'ENCY/GlossaryDetail.tt',
            );
            return;
        }

        $c->model('ENCYModel')->add_glossary($c, $data);
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_glossary', "Glossary term added: $data->{term}");
        $c->flash->{success_msg} = 'Glossary term added successfully.';
        $c->response->redirect($c->uri_for('/ENCY/Glossary'));
        return;
    }

    $c->stash(
        edit_mode       => 1,
        ency_ai_prompt  => 'term, alternate_terms, definition, category, context, etymology, examples, related_terms',
        template        => 'ENCY/GlossaryDetail.tt',
    );
}

sub edit_glossary : Path('/ENCY/Glossary/edit') : Args(0) {
    my ($self, $c) = @_;

    unless ($c->session->{username}) {
        $c->response->redirect($c->uri_for('/user/login', { return_to => '/ENCY/Glossary/edit' }));
        return;
    }

    my $roles = $c->session->{roles} || [];
    my @role_list = ref $roles ? @$roles : split /\s*,\s*/, $roles;
    unless (grep { $_ eq 'admin' || $_ eq 'editor' || $_ eq 'developer' } @role_list) {
        $c->stash(
            error_msg => "You do not have permission to edit glossary terms.",
            template  => 'ENCY/GlossaryList.tt',
        );
        return;
    }

    my $record_id = $c->request->param("record_id") || $c->session->{record_id};

    unless (defined $record_id && $record_id =~ /^\d+$/) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'edit_glossary',
            "Invalid or missing record_id in session.");
        $c->stash(
            error_msg => "Invalid or missing glossary record for editing. Please try again.",
            template  => 'ENCY/GlossaryList.tt',
        );
        return;
    }

    my $term = $c->model('ENCYModel')->get_glossary_by_id($c, $record_id);
    unless ($term) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'edit_glossary',
            "Glossary term not found for record_id: $record_id");
        $c->stash(
            error_msg => "Glossary term not found in the database. Please try again.",
            template  => 'ENCY/GlossaryList.tt',
        );
        return;
    }

    if ($c->request->method eq 'POST') {
        my $p = $c->request->body_parameters;
        my $data = {
            term            => $p->{term}            // '',
            alternate_terms => $p->{alternate_terms} // '',
            definition      => $p->{definition}      // '',
            category        => $p->{category}        // '',
            context         => $p->{context}         // '',
            etymology       => $p->{etymology}       // '',
            examples        => $p->{examples}        // '',
            related_terms   => $p->{related_terms}   // '',
            url             => $p->{url}             // '',
        };

        my ($status, $msg) = $c->model('ENCYModel')->update_glossary($c, $record_id, $data);

        if ($status) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_glossary',
                "Glossary term updated successfully for record_id: $record_id");
            $c->flash->{success_msg} = "Glossary term updated successfully.";
            $c->response->redirect($c->uri_for('/ENCY/Glossary', $record_id));
            return;
        } else {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'edit_glossary',
                "Failed to update glossary term: $msg");
            $c->stash(
                error_msg => "Failed to update glossary term: $msg",
                term      => { %{ $term->get_columns }, %$data },
                edit_mode => 1,
                template  => 'ENCY/GlossaryDetail.tt',
            );
            return;
        }
    }

    $c->stash(
        term            => $term,
        edit_mode       => 1,
        ency_ai_prompt  => 'term, alternate_terms, definition, category, context, etymology, examples, related_terms',
        template        => 'ENCY/GlossaryDetail.tt',
    );
}

sub create_reference :Local {
    my ( $self, $c ) = @_;
    # Implement the logic to display the form for creating a new reference
    $c->stash(template => 'ency/create_reference_form.tt');
}
sub search :Path('/ENCY/search') :Args(0) {
    my ($self, $c) = @_;

    my $query = $c->request->parameters->{search_string} // $c->request->parameters->{q} // '';
    $query =~ s/^\s+|\s+$//g;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'search', "Search query: $query");

    my $ency_model = $c->model('ENCYModel');

    my $herbs        = $query ? $c->model('DBForager')->searchHerbs($c, $query) : [];
    my $animals      = $query ? $ency_model->search_animals($c, $query)      : [];
    my $insects      = $query ? $ency_model->search_insects($c, $query)      : [];
    my $diseases     = $query ? $ency_model->search_diseases($c, $query)     : [];
    my $symptoms     = $query ? $ency_model->search_symptoms($c, $query)     : [];
    my $constituents = $query ? $ency_model->search_constituents($c, $query) : [];
    my $glossary     = $query ? $ency_model->search_glossary($c, $query)     : [];
    my $drugs        = $query ? $ency_model->search_drugs($c, $query)        : [];

    my $total_results = scalar(@$herbs) + scalar(@$animals) + scalar(@$insects)
                      + scalar(@$diseases) + scalar(@$symptoms)
                      + scalar(@$constituents) + scalar(@$glossary)
                      + scalar(@$drugs);

    my $ai_fallback = ($query && $total_results == 0) ? 1 : 0;

    $c->stash(
        search_results => {
            herbs        => $herbs,
            animals      => $animals,
            insects      => $insects,
            diseases     => $diseases,
            symptoms     => $symptoms,
            constituents => $constituents,
            glossary     => $glossary,
            drugs        => $drugs,
        },
        herbal_data    => $herbs,
        search_query   => $query,
        total_results  => $total_results,
        ai_fallback    => $ai_fallback,
        ai_query       => $query,
        template       => 'ENCY/SearchResults.tt',
    );
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

sub herb_list : Path('/ENCY/Herb') : Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'herb_list', 'Entered herb_list');
    my $forager_data = $c->model('DBForager')->get_herbal_data();
    $c->stash(herbal_data => $forager_data, template => 'ENCY/BotanicalNameView.tt');
}

sub herb_detail_by_id : Path('/ENCY/Herb') : Args(1) {
    my ($self, $c, $id) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'herb_detail_by_id', "Herb id: $id");
    $c->response->redirect($c->uri_for('/ENCY/herb_detail', $id), 301);
}

sub drug_list : Path('/ENCY/Drug') : Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'drug_list', 'Entered drug_list');
    my $where = {};
    my $drug_class = $c->request->param('drug_class');
    $where->{drug_class} = $drug_class if $drug_class;
    my $roles     = $c->session->{roles} || [];
    my @role_list = ref $roles ? @$roles : split /\s*,\s*/, $roles;
    my $db_error;
    my $drugs;
    eval {
        $drugs = $c->model('ENCYModel')->list_drugs($c, { where => $where });
    } or do {
        my $err = $@ || 'Unknown DB error';
        $db_error = "Database error: $err — the drug table may not exist yet. Admin: run schema compare to create ency_drug_tb.";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'drug_list', $err);
        $drugs = [];
    };
    $c->stash(
        drugs     => $drugs,
        db_error  => $db_error,
        is_admin  => (grep { $_ eq 'admin' } @role_list) ? 1 : 0,
        is_editor => (grep { $_ eq 'admin' || $_ eq 'editor' || $_ eq 'developer' } @role_list) ? 1 : 0,
        template  => 'ENCY/DrugList.tt',
    );
}

sub drug_detail : Path('/ENCY/Drug') : Args(1) {
    my ($self, $c, $id) = @_;

    unless (defined $id && $id =~ /^\d+$/) {
        $c->response->status(400);
        $c->response->body('Invalid drug ID');
        return;
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'drug_detail', "Fetching drug ID: $id");
    my $drug = $c->model('ENCYModel')->get_drug_by_id($c, $id);

    unless ($drug) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'drug_detail', "Drug not found for ID: $id");
        $c->response->status(404);
        $c->stash(
            error_message => "Drug record #$id was not found.",
            template      => 'error.tt',
        );
        return;
    }

    $c->session->{record_id} = $id;
    my $related = $c->model('ENCYModel')->get_drug_related($c, $id);
    $c->stash(
        drug             => $drug,
        related_diseases => $related->{diseases}         // [],
        related_symptoms => $related->{symptoms}         // [],
        herb_interactions => $related->{herb_interactions} // [],
        edit_mode        => 0,
        template         => 'ENCY/DrugDetail.tt',
    );
}

sub add_drug : Path('/ENCY/Drug/add') : Args(0) {
    my ($self, $c) = @_;

    unless ($c->session->{username}) {
        $c->response->redirect($c->uri_for('/user/login', { return_to => '/ENCY/Drug/add' }));
        return;
    }

    my $roles = $c->session->{roles} || [];
    my @role_list = ref $roles ? @$roles : split /\s*,\s*/, $roles;
    unless (grep { $_ eq 'admin' || $_ eq 'editor' || $_ eq 'developer' } @role_list) {
        $c->stash(
            error_msg => "You do not have permission to add drugs.",
            template  => 'ENCY/DrugList.tt',
        );
        return;
    }

    if ($c->request->method eq 'POST') {
        my $p = $c->request->body_parameters;
        my $data = {
            brand_name              => $p->{brand_name}              // '',
            generic_name            => $p->{generic_name}            // '',
            inn_name                => $p->{inn_name}                // '',
            drug_class              => $p->{drug_class}              // '',
            drug_subclass           => $p->{drug_subclass}           // '',
            formulation             => $p->{formulation}             // '',
            strength                => $p->{strength}                // '',
            package_size            => $p->{package_size}            // '',
            route_of_administration => $p->{route_of_administration} // '',
            prescription_status     => $p->{prescription_status}     // 'Rx',
            din_number              => $p->{din_number}              // '',
            ndc_code                => $p->{ndc_code}                // '',
            atc_code                => $p->{atc_code}                // '',
            manufacturer            => $p->{manufacturer}            // '',
            active_ingredients      => $p->{active_ingredients}      // '',
            inactive_ingredients    => $p->{inactive_ingredients}    // '',
            mechanism_of_action     => $p->{mechanism_of_action}     // '',
            pharmacokinetics        => $p->{pharmacokinetics}        // '',
            pharmacodynamics        => $p->{pharmacodynamics}        // '',
            indications             => $p->{indications}             // '',
            contraindications       => $p->{contraindications}       // '',
            warnings                => $p->{warnings}                // '',
            side_effects            => $p->{side_effects}            // '',
            drug_interactions       => $p->{drug_interactions}       // '',
            herb_drug_interactions  => $p->{herb_drug_interactions}  // '',
            dosage_adult            => $p->{dosage_adult}            // '',
            dosage_pediatric        => $p->{dosage_pediatric}        // '',
            dosage_geriatric        => $p->{dosage_geriatric}        // '',
            duration_typical        => $p->{duration_typical}        // '',
            storage                 => $p->{storage}                 // '',
            pregnancy_category      => $p->{pregnancy_category}      // '',
            breastfeeding_notes     => $p->{breastfeeding_notes}     // '',
            herbal_alternatives     => $p->{herbal_alternatives}     // '',
            naturopathic_notes      => $p->{naturopathic_notes}      // '',
            image                   => $p->{image}                   // '',
            url                     => $p->{url}                     // '',
            reference               => $p->{reference}               // '',
            sitename                => $p->{sitename}                // 'ENCY',
            username_of_poster      => $c->session->{username},
            group_of_poster         => $c->session->{group},
            date_time_posted        => \'NOW()',
        };

        unless ($data->{brand_name} || $data->{generic_name}) {
            $c->stash(
                error_msg => "Brand name or generic name is required.",
                drug      => $data,
                edit_mode => 1,
                template  => 'ENCY/DrugDetail.tt',
            );
            return;
        }

        my ($ok, $msg, $new_id) = $c->model('ENCYModel')->add_drug($c, $data);
        $self->logging->log_with_details($c, $ok ? 'info' : 'error', __FILE__, __LINE__, 'add_drug',
            ($ok ? "Drug added: " : "Drug add FAILED: ") . ($data->{brand_name} || $data->{generic_name}));
        unless ($ok) {
            $c->stash(
                error_msg => "Could not save drug: $msg",
                drug      => $data,
                edit_mode => 1,
                ency_ai_prompt => q{brand_name, generic_name},
                template  => 'ENCY/DrugDetail.tt',
            );
            return;
        }
        if ($new_id) {
            my $resolve = $c->model('ENCYModel')->auto_resolve_text_fields($c, 'drug', $new_id, $data);
            my $n_linked = scalar @{ $resolve->{linked} || [] };
            my $n_unres  = scalar @{ $resolve->{unresolved} || [] };
            $c->flash->{success_msg} = "Drug added. Auto-linked $n_linked record(s). $n_unres unresolved term(s) logged as todos.";
        } else {
            $c->flash->{success_msg} = 'Drug added successfully.';
        }
        $c->response->redirect($c->uri_for('/ENCY/Drug', $new_id ? ($new_id) : ()));
        return;
    }

    $self->_stash_image_files($c);
    $c->stash(
        edit_mode      => 1,
        ency_ai_prompt => q{brand_name (trade name), generic_name (international nonproprietary name), inn_name, drug_class (e.g. Corticosteroid/Antibiotic/NSAID), drug_subclass (e.g. Topical corticosteroid - potent), formulation (e.g. Cream/Tablet/Injection), strength (e.g. 0.05%), package_size (e.g. 200g), route_of_administration (e.g. Topical/Oral/IV), prescription_status (use EXACTLY one of: Rx, OTC, Schedule, Controlled), din_number (Health Canada DIN if Canadian product), ndc_code (US NDC if applicable), atc_code (WHO ATC code), manufacturer (company name), active_ingredients (list all active ingredients with concentrations), inactive_ingredients (excipients), mechanism_of_action (how the drug works pharmacologically), pharmacokinetics (absorption distribution metabolism excretion), pharmacodynamics (effects on body systems), indications (all approved uses and conditions treated), contraindications (when NOT to use), warnings (black box warnings precautions), side_effects (common and serious adverse effects), drug_interactions (significant drug-drug interactions), herb_drug_interactions (known interactions with herbal medicines e.g. St Johns Wort), dosage_adult (standard adult dosing regimen), dosage_pediatric (pediatric dosing if applicable), dosage_geriatric (geriatric considerations), duration_typical (typical course length), storage (storage requirements), pregnancy_category (A/B/C/D/X or equivalent), breastfeeding_notes (safety during lactation), herbal_alternatives (natural alternatives used for same conditions), naturopathic_notes (naturopathic integrative perspective on this drug and alternatives). Fill ALL fields you have knowledge of.},
        template       => 'ENCY/DrugDetail.tt',
    );
}

sub edit_drug : Path('/ENCY/Drug/edit') : Args(0) {
    my ($self, $c) = @_;

    unless ($c->session->{username}) {
        $c->response->redirect($c->uri_for('/user/login', { return_to => '/ENCY/Drug/edit' }));
        return;
    }

    my $roles = $c->session->{roles} || [];
    my @role_list = ref $roles ? @$roles : split /\s*,\s*/, $roles;
    unless (grep { $_ eq 'admin' || $_ eq 'editor' || $_ eq 'developer' } @role_list) {
        $c->stash(
            error_msg => "You do not have permission to edit drugs.",
            template  => 'ENCY/DrugList.tt',
        );
        return;
    }

    my $record_id = $c->request->param('record_id') || $c->session->{record_id};

    unless (defined $record_id && $record_id =~ /^\d+$/) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'edit_drug',
            "Invalid or missing record_id in session.");
        $c->stash(
            error_msg => "Invalid or missing drug record for editing. Please try again.",
            template  => 'ENCY/DrugList.tt',
        );
        return;
    }

    my $drug = $c->model('ENCYModel')->get_drug_by_id($c, $record_id);
    unless ($drug) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'edit_drug',
            "Drug not found for record_id: $record_id");
        $c->stash(
            error_msg => "Drug not found in the database. Please try again.",
            template  => 'ENCY/DrugList.tt',
        );
        return;
    }

    if ($c->request->method eq 'POST') {
        my $p = $c->request->body_parameters;
        my $data = {
            brand_name              => $p->{brand_name}              // '',
            generic_name            => $p->{generic_name}            // '',
            inn_name                => $p->{inn_name}                // '',
            drug_class              => $p->{drug_class}              // '',
            drug_subclass           => $p->{drug_subclass}           // '',
            formulation             => $p->{formulation}             // '',
            strength                => $p->{strength}                // '',
            package_size            => $p->{package_size}            // '',
            route_of_administration => $p->{route_of_administration} // '',
            prescription_status     => $p->{prescription_status}     // 'Rx',
            din_number              => $p->{din_number}              // '',
            ndc_code                => $p->{ndc_code}                // '',
            atc_code                => $p->{atc_code}                // '',
            manufacturer            => $p->{manufacturer}            // '',
            active_ingredients      => $p->{active_ingredients}      // '',
            inactive_ingredients    => $p->{inactive_ingredients}    // '',
            mechanism_of_action     => $p->{mechanism_of_action}     // '',
            pharmacokinetics        => $p->{pharmacokinetics}        // '',
            pharmacodynamics        => $p->{pharmacodynamics}        // '',
            indications             => $p->{indications}             // '',
            contraindications       => $p->{contraindications}       // '',
            warnings                => $p->{warnings}                // '',
            side_effects            => $p->{side_effects}            // '',
            drug_interactions       => $p->{drug_interactions}       // '',
            herb_drug_interactions  => $p->{herb_drug_interactions}  // '',
            dosage_adult            => $p->{dosage_adult}            // '',
            dosage_pediatric        => $p->{dosage_pediatric}        // '',
            dosage_geriatric        => $p->{dosage_geriatric}        // '',
            duration_typical        => $p->{duration_typical}        // '',
            storage                 => $p->{storage}                 // '',
            pregnancy_category      => $p->{pregnancy_category}      // '',
            breastfeeding_notes     => $p->{breastfeeding_notes}     // '',
            herbal_alternatives     => $p->{herbal_alternatives}     // '',
            naturopathic_notes      => $p->{naturopathic_notes}      // '',
            image                   => $p->{image}                   // '',
            url                     => $p->{url}                     // '',
            reference               => $p->{reference}               // '',
        };

        my ($status, $msg) = $c->model('ENCYModel')->update_drug($c, $record_id, $data);

        if ($status) {
            my $resolve = $c->model('ENCYModel')->auto_resolve_text_fields($c, 'drug', $record_id, $data);
            my $n_linked = scalar @{ $resolve->{linked} || [] };
            my $n_unres  = scalar @{ $resolve->{unresolved} || [] };
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_drug',
                "Drug updated successfully for record_id: $record_id");
            $c->flash->{success_msg} = "Drug updated. Auto-linked $n_linked record(s). $n_unres unresolved term(s) logged as todos.";
            $c->response->redirect($c->uri_for('/ENCY/Drug', $record_id));
            return;
        } else {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'edit_drug',
                "Failed to update drug: $msg");
            $c->stash(
                error_msg => "Failed to update drug: $msg",
                drug      => { %{ $drug->get_columns }, %$data },
                edit_mode => 1,
                template  => 'ENCY/DrugDetail.tt',
            );
            return;
        }
    }

    $self->_stash_image_files($c);
    $c->stash(
        drug           => $drug,
        edit_mode      => 1,
        ency_ai_prompt => q{brand_name (trade name), generic_name (international nonproprietary name), inn_name, drug_class (e.g. Corticosteroid/Antibiotic/NSAID), drug_subclass (e.g. Topical corticosteroid - potent), formulation (e.g. Cream/Tablet/Injection), strength (e.g. 0.05%), package_size (e.g. 200g), route_of_administration (e.g. Topical/Oral/IV), prescription_status (use EXACTLY one of: Rx, OTC, Schedule, Controlled), din_number (Health Canada DIN if Canadian product), ndc_code (US NDC if applicable), atc_code (WHO ATC code), manufacturer (company name), active_ingredients (list all active ingredients with concentrations), inactive_ingredients (excipients), mechanism_of_action (how the drug works pharmacologically), pharmacokinetics (absorption distribution metabolism excretion), pharmacodynamics (effects on body systems), indications (all approved uses and conditions treated), contraindications (when NOT to use), warnings (black box warnings precautions), side_effects (common and serious adverse effects), drug_interactions (significant drug-drug interactions), herb_drug_interactions (known interactions with herbal medicines e.g. St Johns Wort), dosage_adult (standard adult dosing regimen), dosage_pediatric (pediatric dosing if applicable), dosage_geriatric (geriatric considerations), duration_typical (typical course length), storage (storage requirements), pregnancy_category (A/B/C/D/X or equivalent), breastfeeding_notes (safety during lactation), herbal_alternatives (natural alternatives used for same conditions), naturopathic_notes (naturopathic integrative perspective on this drug and alternatives). Fill ALL fields you have knowledge of.},
        template       => 'ENCY/DrugDetail.tt',
    );
}

sub formula_list : Path('/ENCY/Formula') : Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'formula_list', 'Formula list');
    my $roles    = $c->session->{roles} || [];
    my $is_admin  = grep { $_ eq 'admin'                                         } (ref $roles ? @$roles : split(/s*,s*/, $roles));
    my $is_editor = grep { $_ eq 'admin' || $_ eq 'editor' || $_ eq 'developer' } (ref $roles ? @$roles : split(/s*,s*/, $roles));
    my $q = $c->request->param('q') || '';
    my $formulas;
    eval {
        my $model = $c->model('ENCYModel');
        if ($q) {
            $formulas = $model->search_formulas($c, $q);
        } else {
            $formulas = $model->list_formulas($c, {});
        }
    };
    if ($@) {
        $c->stash(db_error => "Database error loading formulas: $@");
        $formulas = [];
    }
    my $ai_fallback = ($q && (!$formulas || !@$formulas)) ? 1 : 0;
    $c->stash(
        formulas      => $formulas,
        search_query  => $q,
        is_admin      => $is_admin,
        is_editor     => $is_editor,
        ai_fallback   => $ai_fallback,
        ai_query      => $q,
        template      => 'ENCY/FormulaList.tt',
    );
}

sub formula_detail : Path('/ENCY/Formula') : Args(1) {
    my ($self, $c, $id) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'formula_detail', "Formula detail id=$id");
    my $roles    = $c->session->{roles} || [];
    my $is_admin  = grep { $_ eq 'admin'                                         } (ref $roles ? @$roles : split(/s*,s*/, $roles));
    my $is_editor = grep { $_ eq 'admin' || $_ eq 'editor' || $_ eq 'developer' } (ref $roles ? @$roles : split(/s*,s*/, $roles));
    my ($formula, $herb_links, $disease_links) = $c->model('ENCYModel')->get_formula_with_herbs($c, $id);
    unless ($formula) {
        $c->stash(error_msg => "Formula $id not found.", template => 'ENCY/FormulaList.tt');
        return;
    }
    if ($is_editor && $c->request->method eq 'POST' && $c->request->param('set_edit')) {
        $c->session->{formula_record_id} = $id;
        $c->response->redirect($c->uri_for('/ENCY/Formula/edit'));
        return;
    }
    $c->stash(
        formula       => $formula,
        herb_links    => $herb_links,
        disease_links => $disease_links,
        is_admin      => $is_admin,
        is_editor     => $is_editor,
        edit_mode     => 0,
        template      => 'ENCY/FormulaDetail.tt',
    );
}

sub add_formula : Path('/ENCY/Formula/add') : Args(0) {
    my ($self, $c) = @_;
    my $roles    = $c->session->{roles} || [];
    my $is_admin  = grep { $_ eq 'admin'                                         } (ref $roles ? @$roles : split(/s*,s*/, $roles));
    my $is_editor = grep { $_ eq 'admin' || $_ eq 'editor' || $_ eq 'developer' } (ref $roles ? @$roles : split(/s*,s*/, $roles));
    unless ($is_editor) {
        $c->stash(error_msg => 'Editor access required.', template => 'ENCY/FormulaList.tt');
        return;
    }
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_formula', 'Add formula');
    if ($c->request->method eq 'POST') {
        my $data = {
            formula_number     => $c->request->param('formula_number') || undef,
            name               => $c->request->param('name')               || '',
            indications        => $c->request->param('indications')        || undef,
            description        => $c->request->param('description')        || undef,
            herbs_raw          => $c->request->param('herbs_raw')          || undef,
            preparation        => $c->request->param('preparation')        || undef,
            dosage             => $c->request->param('dosage')             || undef,
            administration     => $c->request->param('administration')     || undef,
            notes              => $c->request->param('notes')              || undef,
            reference          => $c->request->param('reference')          || undef,
            url                => $c->request->param('url')                || undef,
            image              => $c->request->param('image')              || undef,
            sitename           => $c->request->param('sitename')           || 'ENCY',
            source             => $c->request->param('source')             || 'USBM Legacy',
            username_of_poster => $c->session->{username}                 || '',
            group_of_poster    => $c->session->{group}                    || '',
            date_time_posted   => scalar localtime,
            share              => 0,
        };
        unless ($data->{name}) {
            $c->stash(error_msg => 'Formula name is required.', formula => bless($data, 'HASH'), edit_mode => 1, is_admin => $is_admin, is_editor => $is_editor, template => 'ENCY/FormulaDetail.tt');
            return;
        }
        my ($ok, $msg, $new_id) = $c->model('ENCYModel')->add_formula($c, $data);
        if ($ok) {
            $c->flash->{success_msg} = "Formula added successfully.";
            $c->response->redirect($c->uri_for('/ENCY/Formula/' . $new_id));
        } else {
            $c->stash(error_msg => "Could not save formula: $msg", formula => bless($data, 'HASH'), edit_mode => 1, is_admin => $is_admin, is_editor => $is_editor, template => 'ENCY/FormulaDetail.tt');
        }
        return;
    }
    $c->stash(
        formula   => {},
        edit_mode => 1,
        is_admin  => $is_admin,
        ency_ai_prompt => 'name, formula_number, indications, description, herbs_raw (one herb per line with quantity and botanical name), preparation, dosage, administration, notes, reference',
        template  => 'ENCY/FormulaDetail.tt',
    );
}

sub edit_formula : Path('/ENCY/Formula/edit') : Args(0) {
    my ($self, $c) = @_;
    my $roles    = $c->session->{roles} || [];
    my $is_admin  = grep { $_ eq 'admin'                                         } (ref $roles ? @$roles : split(/s*,s*/, $roles));
    my $is_editor = grep { $_ eq 'admin' || $_ eq 'editor' || $_ eq 'developer' } (ref $roles ? @$roles : split(/s*,s*/, $roles));
    unless ($is_editor) {
        $c->stash(error_msg => 'Editor access required.', template => 'ENCY/FormulaList.tt');
        return;
    }
    my $id = $c->session->{formula_record_id} || $c->request->param('record_id');
    unless ($id) {
        $c->response->redirect($c->uri_for('/ENCY/Formula'));
        return;
    }
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_formula', "Edit formula id=$id");
    if ($c->request->method eq 'POST') {
        my $data = {
            formula_number     => $c->request->param('formula_number') || undef,
            name               => $c->request->param('name')               || '',
            indications        => $c->request->param('indications')        || undef,
            description        => $c->request->param('description')        || undef,
            herbs_raw          => $c->request->param('herbs_raw')          || undef,
            preparation        => $c->request->param('preparation')        || undef,
            dosage             => $c->request->param('dosage')             || undef,
            administration     => $c->request->param('administration')     || undef,
            notes              => $c->request->param('notes')              || undef,
            reference          => $c->request->param('reference')          || undef,
            url                => $c->request->param('url')                || undef,
            image              => $c->request->param('image')              || undef,
            sitename           => $c->request->param('sitename')           || 'ENCY',
            source             => $c->request->param('source')             || undef,
        };
        my ($ok, $msg) = $c->model('ENCYModel')->update_formula($c, $id, $data);
        if ($ok) {
            $c->flash->{success_msg} = "Formula updated successfully.";
            $c->response->redirect($c->uri_for('/ENCY/Formula/' . $id));
        } else {
            my ($formula, $herb_links, $disease_links) = $c->model('ENCYModel')->get_formula_with_herbs($c, $id);
            $c->stash(error_msg => "Could not update formula: $msg", formula => $formula, herb_links => $herb_links, disease_links => $disease_links, edit_mode => 1, is_admin => $is_admin, is_editor => $is_editor, template => 'ENCY/FormulaDetail.tt');
        }
        return;
    }
    my ($formula, $herb_links, $disease_links) = $c->model('ENCYModel')->get_formula_with_herbs($c, $id);
    unless ($formula) {
        $c->flash->{error_msg} = "Formula $id not found.";
        $c->response->redirect($c->uri_for('/ENCY/Formula'));
        return;
    }
    $c->stash(
        formula       => $formula,
        herb_links    => $herb_links,
        disease_links => $disease_links,
        edit_mode     => 1,
        is_admin      => $is_admin,
        ency_ai_prompt => 'name, formula_number, indications, description, herbs_raw (one herb per line with quantity and botanical name), preparation, dosage, administration, notes, reference',
        template      => 'ENCY/FormulaDetail.tt',
    );
}

sub practitioner_type_list : Path('/ENCY/PractitionerType') : Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'practitioner_type_list', 'PractitionerType list not yet implemented');
    $c->stash(
        entity_name => 'Practitioner Type',
        entity_desc => 'Types of healthcare practitioners — allopathic physicians, naturopaths, herbalists, homeopaths, TCM practitioners, Ayurvedic practitioners — and how each approaches diagnosis and treatment.',
        template    => 'ENCY/ComingSoon.tt',
    );
}

sub practitioner_type_detail : Path('/ENCY/PractitionerType') : Args(1) {
    my ($self, $c, $id) = @_;
    $c->response->redirect($c->uri_for('/ENCY/PractitionerType'), 302);
}

sub api_resolve : Path('/ENCY/api/resolve') : Args(0) {
    my ($self, $c) = @_;
    $c->response->content_type('application/json; charset=utf-8');
    my $type  = $c->request->param('type')  || '';
    my $query = $c->request->param('q')     || '';
    unless ($type && length($query) >= 2) {
        $c->response->body('{"results":[]}');
        return;
    }
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'api_resolve', "Resolving type=$type q=$query");
    my @results;
    eval {
        my $model = $c->model('ENCYModel');
        if ($type eq 'herb') {
            my @rows = $model->forager_schema->resultset('Herb')->search(
                { -or => [
                    common_name    => { like => "%$query%" },
                    botanical_name => { like => "%$query%" },
                ]},
                { rows => 8, order_by => 'common_name' }
            )->all;
            @results = map { {
                id         => $_->record_id,
                name       => $_->common_name // '',
                secondary  => $_->botanical_name // '',
                url        => '/ENCY/herb_detail/' . $_->record_id,
            } } @rows;
        } elsif ($type eq 'disease') {
            my @rows = $model->ency_schema->resultset('Disease')->search(
                { common_name => { like => "%$query%" } },
                { rows => 8, order_by => 'common_name' }
            )->all;
            @results = map { {
                id        => $_->record_id,
                name      => $_->common_name // '',
                secondary => $_->disease_type // '',
                url       => '/ENCY/Disease/' . $_->record_id,
            } } @rows;
        } elsif ($type eq 'symptom') {
            my @rows = $model->ency_schema->resultset('Symptom')->search(
                { -or => [
                    name        => { like => "%$query%" },
                    common_name => { like => "%$query%" },
                ]},
                { rows => 8, order_by => 'name' }
            )->all;
            @results = map { {
                id        => $_->record_id,
                name      => $_->name // '',
                secondary => $_->body_system // '',
                url       => '/ENCY/Symptom/' . $_->record_id,
            } } @rows;
        } elsif ($type eq 'constituent') {
            my @rows = $model->ency_schema->resultset('Constituent')->search(
                { -or => [
                    name        => { like => "%$query%" },
                    common_name => { like => "%$query%" },
                ]},
                { rows => 8, order_by => 'name' }
            )->all;
            @results = map { {
                id        => $_->record_id,
                name      => $_->name // '',
                secondary => $_->chemical_class // '',
                url       => '/ENCY/Constituent/' . $_->record_id,
            } } @rows;
        }
    } or do {
        my $err = $@ || 'unknown';
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'api_resolve', "Resolve error: $err");
    };
    require JSON;
    $c->response->body(JSON::encode_json({ results => \@results }));
}

__PACKAGE__->meta->make_immutable;

1;