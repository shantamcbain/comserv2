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
sub add_herb :Path('/ENCY/add_herb') :Args(0) {
    my ($self, $c) = @_;

    # Log the entry into the add_herb method
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_herb', 'Entered add_herb method');

    # Set the template for adding a new herb
    $c->stash(template => 'ENCY/add_herb_form.tt');
}

sub edit_herb : Path('/ENCY/edit_herb') : Args(0) {
    my ($self, $c) = @_;

    # Try to get record_id from various sources in order of preference:
    # 1. Form submission 'record_id' field (for POST requests)
    # 2. URL query parameter 'id' (for GET requests from links)
    # 3. Session (for continuity between requests)
    my $record_id = $c->request->param('record_id') || 
                   $c->request->param('id') || 
                   $c->session->{record_id};
    
    # Log which source provided the record_id
    my $source = "";
    if ($c->request->param('record_id')) {
        $source = "form field 'record_id'";
    } elsif ($c->request->param('id')) {
        $source = "URL parameter 'id'";
    } elsif ($c->session->{record_id}) {
        $source = "session";
    } else {
        $source = "none (record_id is undefined)";
    }
    
    # Store the record_id in session for future use
    $c->session->{record_id} = $record_id if defined $record_id;

    # Log the record_id source for debugging
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_herb',
        "Using record_id: $record_id. Source: $source");

    # Validate the record_id; if invalid, show error (stay on the HerbView page)
    unless (defined $record_id && $record_id =~ /^\d+$/) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'edit_herb',
            "Invalid or missing record_id in both URL parameters and session.");
        $c->stash(
            error_msg => "Invalid or missing herb record for editing. Please try again.",
            template  => 'ENCY/HerbView.tt',
            edit_mode => 0, # Keep edit_mode off since no valid record is loaded
        );
        return; # Do not redirect; just render the view with an error message
    }

    # Retrieve the herb record using DBForager model (same as herb_detail method)
    my $herb = $c->model('DBForager')->get_herb_by_id($record_id);
    
    # Log the herb retrieval attempt
    if ($herb) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_herb',
            "Herb record successfully retrieved for record_id: $record_id");
    } else {
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
        # Log all received parameters for debugging
        my $all_params = $c->request->params;
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'edit_herb',
            "All received parameters: " . join(", ", map { "$_=" . ($all_params->{$_} // 'undef') } sort keys %$all_params));
        
        # Log specific image-related parameters
        my $image_url_param = $c->request->param('image_url') || 'not provided';
        my $image_param = $c->request->param('image') || 'not provided';
        my $image_action_param = $c->request->param('image_action') || 'not provided';
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'edit_herb',
            "Image parameters - image_url: $image_url_param, image: $image_param, image_action: $image_action_param");
        my $form_data = {
            # Naming section
            botanical_name      => $c->request->params->{botanical_name} // '',
            common_names        => $c->request->params->{common_names} // '',
            key_name            => $c->request->params->{key_name} // '',
            parts_used          => $c->request->params->{parts_used} // '',
            sister_plants       => $c->request->params->{sister_plants} // '',
            comments            => $c->request->params->{comments} // '',
            
            # Characteristics section
            ident_character     => $c->request->params->{ident_character} // '',
            stem                => $c->request->params->{stem} // '',
            leaves              => $c->request->params->{leaves} // '',
            flowers             => $c->request->params->{flowers} // '',
            fruit               => $c->request->params->{fruit} // '',
            taste               => $c->request->params->{taste} // '',
            odour               => $c->request->params->{odour} // '',
            root                => $c->request->params->{root} // '',
            # image field will be set by image processing logic below
            
            # Distribution section
            distribution        => $c->request->params->{distribution} // '',
            cultivation         => $c->request->params->{cultivation} // '',
            harvest             => $c->request->params->{harvest} // '',
            
            # Medical section
            therapeutic_action  => $c->request->params->{therapeutic_action} // '',
            medical_uses        => $c->request->params->{medical_uses} // '',
            constituents        => $c->request->params->{constituents} // '',
            solvents            => $c->request->params->{solvents} // '',
            dosage              => $c->request->params->{dosage} // '',
            administration      => $c->request->params->{administration} // '',
            formulas            => $c->request->params->{formulas} // '',
            contra_indications  => $c->request->params->{contra_indications} // '',
            preparation         => $c->request->params->{preparation} // '',
            chinese             => $c->request->params->{chinese} // '',
            vetrinary           => $c->request->params->{vetrinary} // '',
            homiopathic         => $c->request->params->{homiopathic} // '',
            
            # Pollination section
            apis                => $c->request->params->{apis} // 0,
            pollinator          => $c->request->params->{pollinator} // '',
            pollen              => $c->request->params->{pollen} // 0,
            pollennotes         => $c->request->params->{pollennotes} // '',
            nectar              => $c->request->params->{nectar} // 0,
            nectarnotes         => $c->request->params->{nectarnotes} // '',
            
            # Other section
            non_med             => $c->request->params->{non_med} // '',
            Culinary            => $c->request->params->{culinary} // '',
            history             => $c->request->params->{history} // '',
            reference           => $c->request->params->{reference} // '',
            url                 => $c->request->params->{url} // '',
            share               => $c->request->params->{share} // 0,
        };

        # Log form data for debugging
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'edit_herb',
            "Form data received: " . join(", ", map { "$_=" . ($form_data->{$_} // 'undef') } sort keys %$form_data));

        # Handle image processing - NEW CODE VERSION 2.0
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_herb',
            "=== IMAGE PROCESSING STARTED - NEW CODE VERSION 2.0 ===");
        my $new_image_url;
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_herb',
            "Checking admin role...");
        
        if ($c->user_exists && $c->check_user_roles('admin')) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_herb',
                "User has admin role - processing admin image options");
            my $image_action = $c->request->param('image_action') || '';
            my $image_url_param = $c->request->param('image_url') || '';
            my $image_url_simple = $c->request->param('image_url_simple') || '';
            
            # Log all image-related parameters for debugging - UPDATED CODE
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'edit_herb',
                "Admin image parameters - image_action: '$image_action', image_url: '$image_url_param', image_url_simple: '$image_url_simple'");
            
            if ($image_action =~ /^simple:(.*)$/) {
                # Simple image URL entry (direct save to database)
                $new_image_url = $1;
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_herb',
                    "Using simple image URL (direct save): $new_image_url");
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'edit_herb',
                    "Regex matched! Original image_action: '$image_action', Extracted URL: '$new_image_url'");
            } elsif ($image_url_simple && $image_url_simple ne '') {
                # Fallback: if simple URL field has content but no action was set
                $new_image_url = $image_url_simple;
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_herb',
                    "Using simple image URL (fallback): $new_image_url");
            } elsif ($image_action =~ /^url:(.+)$/) {
                # Download image from URL (when Preview was clicked)
                my $source_url = $1;
                $new_image_url = $self->_download_image_from_url($c, $source_url, $record_id);
                if ($new_image_url) {
                    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_herb',
                        "Image downloaded from URL successfully: $new_image_url");
                } else {
                    $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'edit_herb',
                        "Failed to download image from URL: $source_url");
                }
            } elsif ($image_action eq 'upload' && $c->request->upload('image_upload')) {
                # Handle file upload
                my $upload = $c->request->upload('image_upload');
                $new_image_url = $self->_handle_herb_image_upload($c, $upload, $record_id);
                if ($new_image_url) {
                    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_herb',
                        "Image uploaded successfully: $new_image_url");
                } else {
                    $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'edit_herb',
                        "Failed to upload image");
                }
            } elsif ($image_action =~ /^existing:(.+)$/) {
                # Use existing image
                $new_image_url = $1;
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_herb',
                    "Using existing image: $new_image_url");
            } elsif ($image_action eq 'remove') {
                # Remove image (set to empty)
                $new_image_url = '';
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_herb',
                    "Removing image (setting to empty)");
            } elsif ($image_url_param && $image_url_param ne '') {
                # Fallback: Download image from URL even if Preview wasn't clicked
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_herb',
                    "Processing image URL without preview: $image_url_param");
                $new_image_url = $self->_download_image_from_url($c, $image_url_param, $record_id);
                if ($new_image_url) {
                    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_herb',
                        "Image downloaded from URL successfully: $new_image_url");
                } else {
                    $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'edit_herb',
                        "Failed to download image from URL: $image_url_param");
                }
            }
        } else {
            # Handle non-admin users - simple image URL field
            my $image_param = $c->request->param('image') || '';
            if ($image_param && $image_param ne '') {
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_herb',
                    "Non-admin user provided image URL: $image_param");
                # For non-admin users, just save the URL directly (no download)
                $new_image_url = $image_param;
            }
        }
        
        # Set the image field in form data
        if (defined $new_image_url) {
            # New image URL was processed (could be empty string for removal)
            $form_data->{image} = $new_image_url;
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_herb',
                "Final image URL set to: " . ($new_image_url eq '' ? '(empty - removed)' : $new_image_url));
        } else {
            # No new image processed, keep the existing image value
            # BACKUP FIX: Check for image_url_simple parameter as fallback
            my $image_url_simple = $c->request->param('image_url_simple') || '';
            if ($image_url_simple && $image_url_simple ne '') {
                $form_data->{image} = $image_url_simple;
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_herb',
                    "BACKUP FIX: Using image_url_simple parameter: $image_url_simple");
            } else {
                $form_data->{image} = $herb->image // '';
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_herb',
                    "No new image URL processed. Keeping existing image: " . ($form_data->{image} // 'empty'));
            }
        }

        # Attempt to update the herb record and handle success or failure using DBForager model
        my ($status, $error_message) = $c->model('DBForager')->update_herb($c, $record_id, $form_data);

        if ($status) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_herb',
                "Herb updated successfully for record_id: $record_id.");
            
            # Reload the herb from database to show updated values
            my $updated_herb = $c->model('DBForager')->get_herb_by_id($record_id);
            
            $c->stash(
                success_msg => "Herb details updated successfully.",
                herb        => $updated_herb,
                mode        => 'view',
                edit_mode   => 0, # Switch back to view mode after successful update
                template    => 'ENCY/HerbView.tt',
            );
            return; # Render the updated herb view
        } else {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'edit_herb',
                "Failed to update herb: $error_message.");
            # Load existing images for the error case
            my $existing_images = [];
            if ($c->user_exists && $c->check_user_roles('admin')) {
                $existing_images = $self->_get_existing_herb_images($c);
            }
            
            # Convert herb object to hash and combine with form data
            my $herb_data = {};
            if ($herb) {
                $herb_data = { $herb->get_columns };
            }
            my $combined_data = { %$herb_data, %$form_data };
            
            $c->stash(
                error_msg => "Failed to update herb: $error_message",
                herb      => $combined_data, # Combine original and submitted data for display
                mode      => 'edit',
                edit_mode => 1, # Stay in edit mode for correction
                existing_images => $existing_images,
                template  => 'ENCY/HerbView.tt',
            );
            return; # Re-render the form with an error message
        }
    }

    # Load existing images for the dropdown if user is admin
    my $existing_images = [];
    if ($c->user_exists && $c->check_user_roles('admin')) {
        $existing_images = $self->_get_existing_herb_images($c);
    }

    # Pass herb object directly to template
    $c->stash(
        herb            => $herb,
        mode            => 'edit',
        edit_mode       => 1, # Enable edit mode
        existing_images => $existing_images,
        template        => 'ENCY/HerbView.tt',
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
    
    # Debug: log the image field value
    if ($herb) {
        my $image_value = $herb->image // 'undef';
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'herb_detail', 
            "Herb found - botanical_name: " . ($herb->botanical_name // 'undef') . ", image: $image_value");
    }
   if ($herb) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'herb_detail', "Herb details fetched successfully for ID: $id");
    } else {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'herb_detail', "Herb not found for ID: $id");
    }
    $c->session->{record_id} = $id;  # Store the id in the session

    # Load existing images for admin users
    my $existing_images = [];
    if ($c->user_exists && $c->check_user_roles('admin')) {
        $existing_images = $self->_get_existing_herb_images($c);
    }

    # Try passing herb object directly first, then convert to hash if needed
    my $herb_data = {};
    if ($herb) {
        # Try direct object access first
        $c->stash(
            herb => $herb,
            mode => 'view',
            edit_mode => 0,
            existing_images => $existing_images,
            template => 'ENCY/HerbView.tt');
        return;
    } else {
        # If no herb found, set empty data
        $c->stash(
            herb => {},
            mode => 'view',
            edit_mode => 0,
            existing_images => $existing_images,
            template => 'ENCY/HerbView.tt');
    }
}

sub delete_herb :Path('/ENCY/delete_herb') :Args(1) {
    my ( $self, $c, $id ) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'delete_herb',
        "Delete herb request received for ID: $id");
    
    # Check if user has admin privileges
    unless ($c->user_exists && $c->check_user_roles('admin')) {
        my $username = ($c->user_exists && $c->user) ? $c->user->username : ($c->session->{username} || 'Guest');
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'delete_herb',
            "Unauthorized delete attempt by user: $username");
        $c->response->status(403);
        $c->stash(
            error_msg => "You do not have permission to delete herbs.",
            template => 'error.tt'
        );
        return;
    }
    
    # Validate the ID
    unless (defined $id && $id =~ /^\d+$/) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'delete_herb',
            "Invalid herb ID provided: " . (defined $id ? $id : 'undefined'));
        $c->response->status(400);
        $c->stash(
            error_msg => "Invalid herb ID provided.",
            template => 'error.tt'
        );
        return;
    }
    
    # Get herb details before deletion for confirmation
    my $herb = $c->model('DBForager')->get_herb_by_id($id);
    unless ($herb) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'delete_herb',
            "Herb not found for deletion with ID: $id");
        $c->response->status(404);
        $c->stash(
            error_msg => "Herb not found.",
            template => 'error.tt'
        );
        return;
    }
    
    my $botanical_name = $herb->botanical_name // 'Unknown';
    
    # Handle POST request (actual deletion)
    if ($c->request->method eq 'POST') {
        my $confirm = $c->request->param('confirm_delete') || '';
        
        if ($confirm eq 'yes') {
            # Perform the deletion
            my ($status, $message) = $c->model('DBForager')->delete_herb($c, $id);
            
            if ($status) {
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'delete_herb',
                    "Herb successfully deleted: $botanical_name (ID: $id)");
                
                # Redirect to herb list or main page
                $c->response->redirect($c->uri_for('/ENCY/BotanicalNameView'));
                return;
            } else {
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'delete_herb',
                    "Failed to delete herb: $message");
                $c->stash(
                    error_message => "Failed to delete herb: $message",
                    herb => $herb,
                    template => 'ENCY/delete_herb_confirm.tt'
                );
                return;
            }
        } else {
            # User cancelled deletion
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'delete_herb',
                "Herb deletion cancelled by user for ID: $id");
            $c->response->redirect($c->uri_for('/ENCY/herb_detail/' . $id));
            return;
        }
    }
    
    # Handle GET request (show confirmation page)
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'delete_herb',
        "Showing delete confirmation for herb: $botanical_name (ID: $id)");
    
    $c->stash(
        herb => $herb,
        template => 'ENCY/delete_herb_confirm.tt'
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

# Private method to handle herb image uploads
sub _handle_herb_image_upload {
    my ($self, $c, $upload, $record_id) = @_;
    
    # Validate upload
    unless ($upload && $upload->size > 0) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_handle_herb_image_upload',
            "No valid upload provided");
        return undef;
    }
    
    # Get original filename and validate file type
    my $original_filename = $upload->filename;
    my ($file_extension) = $original_filename =~ /\.([^.]+)$/;
    
    unless ($file_extension && $file_extension =~ /^(jpg|jpeg|png|gif)$/i) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_handle_herb_image_upload',
            "Invalid file type: $file_extension. Only JPG, PNG, and GIF are allowed.");
        return undef;
    }
    
    # Check file size (5MB limit)
    my $max_size = 5 * 1024 * 1024; # 5MB
    if ($upload->size > $max_size) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_handle_herb_image_upload',
            "File too large: " . $upload->size . " bytes. Maximum allowed: $max_size bytes.");
        return undef;
    }
    
    # Create unique filename using record_id and timestamp
    my $timestamp = time();
    my $new_filename = "herb_${record_id}_${timestamp}.${file_extension}";
    
    # Define upload directory and ensure it exists
    my $upload_dir = $c->path_to('root', 'static', 'uploads', 'herbs');
    unless (-d $upload_dir) {
        eval { 
            require File::Path;
            File::Path::make_path($upload_dir);
        };
        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_handle_herb_image_upload',
                "Failed to create upload directory: $@");
            return undef;
        }
    }
    
    # Full path for the uploaded file
    my $file_path = $upload_dir->file($new_filename);
    
    # Copy the uploaded file
    eval {
        $upload->copy_to($file_path);
    };
    
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_handle_herb_image_upload',
            "Failed to save uploaded file: $@");
        return undef;
    }
    
    # Return the web-accessible URL
    my $image_url = $c->uri_for('/static/uploads/herbs/' . $new_filename);
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_handle_herb_image_upload',
        "Successfully uploaded image: $new_filename");
    
    return $image_url;
}

# Method to download image from URL and save locally
sub _download_image_from_url {
    my ($self, $c, $source_url, $record_id) = @_;
    
    # Load required modules
    eval {
        require LWP::UserAgent;
        require HTTP::Request;
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_download_image_from_url',
            "Required modules not available: $@");
        return undef;
    }
    
    # Create user agent
    my $ua = LWP::UserAgent->new(
        timeout => 30,
        agent => 'Comserv/1.0'
    );
    
    # Make request
    my $response = $ua->get($source_url);
    
    unless ($response->is_success) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_download_image_from_url',
            "Failed to download image: " . $response->status_line);
        return undef;
    }
    
    # Get content type and determine file extension
    my $content_type = $response->header('Content-Type') || '';
    my $file_extension;
    
    if ($content_type =~ /image\/jpeg/i) {
        $file_extension = 'jpg';
    } elsif ($content_type =~ /image\/png/i) {
        $file_extension = 'png';
    } elsif ($content_type =~ /image\/gif/i) {
        $file_extension = 'gif';
    } else {
        # Try to guess from URL
        if ($source_url =~ /\.([^.?]+)(?:\?|$)/i) {
            my $ext = lc($1);
            if ($ext =~ /^(jpg|jpeg|png|gif)$/) {
                $file_extension = $ext eq 'jpeg' ? 'jpg' : $ext;
            }
        }
        
        unless ($file_extension) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_download_image_from_url',
                "Could not determine image type from content-type: $content_type");
            return undef;
        }
    }
    
    # Check file size (5MB limit)
    my $content_length = length($response->content);
    my $max_size = 5 * 1024 * 1024; # 5MB
    if ($content_length > $max_size) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_download_image_from_url',
            "Downloaded image too large: $content_length bytes. Maximum allowed: $max_size bytes.");
        return undef;
    }
    
    # Create unique filename
    my $timestamp = time();
    my $filename = "herb_${record_id}_downloaded_${timestamp}.${file_extension}";
    
    # Define upload directory and ensure it exists
    my $upload_dir = $c->path_to('root', 'static', 'uploads', 'herbs');
    unless (-d $upload_dir) {
        eval { 
            require File::Path;
            File::Path::make_path($upload_dir);
        };
        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_download_image_from_url',
                "Failed to create upload directory: $@");
            return undef;
        }
    }
    
    # Save the file
    my $file_path = $upload_dir->file($filename);
    eval {
        open my $fh, '>', $file_path or die "Cannot open file: $!";
        binmode $fh;
        print $fh $response->content;
        close $fh;
    };
    
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_download_image_from_url',
            "Failed to save downloaded image: $@");
        return undef;
    }
    
    # Return the web-accessible URL
    my $image_url = $c->uri_for('/static/uploads/herbs/' . $filename);
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_download_image_from_url',
        "Successfully downloaded and saved image: $filename");
    
    return $image_url;
}

# Method to get list of existing herb images
sub _get_existing_herb_images {
    my ($self, $c) = @_;
    
    my $upload_dir = $c->path_to('root', 'static', 'uploads', 'herbs');
    my @images = ();
    
    if (-d $upload_dir) {
        eval {
            opendir(my $dh, $upload_dir) or die "Cannot open directory: $!";
            my @files = grep { /\.(jpg|jpeg|png|gif)$/i && -f "$upload_dir/$_" } readdir($dh);
            closedir($dh);
            
            foreach my $file (sort @files) {
                push @images, {
                    filename => $file,
                    url => $c->uri_for('/static/uploads/herbs/' . $file)
                };
            }
        };
        
        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_get_existing_herb_images',
                "Error reading upload directory: $@");
        }
    }
    
    return \@images;
}

__PACKAGE__->meta->make_immutable;

1;