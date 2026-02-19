package Comserv::Controller::WorkShop;
use Moose;
use namespace::autoclean;
use Data::FormValidator;
use Comserv::Util::AdminAuth;
BEGIN { extends 'Catalyst::Controller'; }

# In Workshop Controller
sub index :Path :Args(0) {
    my ( $self, $c ) = @_;

    my ($workshops, $error);
    ($workshops, $error) = $c->model('WorkShop')->get_active_workshops($c);
    
    # Apply client-side filters based on query parameters
    my $site_filter = $c->request->params->{site_filter} || '';
    my $status_filter = $c->request->params->{status_filter} || '';
    
    if ($site_filter || $status_filter) {
        my @filtered_workshops;
        for my $workshop (@$workshops) {
            my $include = 1;
            
            # Apply site filter
            if ($site_filter eq 'public') {
                $include = 0 unless $workshop->share eq 'public';
            } elsif ($site_filter eq 'my_site') {
                my $sitename = $c->session->{SiteName};
                $include = 0 unless $workshop->sitename eq $sitename;
            }
            
            # Apply status filter
            if ($status_filter && $include) {
                $include = 0 unless $workshop->status eq $status_filter;
            }
            
            push @filtered_workshops, $workshop if $include;
        }
        $workshops = \@filtered_workshops;
    }

    my @workshops_hash;
    for my $workshop (@$workshops) {
        my @file = $c->model('DBEncy::File')->search({ workshop_id => $workshop->id });

        my %workshop_hash = $workshop->get_columns;
        $workshop_hash{file} = \@file;
        
        if ($workshop->creator) {
            $workshop_hash{creator} = {
                id => $workshop->creator->id,
                username => $workshop->creator->username,
                first_name => $workshop->creator->first_name,
                last_name => $workshop->creator->last_name,
            };
        }

        push @workshops_hash, \%workshop_hash;
    }

    my ($past_workshops, $past_error);
    ($past_workshops, $past_error) = $c->model('WorkShop')->get_past_workshops($c);
    
    # Apply filters to past workshops too
    if ($site_filter || $status_filter) {
        my @filtered_past;
        for my $workshop (@$past_workshops) {
            my $include = 1;
            
            if ($site_filter eq 'public') {
                $include = 0 unless $workshop->share eq 'public';
            } elsif ($site_filter eq 'my_site') {
                my $sitename = $c->session->{SiteName};
                $include = 0 unless $workshop->sitename eq $sitename;
            }
            
            if ($status_filter && $include) {
                $include = 0 unless $workshop->status eq $status_filter;
            }
            
            push @filtered_past, $workshop if $include;
        }
        $past_workshops = \@filtered_past;
    }

    my @past_workshops_hash;
    for my $workshop (@$past_workshops) {
        my @file = $c->model('DBEncy::File')->search({ workshop_id => $workshop->id });

        my %workshop_hash = $workshop->get_columns;
        $workshop_hash{file} = \@file;
        
        if ($workshop->creator) {
            $workshop_hash{creator} = {
                id => $workshop->creator->id,
                username => $workshop->creator->username,
                first_name => $workshop->creator->first_name,
                last_name => $workshop->creator->last_name,
            };
        }

        push @past_workshops_hash, \%workshop_hash;
    }

    my $admin_auth = Comserv::Util::AdminAuth->new();
    my $is_admin = $admin_auth->check_admin_access($c, 'workshop_index');

    $c->stash(
        workshops => \@workshops_hash,
        past_workshops => \@past_workshops_hash,
        error => $error,
        past_error => $past_error,
        sitename => $c->session->{SiteName},
        is_admin => $is_admin,
        template => 'WorkShops/Workshops.tt',
    );
    if ($@) {
    $c->stash(error => "Error fetching active workshops: $@");
}
}
sub dashboard :Local {
    my ( $self, $c ) = @_;

    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->check_admin_access($c, 'workshop_dashboard')) {
        $c->flash->{error_msg} = "Access denied. Admin access required.";
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }

    my $user_id = $c->session->{user_id};
    my $sitename = $c->session->{SiteName};
    my $schema = $c->model('DBEncy');

    my $admin_type = $admin_auth->get_admin_type($c);
    my $is_csc_admin = ($admin_type eq 'csc' || $admin_type eq 'special');

    $c->log->debug("Dashboard: user_id=$user_id, sitename=$sitename, admin_type=$admin_type, is_csc_admin=$is_csc_admin");

    my $search_filter;

    if ($is_csc_admin) {
        $search_filter = {};
        $c->log->debug("Dashboard: CSC admin - showing ALL workshops");
    } else {
        $search_filter = {
            -or => [
                { created_by => $user_id },
            ]
        };
        if ($sitename) {
            push @{$search_filter->{-or}}, { sitename => $sitename, created_by => undef };
        }
        $c->log->debug("Dashboard: Regular admin filter applied");
    }

    my @my_workshops = $schema->resultset('WorkShop')->search(
        $search_filter,
        { 
            order_by => { -desc => 'created_at' },
            prefetch => 'creator'
        }
    )->all;

    $c->log->debug("Dashboard: Found " . scalar(@my_workshops) . " workshops from main search");

    my @workshop_leader_ids = $schema->resultset('WorkshopRole')->search(
        {
            user_id => $user_id,
            role => 'workshop_leader'
        }
    )->get_column('workshop_id')->all;

    if (@workshop_leader_ids) {
        my @leader_workshops = $schema->resultset('WorkShop')->search(
            {
                id => { -in => \@workshop_leader_ids },
                created_by => { '!=' => $user_id }
            },
            { prefetch => 'creator' }
        )->all;
        push @my_workshops, @leader_workshops;
    }

    my @workshops_with_stats;
    for my $workshop (@my_workshops) {
        my $participant_count = $workshop->participants->search({ status => 'registered' })->count;
        my $email_count = $workshop->emails->count;
        my $file_count = $workshop->files->count;

        push @workshops_with_stats, {
            workshop => $workshop,
            participant_count => $participant_count,
            email_count => $email_count,
            file_count => $file_count,
        };
    }

    $c->stash(
        workshops => \@workshops_with_stats,
        template => 'WorkShops/Dashboard.tt',
    );
}

sub add :Local {
    my ( $self, $c ) = @_;

    # Set the TT template to use
    $c->stash->{template} = 'WorkShops/AddWorkshop.tt';
}
sub addworkshop :Local {
    my ( $self, $c ) = @_;

    # Retrieve the form data from the request
    my $params = $c->request->parameters;

    # Validate the form data
    my ($is_valid, $errors) = validate_form_data($params);
    if (!$is_valid) {
        # If validation fails, return to the form with errors
        $c->stash->{error_msg} = 'Invalid form data: ' . join(', ', map { "$_: $errors->{$_}" } keys %$errors);
        $c->stash->{form_data} = $params; # Add the form data to the stash
        $c->stash->{template} = 'WorkShops/AddWorkshop.tt';
        return;
    }

    # Get a DBIx::Class::Schema object
    my $schema = $c->model('DBEncy');

    # Get a DBIx::Class::ResultSet object
    my $rs = $schema->resultset('WorkShop');

    # Get the start_time from the form data
    my $start_time_str = $params->{time};

    # Create a DateTime::Format::Strptime object for parsing the time strings
    my $strp = DateTime::Format::Strptime->new(
        pattern   => '%H:%M',
        time_zone => 'local',
    );

    # Convert the start_time string to a DateTime object
    my $time = $strp->parse_datetime($start_time_str);

    # Get creator's site_id from session
    my $creator_sitename = $c->session->{SiteName} || $params->{sitename};
    my $creator_site = $schema->resultset('Site')->search({ name => $creator_sitename })->first;
    my $creator_site_id = $creator_site ? $creator_site->id : undef;
    
    # Try to create a new workshop record
    my $workshop;
    eval {
        $workshop = $rs->create({
            sitename         => $creator_sitename,
            title            => $params->{title},
            description      => $params->{description},
            date             => $params->{dateOfWorkshop},
            location         => $params->{location},
            instructor       => $params->{instructor},
            max_participants => $params->{maxMinAttendees},
            share            => $params->{share} || 'private',
            end_time         => $params->{end_time},
            time             => $time,
            created_by       => $c->session->{user_id},
            site_id          => $creator_site_id,
        });
        
        # Create site_workshop records based on share setting
        if ($workshop) {
            if ($params->{share} && $params->{share} eq 'public') {
                # Create site_workshop records for all sites
                my @all_sites = $schema->resultset('Site')->all;
                for my $site (@all_sites) {
                    $schema->resultset('SiteWorkshop')->create({
                        site_id => $site->id,
                        workshop_id => $workshop->id,
                    });
                }
            } else {
                # Create site_workshop record only for creator's site
                if ($creator_site_id) {
                    $schema->resultset('SiteWorkshop')->create({
                        site_id => $creator_site_id,
                        workshop_id => $workshop->id,
                    });
                }
            }
        }
    };

    if ($@) {
        # If creation fails, return to the form with an error message
        $c->stash->{error_msg} = 'Failed to create workshop: ' . $@;
        $c->stash->{form_data} = $params; # Add the form data to the stash
        $c->stash->{template} = 'WorkShops/AddWorkshop.tt';
        return;
    }

    # Redirect the user to the index action on success
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

sub details :Path('/workshop/details') :Args(0) {
    my ($self, $c) = @_;

    # Retrieve the ID from query parameters
    my $id = $c->request->params->{id};
    
    unless ($id) {
        $c->flash->{error_msg} = 'Workshop ID is required';
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }

    # Get a DBIx::Class::Schema object
    my $schema = $c->model('DBEncy');

    # Get a DBIx::Class::ResultSet object for the 'WorkShop' table
    my $rs = $schema->resultset('WorkShop');

    # Try to find the workshop by its ID
    my $workshop;
    eval {
        $workshop = $rs->find($id);
    };

    if ($@ || !$workshop) {
        $c->log->error("Failed to find workshop with ID $id: " . ($@ || 'Workshop not found'));
        $c->flash->{error_msg} = 'Failed to find workshop: ' . ($@ || 'Workshop not found');
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }

    # Workshop details are viewable by all users
    # Edit access is restricted to admins/leaders via separate authorization checks

    # Assuming $workshop->date is a DateTime object
    my $formatted_date = $workshop->date->strftime('%Y-%m-%d');

    # Check if user is registered for this workshop (including past attendees)
    my $is_user_registered = 0;
    if ($c->user_exists) {
        my $user_id = $c->session->{user_id};
        my $participant = $schema->resultset('Participant')->search({
            workshop_id => $id,
            user_id => $user_id,
            status => { -in => ['registered', 'waitlist', 'attended'] }
        })->first;
        $is_user_registered = 1 if $participant;
    }

    # Get workshop files
    my @workshop_files = $schema->resultset('File')->search(
        { workshop_id => $id },
        { order_by => 'created_at DESC' }
    )->all;

    # Get workshop content
    my @workshop_content = $schema->resultset('WorkshopContent')->search(
        { workshop_id => $id },
        { order_by => 'sort_order ASC' }
    )->all;

    # Pass the workshop to the view
    $c->stash(
        workshop => $workshop,
        formatted_date => $formatted_date,
        is_user_registered => $is_user_registered,
        workshop_files => \@workshop_files,
        workshop_content => \@workshop_content,
        template => 'WorkShops/Details.tt',
    );
}


use DateTime::Format::Strptime;

sub edit :Path('/workshop/edit') :Args(1) {
    my ($self, $c, $id) = @_;

    # Find the workshop in the database
    my $workshop = $c->model('DBEncy::WorkShop')->find($id);

    unless ($workshop) {
        $c->flash->{error_msg} = 'Workshop not found.';
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }

    # Authorization check using helper method
    unless ($self->_can_edit_workshop($c, $workshop)) {
        $c->flash->{error_msg} = 'Access denied. You do not have permission to edit this workshop.';
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }

    # For GET requests, display the edit form
    if ($c->request->method eq 'GET') {
        # Format the date to 'YYYY-MM-DD'
        my $formatted_date = $workshop->date->strftime('%Y-%m-%d');

        $c->stash(
            workshop => $workshop,
            formatted_date => $formatted_date,
            template => 'WorkShops/Edit.tt'
        );
        return;
    }

    # Handle POST request for updates
    if ($c->request->method eq 'POST') {
        my $params = $c->request->body_parameters;
        my $old_share = $workshop->share;
        my $new_share = $params->{share};
        
        eval {
            $workshop->update({
                title            => $params->{title},
                description      => $params->{description},
                date             => $params->{date},
                time             => $params->{time},
                end_time         => $params->{end_time},
                location         => $params->{location},
                instructor       => $params->{instructor},
                max_participants => $params->{max_participants},
                share            => $new_share,
            });
            
            # Update site_workshop records if share setting changed
            if ($old_share ne $new_share) {
                my $schema = $c->model('DBEncy');
                
                # Delete existing site_workshop records
                $schema->resultset('SiteWorkshop')->search({
                    workshop_id => $workshop->id
                })->delete;
                
                # Create new records based on new share setting
                if ($new_share eq 'public') {
                    # Create records for all sites
                    my @all_sites = $schema->resultset('Site')->all;
                    for my $site (@all_sites) {
                        $schema->resultset('SiteWorkshop')->create({
                            site_id => $site->id,
                            workshop_id => $workshop->id,
                        });
                    }
                } else {
                    # Create record only for workshop's site
                    if ($workshop->site_id) {
                        $schema->resultset('SiteWorkshop')->create({
                            site_id => $workshop->site_id,
                            workshop_id => $workshop->id,
                        });
                    }
                }
            }
        };

        if ($@) {
            $c->stash->{error_msg} = 'Failed to update workshop: ' . $@;
        } else {
            $c->flash->{success_msg} = 'Workshop updated successfully.';
            $c->res->redirect($c->uri_for($self->action_for('index')));
            return;
        }
    }
}

sub _check_workshop_access {
    my ($self, $c, $workshop, $required_level) = @_;
    
    $required_level ||= 'view';
    
    if ($required_level eq 'view') {
        # Public workshops are visible to everyone (even non-logged-in users)
        if ($workshop->share eq 'public') {
            return 1;
        }
    }
    
    # For non-view access or private workshops, user must be logged in
    return 0 unless $c->user_exists;
    
    my $user_id = $c->session->{user_id};
    my $sitename = $c->session->{SiteName};
    my $roles = $c->session->{roles} || [];
    
    my $admin_auth = Comserv::Util::AdminAuth->new();
    my $admin_type = $admin_auth->get_admin_type($c);
    
    # CSC admin has god-level access
    if ($admin_type eq 'csc' || $admin_type eq 'special') {
        return 1;
    }
    
    if ($required_level eq 'view') {
        # Check if user's site has access via site_workshop table
        if ($sitename) {
            my $schema = $c->model('DBEncy');
            my $site = $schema->resultset('Site')->search({ name => $sitename })->first;
            if ($site) {
                my $site_access = $schema->resultset('SiteWorkshop')->search({
                    site_id => $site->id,
                    workshop_id => $workshop->id
                })->count > 0;
                
                return 1 if $site_access;
            }
        }
        
        # Check if user is a registered participant
        my $is_participant = $c->model('DBEncy::Participant')->search({
            workshop_id => $workshop->id,
            user_id => $user_id,
            status => { -in => ['registered', 'attended'] }
        })->count > 0;
        
        return 1 if $is_participant;
    }
    
    if ($required_level eq 'leader' || $required_level eq 'edit') {
        if ($admin_type eq 'standard' && $sitename && $sitename eq $workshop->sitename) {
            return 1;
        }
        
        if ($self->_is_workshop_leader($c, $workshop)) {
            return 1;
        }
    }
    
    return 0;
}

sub _is_workshop_leader {
    my ($self, $c, $workshop) = @_;
    
    return 0 unless $c->user_exists;
    
    my $user_id = $c->session->{user_id};
    
    if ($workshop->created_by && $workshop->created_by == $user_id) {
        return 1;
    }
    
    my $has_leader_role = $c->model('DBEncy::WorkshopRole')->search({
        workshop_id => $workshop->id,
        user_id => $user_id,
        role => 'workshop_leader'
    })->count > 0;
    
    return $has_leader_role;
}

sub _can_edit_workshop {
    my ($self, $c, $workshop) = @_;
    
    return $self->_check_workshop_access($c, $workshop, 'edit');
}

sub publish :Local :Args(1) {
    my ($self, $c, $id) = @_;
    
    my $workshop = $c->model('DBEncy::WorkShop')->find($id);
    
    unless ($workshop) {
        $c->flash->{error_msg} = 'Workshop not found.';
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }
    
    unless ($self->_can_edit_workshop($c, $workshop)) {
        $c->flash->{error_msg} = 'Access denied. You do not have permission to publish this workshop.';
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }
    
    eval {
        $workshop->update({ status => 'published' });
    };
    
    if ($@) {
        $c->flash->{error_msg} = 'Failed to publish workshop: ' . $@;
    } else {
        $c->flash->{success_msg} = 'Workshop published successfully.';
    }
    
    $c->response->redirect($c->uri_for($self->action_for('details'), { id => $id }));
}

sub close_registration :Local :Args(1) {
    my ($self, $c, $id) = @_;
    
    my $workshop = $c->model('DBEncy::WorkShop')->find($id);
    
    unless ($workshop) {
        $c->flash->{error_msg} = 'Workshop not found.';
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }
    
    unless ($self->_can_edit_workshop($c, $workshop)) {
        $c->flash->{error_msg} = 'Access denied. You do not have permission to close registration for this workshop.';
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }
    
    eval {
        $workshop->update({ status => 'registration_closed' });
    };
    
    if ($@) {
        $c->flash->{error_msg} = 'Failed to close registration: ' . $@;
    } else {
        $c->flash->{success_msg} = 'Workshop registration closed successfully.';
    }
    
    $c->response->redirect($c->uri_for($self->action_for('details'), { id => $id }));
}

sub start :Local :Args(1) {
    my ($self, $c, $id) = @_;
    
    my $workshop = $c->model('DBEncy::WorkShop')->find($id);
    
    unless ($workshop) {
        $c->flash->{error_msg} = 'Workshop not found.';
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }
    
    unless ($self->_can_edit_workshop($c, $workshop)) {
        $c->flash->{error_msg} = 'Access denied. You do not have permission to start this workshop.';
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }
    
    eval {
        $workshop->update({ status => 'in_progress' });
    };
    
    if ($@) {
        $c->flash->{error_msg} = 'Failed to start workshop: ' . $@;
    } else {
        $c->flash->{success_msg} = 'Workshop started successfully.';
    }
    
    $c->response->redirect($c->uri_for($self->action_for('details'), { id => $id }));
}

sub complete :Local :Args(1) {
    my ($self, $c, $id) = @_;
    
    my $workshop = $c->model('DBEncy::WorkShop')->find($id);
    
    unless ($workshop) {
        $c->flash->{error_msg} = 'Workshop not found.';
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }
    
    unless ($self->_can_edit_workshop($c, $workshop)) {
        $c->flash->{error_msg} = 'Access denied. You do not have permission to complete this workshop.';
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }
    
    eval {
        $workshop->update({ status => 'completed' });
    };
    
    if ($@) {
        $c->flash->{error_msg} = 'Failed to complete workshop: ' . $@;
    } else {
        $c->flash->{success_msg} = 'Workshop marked as completed.';
    }
    
    $c->response->redirect($c->uri_for($self->action_for('details'), { id => $id }));
}

sub cancel :Local :Args(1) {
    my ($self, $c, $id) = @_;
    
    my $workshop = $c->model('DBEncy::WorkShop')->find($id);
    
    unless ($workshop) {
        $c->flash->{error_msg} = 'Workshop not found.';
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }
    
    unless ($self->_can_edit_workshop($c, $workshop)) {
        $c->flash->{error_msg} = 'Access denied. You do not have permission to cancel this workshop.';
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }
    
    eval {
        $workshop->update({ status => 'cancelled' });
    };
    
    if ($@) {
        $c->flash->{error_msg} = 'Failed to cancel workshop: ' . $@;
    } else {
        $c->flash->{success_msg} = 'Workshop cancelled successfully.';
    }
    
    $c->response->redirect($c->uri_for($self->action_for('details'), { id => $id }));
}

sub register :Local :Args(1) {
    my ($self, $c, $id) = @_;
    
    unless ($c->user_exists) {
        $c->flash->{error_msg} = 'You must be logged in to register for a workshop.';
        $c->response->redirect($c->uri_for($self->action_for('details'), { id => $id }));
        return;
    }
    
    my $workshop = $c->model('DBEncy::WorkShop')->find($id);
    
    unless ($workshop) {
        $c->flash->{error_msg} = 'Workshop not found.';
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }
    
    unless ($workshop->status eq 'published') {
        $c->flash->{error_msg} = 'This workshop is not open for registration.';
        $c->response->redirect($c->uri_for($self->action_for('details'), { id => $id }));
        return;
    }
    
    my $user_id = $c->session->{user_id};
    my $user = $c->model('DBEncy::User')->find($user_id);
    
    my $existing = $c->model('DBEncy::Participant')->search({
        workshop_id => $id,
        user_id => $user_id,
        status => { -in => ['registered', 'waitlist'] }
    })->first;
    
    if ($existing) {
        $c->flash->{error_msg} = 'You are already registered for this workshop.';
        $c->response->redirect($c->uri_for($self->action_for('details'), { id => $id }));
        return;
    }
    
    my $email = $user ? $user->email : $c->session->{email};
    my $sitename = $c->session->{SiteName};
    
    my $participant_status;
    if ($workshop->is_full) {
        $participant_status = 'waitlist';
    } else {
        $participant_status = 'registered';
    }
    
    my $participant;
    eval {
        $participant = $c->model('DBEncy::Participant')->create({
            workshop_id => $id,
            user_id => $user_id,
            email => $email,
            site_affiliation => $sitename,
            status => $participant_status,
        });
    };
    
    if ($@) {
        $c->flash->{error_msg} = 'Failed to register for workshop: ' . $@;
        $c->response->redirect($c->uri_for($self->action_for('details'), { id => $id }));
        return;
    }
    
    if ($email && $email =~ /\@/) {
        eval {
            my $from_address = $c->config->{mail_from} || 'noreply@computersystemconsulting.ca';
            my $reply_to = $c->config->{mail_replyto} || 'helpdesk@computersystemconsulting.ca';
            
            my $workshop_url = $c->uri_for($self->action_for('details'), { id => $id });
            my $base_uri = $c->req->base;
            my $full_url = $base_uri . $workshop_url;
            
            my $formatted_date = $workshop->date ? $workshop->date->strftime('%Y-%m-%d') : 'TBD';
            my $formatted_time = $workshop->time ? $workshop->time->strftime('%H:%M') : 'TBD';
            my $formatted_end_time = $workshop->end_time || '';
            
            my $user_name = '';
            if ($user) {
                $user_name = $user->first_name || $user->username || '';
                if ($user->last_name) {
                    $user_name .= ' ' . $user->last_name;
                }
            }
            
            $c->stash->{email} = {
                to       => $email,
                from     => $from_address,
                reply_to => $reply_to,
                subject  => 'Workshop Registration Confirmation - ' . $workshop->title,
                template => 'email/workshop/registration_confirmation.tt',
                template_vars => {
                    name => $user_name,
                    workshop_title => $workshop->title,
                    workshop_instructor => $workshop->instructor,
                    workshop_date => $formatted_date,
                    workshop_time => $formatted_time,
                    workshop_end_time => $formatted_end_time,
                    workshop_location => $workshop->location,
                    workshop_url => $full_url,
                    status => $participant_status,
                },
            };
            
            $c->forward($c->view('Email::Template'));
        };
        
        if ($@) {
            $c->log->warn("Failed to send registration confirmation email: $@");
        }
    }
    
    if ($participant_status eq 'registered') {
        $c->flash->{success_msg} = 'You have successfully registered for this workshop. A confirmation email has been sent to your email address.';
    } else {
        $c->flash->{success_msg} = 'You have been added to the waitlist for this workshop. You will be notified if a spot becomes available.';
    }
    
    $c->response->redirect($c->uri_for($self->action_for('details'), { id => $id }));
}

sub unregister :Local :Args(1) {
    my ($self, $c, $id) = @_;
    
    unless ($c->user_exists) {
        $c->flash->{error_msg} = 'You must be logged in to unregister from a workshop.';
        $c->response->redirect($c->uri_for($self->action_for('details'), { id => $id }));
        return;
    }
    
    my $workshop = $c->model('DBEncy::WorkShop')->find($id);
    
    unless ($workshop) {
        $c->flash->{error_msg} = 'Workshop not found.';
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }
    
    my $user_id = $c->session->{user_id};
    
    my $participant = $c->model('DBEncy::Participant')->search({
        workshop_id => $id,
        user_id => $user_id,
        status => { -in => ['registered', 'waitlist'] }
    })->first;
    
    unless ($participant) {
        $c->flash->{error_msg} = 'You are not registered for this workshop.';
        $c->response->redirect($c->uri_for($self->action_for('details'), { id => $id }));
        return;
    }
    
    eval {
        $participant->update({ status => 'cancelled' });
    };
    
    if ($@) {
        $c->flash->{error_msg} = 'Failed to cancel registration: ' . $@;
    } else {
        $c->flash->{success_msg} = 'Your registration has been cancelled.';
    }
    
    $c->response->redirect($c->uri_for($self->action_for('details'), { id => $id }));
}

sub participants :Local :Args(1) {
    my ($self, $c, $id) = @_;
    
    my $workshop = $c->model('DBEncy::WorkShop')->find($id);
    
    unless ($workshop) {
        $c->flash->{error_msg} = 'Workshop not found.';
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }
    
    unless ($self->_check_workshop_access($c, $workshop, 'leader')) {
        $c->flash->{error_msg} = 'Access denied. You do not have permission to view participants for this workshop.';
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }
    
    my @registered = $c->model('DBEncy::Participant')->search(
        {
            workshop_id => $id,
            status => 'registered'
        },
        {
            order_by => { -asc => 'registered_at' },
            prefetch => 'user'
        }
    )->all;
    
    my @waitlist = $c->model('DBEncy::Participant')->search(
        {
            workshop_id => $id,
            status => 'waitlist'
        },
        {
            order_by => { -asc => 'registered_at' },
            prefetch => 'user'
        }
    )->all;
    
    $c->stash(
        workshop => $workshop,
        registered_participants => \@registered,
        waitlist_participants => \@waitlist,
        template => 'WorkShops/Participants.tt',
    );
}

sub add_participant :Local :Args(1) {
    my ($self, $c, $id) = @_;
    
    my $workshop = $c->model('DBEncy::WorkShop')->find($id);
    
    unless ($workshop) {
        $c->flash->{error_msg} = 'Workshop not found.';
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }
    
    unless ($self->_check_workshop_access($c, $workshop, 'leader')) {
        $c->flash->{error_msg} = 'Access denied. You do not have permission to add participants to this workshop.';
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }
    
    if ($c->request->method eq 'GET') {
        $c->stash(
            workshop => $workshop,
            template => 'WorkShops/AddParticipant.tt',
        );
        return;
    }
    
    my $params = $c->request->body_parameters;
    my $name = $params->{name};
    my $email = $params->{email};
    my $site_affiliation = $params->{site_affiliation};
    
    unless ($name && $email) {
        $c->stash->{error_msg} = 'Name and email are required.';
        $c->stash(
            workshop => $workshop,
            template => 'WorkShops/AddParticipant.tt',
        );
        return;
    }
    
    unless ($email =~ /\@/) {
        $c->stash->{error_msg} = 'Invalid email address.';
        $c->stash(
            workshop => $workshop,
            template => 'WorkShops/AddParticipant.tt',
        );
        return;
    }
    
    my $existing = $c->model('DBEncy::Participant')->search({
        workshop_id => $id,
        email => $email,
        status => { -in => ['registered', 'waitlist'] }
    })->first;
    
    if ($existing) {
        $c->stash->{error_msg} = 'A participant with this email address is already registered.';
        $c->stash(
            workshop => $workshop,
            template => 'WorkShops/AddParticipant.tt',
        );
        return;
    }
    
    my $participant_status;
    if ($workshop->is_full) {
        $participant_status = 'waitlist';
    } else {
        $participant_status = 'registered';
    }
    
    my $participant;
    eval {
        $participant = $c->model('DBEncy::Participant')->create({
            workshop_id => $id,
            name => $name,
            email => $email,
            site_affiliation => $site_affiliation,
            status => $participant_status,
        });
    };
    
    if ($@) {
        $c->flash->{error_msg} = 'Failed to add participant: ' . $@;
    } else {
        if ($participant_status eq 'registered') {
            $c->flash->{success_msg} = "Participant added successfully.";
        } else {
            $c->flash->{success_msg} = "Participant added to waitlist (workshop is full).";
        }
    }
    
    $c->response->redirect($c->uri_for($self->action_for('participants'), [$id]));
}

sub remove_participant :Local :Args(1) {
    my ($self, $c, $participant_id) = @_;
    
    my $participant = $c->model('DBEncy::Participant')->find($participant_id);
    
    unless ($participant) {
        $c->flash->{error_msg} = 'Participant not found.';
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }
    
    my $workshop = $participant->workshop;
    my $workshop_id = $workshop->id;
    
    unless ($self->_check_workshop_access($c, $workshop, 'leader')) {
        $c->flash->{error_msg} = 'Access denied. You do not have permission to remove participants from this workshop.';
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }
    
    eval {
        $participant->update({ status => 'cancelled' });
    };
    
    if ($@) {
        $c->flash->{error_msg} = 'Failed to remove participant: ' . $@;
    } else {
        $c->flash->{success_msg} = 'Participant removed successfully.';
    }
    
    $c->response->redirect($c->uri_for($self->action_for('participants'), [$workshop_id]));
}

sub files :Local :Args(1) {
    my ($self, $c, $id) = @_;
    
    my $workshop = $c->model('DBEncy::WorkShop')->find($id);
    
    unless ($workshop) {
        $c->flash->{error_msg} = 'Workshop not found.';
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }
    
    unless ($self->_check_workshop_access($c, $workshop, 'view')) {
        $c->flash->{error_msg} = 'Access denied. You do not have permission to view files for this workshop.';
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }
    
    my @files = $c->model('DBEncy::File')->search(
        { workshop_id => $id },
        { order_by => { -desc => 'upload_date' } }
    )->all;
    
    $c->stash(
        workshop => $workshop,
        files => \@files,
        template => 'WorkShops/Files.tt',
    );
}

sub upload :Local :Args(1) {
    my ($self, $c, $id) = @_;
    
    my $workshop = $c->model('DBEncy::WorkShop')->find($id);
    
    unless ($workshop) {
        $c->flash->{error_msg} = 'Workshop not found.';
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }
    
    unless ($self->_check_workshop_access($c, $workshop, 'leader')) {
        $c->flash->{error_msg} = 'Access denied. You do not have permission to upload files to this workshop.';
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }
    
    if ($c->request->method eq 'GET') {
        $c->stash(
            workshop => $workshop,
            template => 'WorkShops/Upload.tt',
        );
        return;
    }
    
    my $upload = $c->request->upload('file');
    
    unless ($upload) {
        $c->stash->{error_msg} = 'No file uploaded.';
        $c->stash(
            workshop => $workshop,
            template => 'WorkShops/Upload.tt',
        );
        return;
    }
    
    my $filename = $upload->filename;
    my $filesize = $upload->size;
    
    my @allowed_extensions = ('.ppt', '.pptx', '.pdf', '.PPT', '.PPTX', '.PDF');
    my $max_size = 50 * 1024 * 1024;
    
    my ($file_extension) = $filename =~ /(\.[^.]+)$/;
    
    unless ($file_extension && grep { lc($_) eq lc($file_extension) } @allowed_extensions) {
        $c->stash->{error_msg} = 'Invalid file type. Only PowerPoint (PPT, PPTX) and PDF files are allowed.';
        $c->stash(
            workshop => $workshop,
            template => 'WorkShops/Upload.tt',
        );
        return;
    }
    
    if ($filesize > $max_size) {
        my $max_mb = $max_size / (1024 * 1024);
        $c->stash->{error_msg} = "File is too large. Maximum size is ${max_mb}MB.";
        $c->stash(
            workshop => $workshop,
            template => 'WorkShops/Upload.tt',
        );
        return;
    }
    
    my $upload_dir = $c->config->{workshop_upload_dir} || $ENV{HOME} . '/workshop_files';
    
    unless (-d $upload_dir) {
        mkdir $upload_dir or do {
            $c->log->error("Failed to create upload directory: $!");
            $c->flash->{error_msg} = 'Failed to create upload directory.';
            $c->response->redirect($c->uri_for($self->action_for('files'), [$id]));
            return;
        };
    }
    
    my $timestamp = time();
    my $safe_filename = $timestamp . '_' . $filename;
    $safe_filename =~ s/[^a-zA-Z0-9._-]/_/g;
    
    my $filepath = "$upload_dir/$safe_filename";
    
    my $file_record;
    eval {
        $upload->copy_to($filepath);
        
        open my $fh, '<', $filepath or die "Cannot read file: $!";
        binmode $fh;
        my $file_data = do { local $/; <$fh> };
        close $fh;
        
        $file_record = $c->model('DBEncy::File')->create({
            workshop_id => $id,
            file_name => $filename,
            file_type => $file_extension,
            file_size => $filesize,
            file_path => $filepath,
            file_data => $file_data,
            upload_date => DateTime->now,
            user_id => $c->session->{user_id},
        });
    };
    
    if ($@) {
        $c->log->error("File upload failed: $@");
        $c->flash->{error_msg} = "Failed to upload file: $@";
    } else {
        $c->flash->{success_msg} = 'File uploaded successfully.';
    }
    
    $c->response->redirect($c->uri_for($self->action_for('files'), [$id]));
}

sub download :Local :Args(1) {
    my ($self, $c, $file_id) = @_;
    
    my $file = $c->model('DBEncy::File')->find($file_id);
    
    unless ($file) {
        $c->flash->{error_msg} = 'File not found.';
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }
    
    unless ($file->workshop_id) {
        $c->flash->{error_msg} = 'File is not associated with a workshop.';
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }
    
    my $workshop = $c->model('DBEncy::WorkShop')->find($file->workshop_id);
    
    unless ($workshop) {
        $c->flash->{error_msg} = 'Associated workshop not found.';
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }
    
    my $user_id = $c->session->{user_id};
    
    my $is_registered = $c->model('DBEncy::Participant')->search({
        workshop_id => $workshop->id,
        user_id => $user_id,
        status => { -in => ['registered', 'attended'] }
    })->count > 0;
    
    my $is_leader = $self->_is_workshop_leader($c, $workshop);
    
    my $admin_auth = Comserv::Util::AdminAuth->new();
    my $admin_type = $admin_auth->get_admin_type($c);
    my $is_admin = ($admin_type eq 'csc' || $admin_type eq 'special' || $admin_type eq 'standard');
    
    unless ($is_registered || $is_leader || $is_admin) {
        $c->flash->{error_msg} = 'Access denied. You must be registered for this workshop to download files.';
        $c->response->redirect($c->uri_for($self->action_for('details'), { id => $workshop->id }));
        return;
    }
    
    my $file_data;
    if ($file->file_data) {
        $file_data = $file->file_data;
    } elsif ($file->file_path && -f $file->file_path) {
        open my $fh, '<', $file->file_path or do {
            $c->log->error("Cannot read file: $!");
            $c->flash->{error_msg} = 'Failed to read file.';
            $c->response->redirect($c->uri_for($self->action_for('files'), [$workshop->id]));
            return;
        };
        binmode $fh;
        $file_data = do { local $/; <$fh> };
        close $fh;
    } else {
        $c->flash->{error_msg} = 'File data not available.';
        $c->response->redirect($c->uri_for($self->action_for('files'), [$workshop->id]));
        return;
    }
    
    my $content_type = 'application/octet-stream';
    if ($file->file_type) {
        my $ext = lc($file->file_type);
        if ($ext eq '.pdf') {
            $content_type = 'application/pdf';
        } elsif ($ext eq '.ppt') {
            $content_type = 'application/vnd.ms-powerpoint';
        } elsif ($ext eq '.pptx') {
            $content_type = 'application/vnd.openxmlformats-officedocument.presentationml.presentation';
        }
    }
    
    $c->response->content_type($content_type);
    $c->response->header('Content-Disposition' => 'attachment; filename="' . $file->file_name . '"');
    $c->response->body($file_data);
}

sub content :Local :Args(1) {
    my ($self, $c, $id) = @_;
    
    my $workshop = $c->model('DBEncy::WorkShop')->find($id);
    
    unless ($workshop) {
        $c->flash->{error_msg} = 'Workshop not found.';
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }
    
    unless ($self->_check_workshop_access($c, $workshop, 'view')) {
        $c->flash->{error_msg} = 'Access denied. You do not have permission to view content for this workshop.';
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }
    
    my @content = $c->model('DBEncy::WorkshopContent')->search(
        { workshop_id => $id },
        { order_by => { -asc => 'sort_order' } }
    )->all;
    
    $c->stash(
        workshop => $workshop,
        content_sections => \@content,
        template => 'WorkShops/Content.tt',
    );
}

sub add_content :Local :Args(1) {
    my ($self, $c, $id) = @_;
    
    my $workshop = $c->model('DBEncy::WorkShop')->find($id);
    
    unless ($workshop) {
        $c->flash->{error_msg} = 'Workshop not found.';
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }
    
    unless ($self->_check_workshop_access($c, $workshop, 'leader')) {
        $c->flash->{error_msg} = 'Access denied. You do not have permission to add content to this workshop.';
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }
    
    if ($c->request->method eq 'GET') {
        $c->stash(
            workshop => $workshop,
            template => 'WorkShops/AddContent.tt',
        );
        return;
    }
    
    my $params = $c->request->body_parameters;
    my $title = $params->{title};
    my $content = $params->{content};
    my $content_type = $params->{content_type} || 'text';
    
    unless ($title) {
        $c->stash->{error_msg} = 'Title is required.';
        $c->stash(
            workshop => $workshop,
            form_data => $params,
            template => 'WorkShops/AddContent.tt',
        );
        return;
    }
    
    my $max_sort_order = $c->model('DBEncy::WorkshopContent')->search(
        { workshop_id => $id }
    )->get_column('sort_order')->max || 0;
    
    my $content_record;
    eval {
        $content_record = $c->model('DBEncy::WorkshopContent')->create({
            workshop_id => $id,
            title => $title,
            content => $content,
            content_type => $content_type,
            sort_order => $max_sort_order + 1,
        });
    };
    
    if ($@) {
        $c->log->error("Failed to create content: $@");
        $c->flash->{error_msg} = "Failed to create content: $@";
    } else {
        $c->flash->{success_msg} = 'Content added successfully.';
    }
    
    $c->response->redirect($c->uri_for($self->action_for('content'), [$id]));
}

sub edit_content :Local :Args(1) {
    my ($self, $c, $content_id) = @_;
    
    my $content_record = $c->model('DBEncy::WorkshopContent')->find($content_id);
    
    unless ($content_record) {
        $c->flash->{error_msg} = 'Content not found.';
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }
    
    my $workshop = $content_record->workshop;
    my $workshop_id = $workshop->id;
    
    unless ($self->_check_workshop_access($c, $workshop, 'leader')) {
        $c->flash->{error_msg} = 'Access denied. You do not have permission to edit content for this workshop.';
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }
    
    if ($c->request->method eq 'GET') {
        $c->stash(
            workshop => $workshop,
            content_record => $content_record,
            template => 'WorkShops/edit_content.tt',
        );
        return;
    }
    
    my $params = $c->request->body_parameters;
    my $title = $params->{title};
    my $content = $params->{content};
    my $content_type = $params->{content_type} || 'text';
    
    unless ($title) {
        $c->stash->{error_msg} = 'Title is required.';
        $c->stash(
            workshop => $workshop,
            content_record => $content_record,
            form_data => $params,
            template => 'WorkShops/edit_content.tt',
        );
        return;
    }
    
    eval {
        $content_record->update({
            title => $title,
            content => $content,
            content_type => $content_type,
        });
    };
    
    if ($@) {
        $c->log->error("Failed to update content: $@");
        $c->flash->{error_msg} = "Failed to update content: $@";
    } else {
        $c->flash->{success_msg} = 'Content updated successfully.';
    }
    
    $c->response->redirect($c->uri_for($self->action_for('content'), [$workshop_id]));
}

sub delete_content :Local :Args(1) {
    my ($self, $c, $content_id) = @_;
    
    my $content_record = $c->model('DBEncy::WorkshopContent')->find($content_id);
    
    unless ($content_record) {
        $c->flash->{error_msg} = 'Content not found.';
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }
    
    my $workshop = $content_record->workshop;
    my $workshop_id = $workshop->id;
    
    unless ($self->_check_workshop_access($c, $workshop, 'leader')) {
        $c->flash->{error_msg} = 'Access denied. You do not have permission to delete content from this workshop.';
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }
    
    eval {
        $content_record->delete;
    };
    
    if ($@) {
        $c->log->error("Failed to delete content: $@");
        $c->flash->{error_msg} = "Failed to delete content: $@";
    } else {
        $c->flash->{success_msg} = 'Content deleted successfully.';
    }
    
    $c->response->redirect($c->uri_for($self->action_for('content'), [$workshop_id]));
}

sub reorder_content :Local :Args(1) {
    my ($self, $c, $id) = @_;
    
    my $workshop = $c->model('DBEncy::WorkShop')->find($id);
    
    unless ($workshop) {
        $c->response->status(404);
        $c->response->body('Workshop not found');
        return;
    }
    
    unless ($self->_check_workshop_access($c, $workshop, 'leader')) {
        $c->response->status(403);
        $c->response->body('Access denied');
        return;
    }
    
    my $params = $c->request->body_parameters;
    my $order = $params->{order};
    
    unless ($order) {
        $c->response->status(400);
        $c->response->body('Missing order parameter');
        return;
    }
    
    my @content_ids = split(',', $order);
    
    my $sort_order = 1;
    for my $content_id (@content_ids) {
        my $content_record = $c->model('DBEncy::WorkshopContent')->find($content_id);
        if ($content_record && $content_record->workshop_id == $id) {
            eval {
                $content_record->update({ sort_order => $sort_order });
            };
            if ($@) {
                $c->log->error("Failed to update sort_order for content $content_id: $@");
            }
            $sort_order++;
        }
    }
    
    $c->response->content_type('application/json');
    $c->response->body('{"success": true}');
}

sub compose_email :Local :Args(1) {
    my ($self, $c, $id) = @_;
    
    my $workshop = $c->model('DBEncy::WorkShop')->find($id);
    
    unless ($workshop) {
        $c->flash->{error_msg} = 'Workshop not found.';
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }
    
    unless ($self->_check_workshop_access($c, $workshop, 'leader')) {
        $c->flash->{error_msg} = 'Access denied. You do not have permission to send emails for this workshop.';
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }
    
    my $registered_count = $c->model('DBEncy::Participant')->search({
        workshop_id => $id,
        status => 'registered'
    })->count;
    
    $c->stash(
        workshop => $workshop,
        recipient_count => $registered_count,
        template => 'WorkShops/ComposeEmail.tt',
    );
}

sub send_email :Local :Args(1) {
    my ($self, $c, $id) = @_;
    
    my $workshop = $c->model('DBEncy::WorkShop')->find($id);
    
    unless ($workshop) {
        $c->flash->{error_msg} = 'Workshop not found.';
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }
    
    unless ($self->_check_workshop_access($c, $workshop, 'leader')) {
        $c->flash->{error_msg} = 'Access denied. You do not have permission to send emails for this workshop.';
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }
    
    my $params = $c->request->body_parameters;
    my $subject = $params->{subject};
    my $body = $params->{body};
    
    unless ($subject && $body) {
        $c->stash->{error_msg} = 'Subject and body are required.';
        my $registered_count = $c->model('DBEncy::Participant')->search({
            workshop_id => $id,
            status => 'registered'
        })->count;
        $c->stash(
            workshop => $workshop,
            recipient_count => $registered_count,
            form_data => $params,
            template => 'WorkShops/ComposeEmail.tt',
        );
        return;
    }
    
    my @registered_participants = $c->model('DBEncy::Participant')->search(
        {
            workshop_id => $id,
            status => 'registered'
        },
        { prefetch => 'user' }
    )->all;
    
    unless (@registered_participants) {
        $c->flash->{error_msg} = 'No registered participants to email.';
        $c->response->redirect($c->uri_for($self->action_for('participants'), [$id]));
        return;
    }
    
    my @recipient_emails;
    for my $participant (@registered_participants) {
        if ($participant->email && $participant->email =~ /\@/) {
            push @recipient_emails, $participant->email;
        }
    }
    
    unless (@recipient_emails) {
        $c->flash->{error_msg} = 'No valid email addresses found for registered participants.';
        $c->response->redirect($c->uri_for($self->action_for('participants'), [$id]));
        return;
    }
    
    my $from_address = $c->config->{mail_from} || 'noreply@computersystemconsulting.ca';
    my $reply_to = $c->config->{mail_replyto} || 'helpdesk@computersystemconsulting.ca';
    
    my $workshop_url = $c->uri_for($self->action_for('details'), { id => $id });
    my $base_uri = $c->req->base;
    my $full_url = $base_uri . $workshop_url;
    
    my $formatted_date = $workshop->date ? $workshop->date->strftime('%Y-%m-%d') : 'TBD';
    my $formatted_time = $workshop->time ? $workshop->time->strftime('%H:%M') : 'TBD';
    my $formatted_end_time = $workshop->end_time || '';
    
    my $sent_count = 0;
    my $failed_count = 0;
    my @failed_emails;
    
    for my $participant (@registered_participants) {
        my $email = $participant->email;
        next unless $email && $email =~ /\@/;
        
        my $user_name = '';
        if ($participant->user) {
            $user_name = $participant->user->first_name || $participant->user->username || '';
            if ($participant->user->last_name) {
                $user_name .= ' ' . $participant->user->last_name;
            }
        } elsif ($participant->name) {
            $user_name = $participant->name;
        }
        
        eval {
            $c->stash->{email} = {
                to       => $email,
                from     => $from_address,
                reply_to => $reply_to,
                subject  => $subject,
                template => 'email/workshop/workshop_announcement.tt',
                template_vars => {
                    name => $user_name,
                    workshop_title => $workshop->title,
                    workshop_instructor => $workshop->instructor,
                    workshop_date => $formatted_date,
                    workshop_time => $formatted_time,
                    workshop_end_time => $formatted_end_time,
                    workshop_location => $workshop->location,
                    workshop_url => $full_url,
                    message_body => $body,
                },
            };
            
            $c->forward($c->view('Email::Template'));
            $sent_count++;
        };
        
        if ($@) {
            $c->log->warn("Failed to send email to $email: $@");
            $failed_count++;
            push @failed_emails, $email;
        }
    }
    
    my $email_status = 'sent';
    if ($failed_count > 0 && $sent_count == 0) {
        $email_status = 'failed';
    } elsif ($failed_count > 0) {
        $email_status = 'partial';
    }
    
    my $email_record;
    eval {
        $email_record = $c->model('DBEncy::WorkshopEmail')->create({
            workshop_id => $id,
            subject => $subject,
            body => $body,
            sent_by => $c->session->{user_id},
            sent_at => DateTime->now,
            recipient_count => $sent_count,
            status => $email_status,
        });
    };
    
    if ($@) {
        $c->log->error("Failed to record email in database: $@");
    }
    
    if ($failed_count > 0) {
        my $failed_list = join(', ', @failed_emails);
        $c->flash->{warning_msg} = "Email sent to $sent_count participant(s). Failed to send to $failed_count: $failed_list";
    } else {
        $c->flash->{success_msg} = "Email sent successfully to $sent_count participant(s).";
    }
    
    $c->response->redirect($c->uri_for($self->action_for('email_history'), [$id]));
}

sub email_history :Local :Args(1) {
    my ($self, $c, $id) = @_;
    
    my $workshop = $c->model('DBEncy::WorkShop')->find($id);
    
    unless ($workshop) {
        $c->flash->{error_msg} = 'Workshop not found.';
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }
    
    unless ($self->_check_workshop_access($c, $workshop, 'leader')) {
        $c->flash->{error_msg} = 'Access denied. You do not have permission to view email history for this workshop.';
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }
    
    my @emails = $c->model('DBEncy::WorkshopEmail')->search(
        { workshop_id => $id },
        {
            order_by => { -desc => 'sent_at' },
            prefetch => 'sender'
        }
    )->all;
    
    $c->stash(
        workshop => $workshop,
        emails => \@emails,
        template => 'WorkShops/EmailHistory.tt',
    );
}


__PACKAGE__->meta->make_immutable;

1;
