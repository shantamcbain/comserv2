package Comserv::Controller::WorkShop;
use Moose;
use namespace::autoclean;
use Data::FormValidator;
use Comserv::Util::AdminAuth;
use Comserv::Util::Logging;
BEGIN { extends 'Catalyst::Controller'; }

has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

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

    my $roles = $c->session->{roles} || [];
    my $has_workshop_leader_role = ref $roles eq 'ARRAY' && grep { $_ eq 'workshop_leader' } @$roles;
    my $can_access_dashboard = $is_admin || $has_workshop_leader_role ? 1 : 0;

    $c->stash(
        workshops => \@workshops_hash,
        past_workshops => \@past_workshops_hash,
        error => $error,
        past_error => $past_error,
        sitename => $c->session->{SiteName},
        is_admin => $is_admin,
        can_access_dashboard => $can_access_dashboard,
        template => 'WorkShops/Workshops.tt',
    );
    if ($@) {
    $c->stash(error => "Error fetching active workshops: $@");
}
}
sub dashboard :Local {
    my ( $self, $c ) = @_;

    # Check if user has admin access OR workshop_leader role
    my $admin_auth = Comserv::Util::AdminAuth->new();
    my $has_admin = $admin_auth->check_admin_access($c, 'workshop_dashboard');
    
    my $roles = $c->session->{roles} || [];
    my $has_workshop_leader_role = 0;
    if (ref $roles eq 'ARRAY') {
        $has_workshop_leader_role = grep { $_ eq 'workshop_leader' } @$roles;
    }
    
    unless ($has_admin || $has_workshop_leader_role) {
        $c->flash->{error_msg} = "Access denied. Admin or workshop leader access required.";
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }

    my $user_id = $c->session->{user_id};
    my $sitename = $c->session->{SiteName};
    my $schema = $c->model('DBEncy');
    my $admin_type = $admin_auth->get_admin_type($c);
    my $is_csc_admin = ($admin_type eq 'csc' || $admin_type eq 'special');

    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'workshop', "Dashboard: user_id=$user_id, sitename=$sitename, admin_type=$admin_type, is_csc_admin=$is_csc_admin");

    my $search_filter;

    if ($is_csc_admin) {
        $search_filter = {};
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'workshop', "Dashboard: CSC admin - showing ALL workshops");
    } else {
        $search_filter = {
            -or => [
                { created_by => $user_id },
            ]
        };
        if ($sitename) {
            push @{$search_filter->{-or}}, { sitename => $sitename, created_by => undef };
        }
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'workshop', "Dashboard: Regular admin filter applied");
    }

    my @my_workshops = $schema->resultset('WorkShop')->search(
        $search_filter,
        { 
            order_by => { -desc => 'me.created_at' },
            prefetch => 'creator'
        }
    )->all;

    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'workshop', "Dashboard: Found " . scalar(@my_workshops) . " workshops from main search");

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

    unless ($c->session->{username}) {
        $c->response->redirect($c->uri_for('/user/login', { return_to => '/workshop/add' }));
        return;
    }

    # Set the TT template to use
    $c->stash->{template} = 'WorkShops/AddWorkshop.tt';
}
sub addworkshop :Local {
    my ( $self, $c ) = @_;

    unless ($c->session->{username}) {
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }

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
            sitename            => $creator_sitename,
            title               => $params->{title},
            description         => $params->{description},
            date                => $params->{dateOfWorkshop},
            location            => $params->{location},
            instructor          => $params->{instructor},
            max_participants    => $params->{maxMinAttendees},
            share               => $params->{share} || 'private',
            status              => $params->{status} || 'draft',
            registration_deadline => $params->{registration_deadline},
            end_time            => $params->{end_time},
            time                => $time,
            created_by          => $c->session->{user_id},
            site_id             => $creator_site_id,
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
        # Log error with details and send email to site admin
        my $error_msg = "Failed to create workshop: $@";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'workshop', $error_msg);
        
        # Send error notification to site admin
        $self->_send_error_notification($c, {
            error_type => 'Workshop Creation Error',
            error_message => $error_msg,
            user_id => $c->session->{user_id},
            username => $c->session->{username},
            site => $c->session->{SiteName},
            form_data => $params,
        });
        
        # Show user-friendly error message
        $c->stash->{error_msg} = 'An error occurred while creating the workshop. The site administrator has been notified.';
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
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'workshop', "Failed to find workshop with ID $id: " . ($@ || 'Workshop not found'));
        $c->flash->{error_msg} = 'Failed to find workshop: ' . ($@ || 'Workshop not found');
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }

    # Workshop details are viewable by all users
    # Edit access is restricted to admins/leaders via separate authorization checks

    # Format workshop date safely
    my $formatted_date = '';
    if ($workshop->date) {
        eval {
            if (ref($workshop->date) && $workshop->date->can('strftime')) {
                $formatted_date = $workshop->date->strftime('%Y-%m-%d');
            } else {
                $formatted_date = $workshop->date;
            }
        };
        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'workshop', "Error formatting workshop date: $@");
            $formatted_date = $workshop->date || '';
        }
    }

    # Check if user is registered for this workshop (including past attendees)
    my $is_user_registered = 0;
    my $is_workshop_leader = 0;
    if ($c->user_exists) {
        my $user_id = $c->session->{user_id};
        my $participant = $schema->resultset('Participant')->search({
            workshop_id => $id,
            user_id => $user_id,
            status => { -in => ['registered', 'waitlist', 'attended'] }
        })->first;
        $is_user_registered = 1 if $participant;
        
        # Check if user is the workshop leader
        $is_workshop_leader = $self->_is_workshop_leader($c, $workshop);
    }

    # Get workshop files — combine files table (workshop_id) + workshop_resource table
    my @workshop_files;
    eval {
        my @direct = $schema->resultset('File')->search(
            { 'me.workshop_id' => $id },
            {
                columns  => [qw(id file_name file_type file_size upload_date nfs_path file_path external_url)],
                order_by => { -desc => 'me.upload_date' },
            }
        )->all;
        for my $f (@direct) {
            push @workshop_files, {
                id          => $f->id,
                file_name   => $f->file_name  // '',
                file_type   => $f->file_type  // '',
                file_size   => $f->file_size  // 0,
                upload_date => $f->upload_date // '',
                source      => 'files',
            };
        }
    };
    $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'workshop', "details: file query error: $@") if $@;

    eval {
        my @resources = $schema->resultset('WorkshopResource')->search(
            { 'me.workshop_id' => $id },
            { order_by => { -desc => 'me.created_at' } }
        )->all;
        for my $r (@resources) {
            push @workshop_files, {
                id          => $r->id,
                file_name   => $r->file_name  // '',
                file_type   => $r->file_ext   // $r->file_type // '',
                file_size   => $r->file_size  // 0,
                upload_date => $r->created_at // '',
                source      => 'workshop_resource',
                external_url => $r->external_url // '',
            };
        }
    };
    $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'workshop', "details: resource query error: $@") if $@;

    # Get workshop content
    my @workshop_content = $schema->resultset('WorkshopContent')->search(
        { workshop_id => $id },
        { order_by => { -asc => 'sort_order' } }
    )->all;

    my $admin_auth_d = Comserv::Util::AdminAuth->new();
    my $is_admin_d = $admin_auth_d->check_admin_access($c, 'workshop_details');

    $c->stash(
        workshop => $workshop,
        formatted_date => $formatted_date,
        is_user_registered => $is_user_registered,
        is_workshop_leader => $is_workshop_leader,
        is_admin => $is_admin_d,
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

    # Debug logging for authorization issues
    my $user_id = $c->session->{user_id};
    my $admin_auth = Comserv::Util::AdminAuth->new();
    my $admin_type = $admin_auth->get_admin_type($c);
    my $is_leader = $self->_is_workshop_leader($c, $workshop);
    my $can_edit = $self->_can_edit_workshop($c, $workshop);
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'workshop', "Edit Workshop Authorization Debug:");
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'workshop', "  Workshop ID: " . $workshop->id);
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'workshop', "  Workshop created_by: " . ($workshop->created_by || 'NULL'));
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'workshop', "  Session user_id: " . ($user_id || 'NULL'));
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'workshop', "  Admin type: " . ($admin_type || 'NONE'));
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'workshop', "  Is workshop leader: " . ($is_leader ? 'YES' : 'NO'));
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'workshop', "  Can edit workshop: " . ($can_edit ? 'YES' : 'NO'));

    # Authorization check using helper method
    unless ($can_edit) {
        $c->flash->{error_msg} = 'Access denied. You do not have permission to edit this workshop.';
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }

    my @all_sites = $c->model('DBEncy')->resultset('Site')->search({}, { order_by => 'name' })->all;

    my $raw_date = $workshop->date;
    my $formatted_date = '';
    if ($raw_date) {
        if (ref($raw_date) && $raw_date->can('strftime')) {
            $formatted_date = $raw_date->strftime('%Y-%m-%d');
        } else {
            ($formatted_date = "$raw_date") =~ s/ .*$//;
        }
    }

    # For GET requests, display the edit form
    if ($c->request->method eq 'GET') {
        $c->stash(
            workshop       => $workshop,
            formatted_date => $formatted_date,
            all_sites      => \@all_sites,
            template       => 'WorkShops/Edit.tt',
        );
        return;
    }

    # Handle POST request for updates
    if ($c->request->method eq 'POST') {
        my $params    = $c->request->body_parameters;
        my $old_share = $workshop->share || '';
        my $new_share = $params->{share} || 'private';
        my $new_sitename = $params->{sitename} || $workshop->sitename;

        my $err;
        eval {
            $workshop->update({
                title                 => $params->{title},
                description           => $params->{description},
                date                  => $params->{date},
                time                  => $params->{time},
                end_time              => $params->{end_time},
                location              => $params->{location},
                instructor            => $params->{instructor},
                max_participants      => $params->{max_participants},
                share                 => $new_share,
                status                => $params->{status},
                registration_deadline => $params->{registration_deadline} || undef,
                sitename              => $new_sitename,
            });

            # Update site_workshop records if share setting changed
            if ($old_share ne $new_share) {
                my $schema = $c->model('DBEncy');
                $schema->resultset('SiteWorkshop')->search({ workshop_id => $workshop->id })->delete;

                if ($new_share eq 'public') {
                    for my $site (@all_sites) {
                        $schema->resultset('SiteWorkshop')->create({
                            site_id => $site->id, workshop_id => $workshop->id,
                        });
                    }
                } else {
                    my $site_obj = $schema->resultset('Site')->search({ name => $new_sitename })->first;
                    if ($site_obj) {
                        $schema->resultset('SiteWorkshop')->create({
                            site_id => $site_obj->id, workshop_id => $workshop->id,
                        });
                    }
                }
            }
        };
        $err = "$@" if $@;

        if ($err) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'workshop', "Failed to update workshop " . $workshop->id . ": $err");
            $c->stash(
                workshop       => $workshop,
                formatted_date => $formatted_date,
                all_sites      => \@all_sites,
                error_msg      => "Failed to update workshop: $err",
                template       => 'WorkShops/Edit.tt',
            );
            $c->forward($c->view('TT'));
            return;
        }

        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'workshop', "Workshop " . $workshop->id . " updated by user " . ($c->session->{user_id} || 'unknown'));
        $c->flash->{success_msg} = 'Workshop updated successfully.';
        $c->res->redirect($c->uri_for($self->action_for('index')));
        return;
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
    # Use session data - this app uses session-based auth, not Catalyst::Plugin::Authentication
    my $user_id = $c->session->{user_id};
    return 0 unless $user_id;
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
        # Site admin can edit workshops from their site
        if ($admin_type eq 'standard' && $sitename && $sitename eq $workshop->sitename) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'workshop', "_check_workshop_access: GRANTED (site admin for " . $sitename . ")");
            return 1;
        }
        
        # Workshop leader (creator or workshop_roles)
        if ($self->_is_workshop_leader($c, $workshop)) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'workshop', "_check_workshop_access: GRANTED (workshop leader)");
            return 1;
        }
        
        # Fallback: If created_by is NULL and user is admin, allow edit
        if (!$workshop->created_by && ($admin_type eq 'standard' || $admin_type eq 'csc' || $admin_type eq 'special')) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'workshop', "_check_workshop_access: GRANTED (created_by is NULL and user is admin)");
            return 1;
        }
    }
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'workshop', "_check_workshop_access: DENIED (no matching authorization criteria)");
    return 0;
}

sub _is_workshop_leader {
    my ($self, $c, $workshop) = @_;
    
    my $user_id = $c->session->{user_id};
    return 0 unless $user_id;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'workshop', "_is_workshop_leader check:");
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'workshop', "  user_id: " . ($user_id || 'NULL'));
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'workshop', "  workshop.created_by: " . ($workshop->created_by || 'NULL'));
    
    if ($workshop->created_by && $user_id && $workshop->created_by == $user_id) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'workshop', "  Result: TRUE (created_by matches)");
        return 1;
    }
    
    my $has_leader_role = $c->model('DBEncy::WorkshopRole')->search({
        workshop_id => $workshop->id,
        user_id => $user_id,
        role => 'workshop_leader'
    })->count > 0;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'workshop', "  has_leader_role from workshop_roles: " . ($has_leader_role ? 'YES' : 'NO'));
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'workshop', "  Result: " . ($has_leader_role ? 'TRUE' : 'FALSE'));
    
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

sub delete :Local :Args(1) {
    my ($self, $c, $id) = @_;
    
    my $workshop = $c->model('DBEncy::WorkShop')->find($id);
    
    unless ($workshop) {
        $c->flash->{error_msg} = 'Workshop not found.';
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }
    
    unless ($self->_can_edit_workshop($c, $workshop)) {
        $c->flash->{error_msg} = 'Access denied. You do not have permission to delete this workshop.';
        $c->response->redirect($c->uri_for($self->action_for('dashboard')));
        return;
    }
    
    eval {
        # Delete related records first (cascade)
        $c->model('DBEncy::Participant')->search({ workshop_id => $id })->delete;
        $c->model('DBEncy::WorkshopEmail')->search({ workshop_id => $id })->delete;
        $c->model('DBEncy::WorkshopContent')->search({ workshop_id => $id })->delete;
        $c->model('DBEncy::WorkshopRole')->search({ workshop_id => $id })->delete;
        $c->model('DBEncy::SiteWorkshop')->search({ workshop_id => $id })->delete;
        # Delete workshop itself
        $workshop->delete;
    };
    
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'workshop', "Failed to delete workshop: $@");
        $c->flash->{error_msg} = 'Failed to delete workshop: ' . $@;
        $c->response->redirect($c->uri_for($self->action_for('dashboard')));
    } else {
        $c->flash->{success_msg} = 'Workshop deleted successfully.';
        $c->response->redirect($c->uri_for($self->action_for('index')));
    }
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
            
            my $formatted_date = do {
                my $d = $workshop->date;
                $d ? (ref($d) && $d->can('strftime') ? $d->strftime('%Y-%m-%d') : do { (my $s = "$d") =~ s/ .*$//; $s }) : 'TBD';
            };
            my $formatted_time = do {
                my $t = $workshop->time;
                $t ? (ref($t) && $t->can('strftime') ? $t->strftime('%H:%M') : substr("$t", 0, 5)) : 'TBD';
            };
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
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'workshop', "Failed to send registration confirmation email: $@");
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
            'me.status' => 'registered'
        },
        {
            order_by => { -asc => 'registered_at' },
            prefetch => 'user'
        }
    )->all;
    
    my @waitlist = $c->model('DBEncy::Participant')->search(
        {
            workshop_id => $id,
            'me.status' => 'waitlist'
        },
        {
            order_by => { -asc => 'registered_at' },
            prefetch => 'user'
        }
    )->all;
    
    $c->stash(
        workshop => $workshop,
        registered => \@registered,
        waitlist   => \@waitlist,
        template   => 'WorkShops/Participants.tt',
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
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'workshop', "Failed to create upload directory: $!");
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
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'workshop', "File upload failed: $@");
        $c->flash->{error_msg} = "Failed to upload file: $@";
    } else {
        $c->flash->{success_msg} = 'File uploaded successfully.';
    }
    
    $c->response->redirect($c->uri_for($self->action_for('files'), [$id]));
}

sub download :Local :Args(1) {
    my ($self, $c, $file_id) = @_;

    my $user_id = $c->session->{user_id};
    unless ($user_id) {
        $c->flash->{error_msg} = 'Please log in to download workshop files.';
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }

    my $file = eval { $c->model('DBEncy::File')->find($file_id) };
    unless ($file) {
        $c->flash->{error_msg} = 'File not found.';
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }

    my $workshop_id = $file->workshop_id;
    my $back_url    = $workshop_id
        ? $c->uri_for('/workshop/details', { id => $workshop_id })
        : $c->uri_for($self->action_for('index'));

    # Access: admin, file owner, workshop leader, or registered attendee
    my $admin_auth = Comserv::Util::AdminAuth->new();
    my $is_admin   = ($admin_auth->get_admin_type($c) // 'none') ne 'none';
    my $is_owner   = ($file->user_id && $file->user_id == $user_id);

    my ($is_leader, $is_registered) = (0, 0);
    if ($workshop_id) {
        my $workshop = eval { $c->model('DBEncy::WorkShop')->find($workshop_id) };
        if ($workshop) {
            $is_leader = $self->_is_workshop_leader($c, $workshop);
            my $p = eval {
                $c->model('DBEncy')->resultset('Participant')->search({
                    workshop_id => $workshop_id,
                    user_id     => $user_id,
                    status      => { -in => ['registered', 'attended', 'waitlist'] },
                })->first;
            };
            $is_registered = 1 if $p;
        }
    }

    unless ($is_admin || $is_owner || $is_leader || $is_registered) {
        $c->flash->{error_msg} = 'Access denied. You must be registered for this workshop to download its files.';
        $c->response->redirect($back_url);
        return;
    }

    my $file_data;
    if ($file->file_data) {
        $file_data = $file->file_data;
    } elsif ($file->file_path && -f $file->file_path) {
        eval {
            open my $fh, '<:raw', $file->file_path or die $!;
            $file_data = do { local $/; <$fh> };
            close $fh;
        };
        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'workshop', "download read error: $@");
            $c->flash->{error_msg} = 'Failed to read file.';
            $c->response->redirect($back_url);
            return;
        }
    } else {
        $c->flash->{error_msg} = 'File data not available.';
        $c->response->redirect($back_url);
        return;
    }

    my $content_type = $file->file_type || 'application/octet-stream';
    $c->response->content_type($content_type);
    $c->response->header('Content-Disposition' => 'attachment; filename="' . ($file->file_name // 'file') . '"');
    $c->response->body($file_data);
}

sub _nfs_root {
    my $configured = $ENV{WORKSHOP_RESOURCES_PATH} || '/data/nfs';
    return $configured if -d $configured;

    # Fallback for dev environments where NFS is not mounted:
    # try ~/nfs (full NFS mount), /opt/comserv/workshop_resources, then ~/workshop_resources
    for my $fallback (
        ($ENV{HOME} ? "$ENV{HOME}/nfs"                : ()),
        '/opt/comserv/workshop_resources',
        ($ENV{HOME} ? "$ENV{HOME}/workshop_resources" : ()),
    ) {
        if (-d $fallback) {
            return $fallback;
        }
        # Auto-create the fallback dir if we can write to its parent
        my $parent = $fallback =~ s{/[^/]+$}{}r;
        if (-d $parent && -w $parent) {
            mkdir($fallback, 0755) and return $fallback;
        }
    }

    return $configured;  # Return configured path even if not mounted
}

sub _site_scoped_nfs_root {
    my ($self, $c) = @_;
    my $root = $self->_nfs_root();
    return $root unless $c;

    my $admin_auth = Comserv::Util::AdminAuth->new();
    my $admin_type = $admin_auth->get_admin_type($c);
    return $root if $admin_type eq 'csc' || $admin_type eq 'special';

    my $sitename = $c->session->{SiteName} // '';
    if (lc($sitename) eq 'bmaster' && -d "$root/apis") {
        return "$root/apis";
    }
    if ($sitename && -d "$root/$sitename") {
        return "$root/$sitename";
    }
    return $root;
}

sub _can_manage_resource {
    my ($self, $c, $resource) = @_;
    my $user_id  = $c->session->{user_id} // return 0;
    my $admin_auth = Comserv::Util::AdminAuth->new();
    my $admin_type = $admin_auth->get_admin_type($c);
    return 1 if $admin_type eq 'csc' || $admin_type eq 'special';
    my $sitename = $c->session->{SiteName} // '';
    return 1 if $admin_type eq 'standard' && $sitename eq ($resource->sitename // '');
    return 1 if ($resource->uploaded_by // -1) == $user_id;
    return 0;
}

sub _can_access_resources {
    my ($self, $c) = @_;
    my $user_id = $c->session->{user_id} // return 0;
    my $admin_auth = Comserv::Util::AdminAuth->new();
    my $admin_type = $admin_auth->get_admin_type($c);
    return 1 if $admin_type && $admin_type ne 'none';
    my $roles = $c->session->{roles} || [];
    return 1 if ref $roles eq 'ARRAY' && grep { $_ eq 'workshop_leader' } @$roles;
    return 0;
}

my %MIME_MAP = (
    pdf  => 'application/pdf',
    ppt  => 'application/vnd.ms-powerpoint',
    pptx => 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    doc  => 'application/msword',
    docx => 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    xls  => 'application/vnd.ms-excel',
    xlsx => 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    jpg  => 'image/jpeg',
    jpeg => 'image/jpeg',
    png  => 'image/png',
    gif  => 'image/gif',
    svg  => 'image/svg+xml',
    mp4  => 'video/mp4',
    mp3  => 'audio/mpeg',
    zip  => 'application/zip',
    txt  => 'text/plain',
    csv  => 'text/csv',
    md   => 'text/plain',
    log  => 'text/plain',
    webm => 'video/webm',
    ogv  => 'video/ogg',
    oga  => 'audio/ogg',
    flac => 'audio/flac',
    m4a  => 'audio/mp4',
);

sub _normalized_mime {
    my ($self, $mime, $ext) = @_;
    $mime = lc($mime // '');
    return $mime if $mime =~ m{^[a-z0-9.+-]+/[a-z0-9.+-]+$};

    $ext = lc($ext // '');
    $ext =~ s/^\.//;
    return $MIME_MAP{$ext} // 'application/octet-stream';
}

sub _resolve_storage_path {
    my ($self, $c, $stored_path) = @_;
    return '' unless defined $stored_path;

    my $path = $stored_path;
    $path =~ s{\\}{/}g;
    $path =~ s{^\s+|\s+$}{}g;
    return '' unless length $path;

    my $global_root = $self->_nfs_root();
    my $scoped_root = $self->_site_scoped_nfs_root($c);

    if ($path =~ m{^/}) {
        return $path if -f $path;

        my @roots = grep { defined $_ && length $_ } ($scoped_root, $global_root);
        my @host_prefixes = grep { defined $_ && length $_ } (
            $ENV{WORKSHOP_HOST_NFS_PATH},
            '/home/shanta/nfs',
            '/data/nfs',
        );

        for my $prefix (@host_prefixes) {
            my $p = $prefix;
            $p =~ s{/*$}{};
            next unless $path eq $p || CORE::index($path, "$p/") == 0;
            my $suffix = substr($path, length($p));
            $suffix =~ s{^/}{};
            for my $root (@roots) {
                my $candidate = "$root/$suffix";
                return $candidate if -f $candidate;
            }
        }
        return '';
    }

    return '' if $path =~ m{(?:^|/)\.\.(?:/|$)};

    my $scoped_candidate = "$scoped_root/$path";
    return $scoped_candidate if -f $scoped_candidate;

    my $global_candidate = "$global_root/$path";
    return $global_candidate if -f $global_candidate;

    return '';
}

sub resources :Path('/workshop/resources') :Args(0) {
    my ($self, $c) = @_;

    unless ($c->session->{user_id}) {
        $c->flash->{error_msg} = 'Please log in to access the resource library.';
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }

    unless ($self->_can_access_resources($c)) {
        $c->flash->{error_msg} = 'Access denied. Workshop leader or admin access required.';
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }

    my $user_id    = $c->session->{user_id};
    my $sitename   = $c->session->{SiteName} // '';
    my $admin_auth = Comserv::Util::AdminAuth->new();
    my $admin_type = $admin_auth->get_admin_type($c);
    my $is_csc     = ($admin_type eq 'csc' || $admin_type eq 'special');
    my $is_admin   = $admin_type && $admin_type ne 'none';
    my $nfs_root   = $self->_nfs_root();
    my $nfs_available = -d $nfs_root;

    my $schema = $c->model('DBEncy');
    my $res_filter = lc($c->req->param('res_filter') // 'all');
    my $res_search = lc($c->req->param('res_search') // '');
    my $lib_filter = lc($c->req->param('lib_filter') // 'all');
    my $open_panel = lc($c->req->param('open_panel') // '');
    my $show_archived = $c->req->param('show_archived') ? 1 : 0;
    my %allowed_filter = map { $_ => 1 } qw(all image office pdf video audio text other link backup);
    $res_filter = 'all' unless $allowed_filter{$res_filter};
    $lib_filter = 'all' unless $allowed_filter{$lib_filter};

    # --- Workshop resources (attached to workshops) ---
    my @resources;
    my $db_error;
    eval {
        my $filter = {};
        unless ($is_csc) {
            $filter = {
                -or => [
                    { access_level => 'all_leaders' },
                    { sitename     => $sitename },
                    { uploaded_by  => $user_id },
                ]
            };
        }
        my @db_rows = $schema->resultset('WorkshopResource')->search(
            $filter,
            { order_by => { -asc => 'me.file_name' }, prefetch => 'uploader' }
        )->all;
        for my $row (@db_rows) {
            my $ext = lc($row->file_ext // '');
            if (!$ext) {
                my $nameish = $row->file_name // $row->file_path // '';
                ($ext) = ($nameish =~ /\.([^.\/\\]+)$/);
                $ext = lc($ext // '');
            }
            push @resources, {
                id           => $row->id,
                file_id      => $row->file_id,
                file_name    => $row->file_name,
                file_path    => $row->file_path // '',
                file_ext     => $ext,
                file_size    => $row->file_size // 0,
                file_type    => $row->file_type // '',
                description  => $row->description // '',
                access_level => $row->access_level // 'site_only',
                sitename     => $row->sitename // '',
                uploaded_by  => $row->uploader
                    ? ($row->uploader->first_name // $row->uploader->username // 'Unknown')
                    : 'Unknown',
                in_db        => 1,
                external_url => $row->external_url,
                workshop_id  => $row->workshop_id,
            };
        }
    };
    if ($@) {
        $db_error = $@;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'workshop', "Resource library DB error: $db_error");
    }
    my $matches_filter = sub {
        my ($row, $filter_name, $search_text) = @_;
        $filter_name ||= 'all';
        $search_text ||= '';

        my $ext = lc($row->{file_ext} // '');
        my $blob = lc(join(' ',
            $row->{file_name} // '',
            $row->{description} // '',
            $row->{file_path} // '',
            $row->{nfs_path} // '',
            $row->{sitename} // '',
        ));
        return 0 if $search_text ne '' && CORE::index($blob, $search_text) < 0;

        my $is_link  = ($row->{external_url} // '') ne '' ? 1 : 0;
        my $is_image = $ext =~ /^(?:jpg|jpeg|png|gif|svg|webp)$/ ? 1 : 0;
        my $is_office = $ext =~ /^(?:ppt|pptx|doc|docx|xls|xlsx|odt|odp|ods)$/ ? 1 : 0;
        my $is_pdf   = $ext eq 'pdf' ? 1 : 0;
        my $is_video = $ext =~ /^(?:mp4|mov|avi|webm)$/ ? 1 : 0;
        my $is_audio = $ext =~ /^(?:mp3|wav|ogg|flac|m4a)$/ ? 1 : 0;
        my $is_text  = $ext =~ /^(?:txt|csv|md|log|json|xml|yaml|yml)$/ ? 1 : 0;
        my $is_backup = CORE::index($blob, 'backup') >= 0 ? 1 : 0;
        my $is_other = (!$is_link && !$is_image && !$is_office && !$is_pdf && !$is_video && !$is_audio && !$is_text) ? 1 : 0;

        return 1 if $filter_name eq 'all';
        return $is_link if $filter_name eq 'link';
        return $is_image if $filter_name eq 'image';
        return $is_office if $filter_name eq 'office';
        return $is_pdf if $filter_name eq 'pdf';
        return $is_video if $filter_name eq 'video';
        return $is_audio if $filter_name eq 'audio';
        return $is_text if $filter_name eq 'text';
        return $is_backup if $filter_name eq 'backup';
        return $is_other if $filter_name eq 'other';
        return 1;
    };
    if ($res_filter ne 'all' || $res_search ne '') {
        @resources = grep { $matches_filter->($_, $res_filter, $res_search) } @resources;
    }

    # --- File library (files table) with pagination + search ---
    my $lib_search = $c->req->param('lib_search') // '';
    my $lib_page   = int($c->req->param('lib_page') // 1);
    $lib_page = 1 if $lib_page < 1;
    my $lib_per_page = 40;
    if ($lib_filter ne 'all') {
        $lib_page = 1;
        $lib_per_page = 5000;
    }

    my @file_library;
    my ($file_count, $file_pages, $lib_error) = (0, 0, undef);
    eval {
        my $file_filter = {};
        unless ($is_csc) {
            $file_filter = {
                -or => [
                    { 'me.access_level' => 'all_leaders' },
                    { 'me.sitename'     => $sitename },
                    { 'me.user_id'      => $user_id },
                ]
            };
        }
        my @and_terms;
        unless ($show_archived) {
            push @and_terms, { -or => [ { 'me.file_status' => { '!=' => 'archived' } }, { 'me.file_status' => undef } ] };
        }
        if ($lib_search) {
            my $like = "%$lib_search%";
            push @and_terms, {
                -or => [
                    { 'me.file_name'   => { like => $like } },
                    { 'me.description' => { like => $like } },
                    { 'me.file_format' => { like => $like } },
                    { 'me.nfs_path'    => { like => $like } },
                ]
            };
        }
        if (@and_terms) {
            my @existing = ();
            if (exists $file_filter->{-and}) {
                my $existing = $file_filter->{-and};
                @existing = ref($existing) eq 'ARRAY' ? @$existing : ($existing);
            }
            $file_filter = { %$file_filter, -and => [ @existing, @and_terms ] };
        }
        my $files_rs = $schema->resultset('File');
        $file_count  = $files_rs->search($file_filter)->count;
        $file_pages  = int(($file_count + $lib_per_page - 1) / $lib_per_page) || 1;
        $lib_page    = $file_pages if $lib_page > $file_pages;

        my @rows = $files_rs->search(
            $file_filter,
            {
                order_by => { -asc => 'me.file_name' },
                rows     => $lib_per_page,
                offset   => ($lib_page - 1) * $lib_per_page,
                columns  => [qw(id file_name file_format file_size nfs_path file_path external_url
                                access_level sitename description file_type upload_date file_status workshop_id user_id)],
            }
        )->all;

        for my $f (@rows) {
            my $ext  = lc($f->file_format // '');
            if (!$ext) {
                my $nameish = $f->file_name // $f->nfs_path // $f->file_path // '';
                ($ext) = ($nameish =~ /\.([^.\/\\]+)$/);
                $ext = lc($ext // '');
            }
            my $size = $f->file_size // 0;
            push @file_library, {
                id           => $f->id,
                file_name    => $f->file_name // '',
                file_ext     => $ext,
                file_size    => $size,
                file_type    => $f->file_type // '',
                nfs_path     => $f->nfs_path // $f->file_path // '',
                external_url => $f->external_url // '',
                access_level => $f->access_level // 'site_only',
                sitename     => $f->sitename // '',
                description  => $f->description // '',
                file_status  => $f->file_status // 'active',
                workshop_id  => $f->workshop_id,
                duplicate_count => 0,
                duplicate_path_count => 0,
            };
        }
    };
    if ($@) {
        $lib_error = $@;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'workshop', "File library DB error: $lib_error");
    }
    if ($lib_filter ne 'all') {
        @file_library = grep { $matches_filter->($_, $lib_filter, '') } @file_library;
        $file_count = scalar @file_library;
        $file_pages = int(($file_count + $lib_per_page - 1) / $lib_per_page) || 1;
    }

    my (%res_name_counts, %file_name_counts, %file_path_counts);
    for my $r (@resources) {
        my $k = lc($r->{file_name} // '');
        next unless $k ne '';
        $res_name_counts{$k}++;
    }
    for my $f (@file_library) {
        my $nk = lc($f->{file_name} // '');
        $file_name_counts{$nk}++ if $nk ne '';
        my $pk = lc($f->{nfs_path} // '');
        $file_path_counts{$pk}++ if $pk ne '';
    }
    for my $r (@resources) {
        my $k = lc($r->{file_name} // '');
        my $count = $k ne '' ? ($res_name_counts{$k} // 0) : 0;
        $r->{duplicate_count} = $count;
    }
    for my $f (@file_library) {
        my $nk = lc($f->{file_name} // '');
        my $pk = lc($f->{nfs_path} // '');
        $f->{duplicate_count} = $nk ne '' ? ($file_name_counts{$nk} // 0) : 0;
        $f->{duplicate_path_count} = $pk ne '' ? ($file_path_counts{$pk} // 0) : 0;
    }

    my $open_resources = ($open_panel eq 'resources' || $res_filter ne 'all' || $res_search ne '') ? 1 : 0;
    my $open_library   = ($open_panel eq 'files' || $lib_filter ne 'all' || $lib_search ne '') ? 1 : 0;

    # --- Workshops list for "Attach to Workshop" dropdown ---
    my @workshops;
    eval {
        @workshops = $schema->resultset('WorkShop')->search(
            {},
            { columns => ['id', 'title', 'sitename'], order_by => 'title' }
        )->all;
    };

    $c->stash(
        resources     => \@resources,
        file_library  => \@file_library,
        file_count    => $file_count,
        file_pages    => $file_pages,
        lib_page      => $lib_page,
        lib_per_page  => $lib_per_page,
        lib_search    => $lib_search,
        lib_filter    => $lib_filter,
        res_filter    => $res_filter,
        res_search    => $res_search,
        open_resources => $open_resources,
        open_library   => $open_library,
        show_archived  => $show_archived,
        lib_error     => $lib_error,
        workshops     => \@workshops,
        is_csc        => $is_csc,
        is_admin      => $is_admin,
        sitename      => $sitename,
        nfs_root      => $nfs_root,
        nfs_available => $nfs_available,
        db_error      => $db_error,
        template      => 'WorkShops/Resources.tt',
    );
}

sub resource_fs_list :Path('/workshop/resource_fs_list') :Args(0) {
    my ($self, $c) = @_;

    $c->res->header('Content-Type', 'application/json');

    unless ($c->session->{user_id}) {
        $c->stash(json => { error => 'Not authenticated' });
        $c->forward('View::JSON');
        return;
    }

    my $admin_auth = Comserv::Util::AdminAuth->new();
    my $admin_type = $admin_auth->get_admin_type($c);
    my $is_admin   = $admin_type && $admin_type ne 'none';

    unless ($is_admin) {
        $c->stash(json => { error => 'Admin access required' });
        $c->forward('View::JSON');
        return;
    }

    my $nfs_root = $self->_site_scoped_nfs_root($c);
    unless (-d $nfs_root) {
        $c->stash(json => { error => 'NFS not available', nfs_available => 0, files => [] });
        $c->forward('View::JSON');
        return;
    }

    my @files;
    my $max_files = int($c->req->param('max_files') // 3000);
    $max_files = 100 if $max_files < 100;
    $max_files = 20000 if $max_files > 20000;
    my $limit_hit = 0;
    my $scan;
    $scan = sub {
        my ($dir, $rel_prefix) = @_;
        return if $limit_hit;
        return unless opendir(my $dh, $dir);
        while (my $entry = readdir($dh)) {
            last if $limit_hit;
            next if $entry =~ /^\./;
            my $full = "$dir/$entry";
            my $rel  = $rel_prefix ? "$rel_prefix/$entry" : $entry;
            if (-d $full) {
                $scan->($full, $rel);
            } elsif (-f $full) {
                my ($ext) = ($entry =~ /\.([^.]+)$/);
                $ext = lc($ext // '');
                push @files, {
                    file_name => $entry,
                    file_path => $rel,
                    file_ext  => $ext,
                    file_size => (-s $full) + 0,
                };
                if (@files >= $max_files) {
                    $limit_hit = 1;
                    last;
                }
            }
        }
        closedir($dh);
    };
    eval { $scan->($nfs_root, '') };
    $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'workshop', "NFS scan error: $@") if $@;

    @files = sort { lc($a->{file_name}) cmp lc($b->{file_name}) } @files;

    $c->stash(json => {
        files         => \@files,
        nfs_available => 1,
        nfs_root      => $nfs_root,
        count         => scalar(@files),
        max_files     => $max_files,
        truncated     => $limit_hit ? 1 : 0,
        error         => $@ ? "$@" : undef,
    });
    $c->forward('View::JSON');
}

sub resource_upload :Path('/workshop/resource_upload') :Args(0) {
    my ($self, $c) = @_;

    unless ($c->session->{user_id}) {
        $c->flash->{error_msg} = 'Please log in to upload files.';
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }

    unless ($self->_can_access_resources($c)) {
        $c->flash->{error_msg} = 'Access denied. Workshop leader or admin access required.';
        $c->response->redirect($c->uri_for('/workshop/resources'));
        return;
    }

    unless ($c->req->method eq 'POST') {
        $c->response->redirect($c->uri_for('/workshop/resources'));
        return;
    }

    my $upload   = $c->req->upload('file');
    my $desc     = $c->req->param('description') // '';
    my $access   = $c->req->param('access_level') // 'site_only';
    my $user_id  = $c->session->{user_id};
    my $sitename = $c->session->{SiteName} // '';
    my $nfs_root = $self->_nfs_root();

    unless ($upload) {
        $c->flash->{error_msg} = 'No file selected.';
        $c->response->redirect($c->uri_for('/workshop/resources'));
        return;
    }

    unless (-d $nfs_root) {
        $c->flash->{error_msg} = "Storage directory not available ($nfs_root). Is the NFS share mounted?";
        $c->response->redirect($c->uri_for('/workshop/resources'));
        return;
    }

    my $filename = $upload->filename;
    $filename =~ s/[^A-Za-z0-9._-]/_/g;
    my ($ext) = ($filename =~ /\.([^.]+)$/);
    $ext = lc($ext // '');

    my $subdir   = $sitename || 'shared';
    my $dest_dir = "$nfs_root/$subdir";
    unless (-d $dest_dir) {
        mkdir($dest_dir, 0755) or do {
            $c->flash->{error_msg} = "Cannot create subdirectory '$subdir': $!";
            $c->response->redirect($c->uri_for('/workshop/resources'));
            return;
        };
    }

    my $dest_path = "$dest_dir/$filename";
    if (-e $dest_path) {
        my $ts = time();
        $filename  = "${ts}_$filename";
        $dest_path = "$dest_dir/$filename";
    }

    eval { $upload->copy_to($dest_path) };
    if ($@) {
        $c->flash->{error_msg} = "Failed to write file to storage: $@";
        $c->response->redirect($c->uri_for('/workshop/resources'));
        return;
    }

    my $rel_path  = "$subdir/$filename";
    my $file_size = -s $dest_path;
    my $mime_type = $MIME_MAP{$ext} // 'application/octet-stream';

    eval {
        $c->model('DBEncy')->resultset('WorkshopResource')->create({
            file_name    => $filename,
            file_path    => $rel_path,
            file_type    => $mime_type,
            file_ext     => $ext,
            file_size    => $file_size,
            description  => $desc,
            uploaded_by  => $user_id,
            sitename     => $sitename,
            access_level => $access,
        });
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'workshop', "resource_upload DB error: $@");
        $c->flash->{error_msg} = "File saved to storage but database record failed: $@. Please contact the administrator.";
    } else {
        $c->flash->{success_msg} = "File '$filename' uploaded successfully.";
    }

    $c->response->redirect($c->uri_for('/workshop/resources'));
}

sub resource_add_url :Path('/workshop/resource_add_url') :Args(0) {
    my ($self, $c) = @_;

    unless ($c->session->{user_id}) {
        $c->flash->{error_msg} = 'Please log in.';
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }

    unless ($self->_can_access_resources($c)) {
        $c->flash->{error_msg} = 'Access denied. Workshop leader or admin access required.';
        $c->response->redirect($c->uri_for('/workshop/resources'));
        return;
    }

    unless ($c->req->method eq 'POST') {
        $c->response->redirect($c->uri_for('/workshop/resources'));
        return;
    }

    my $url      = $c->req->param('external_url') // '';
    my $title    = $c->req->param('title')         // '';
    my $desc     = $c->req->param('description')   // '';
    my $access   = $c->req->param('access_level')  // 'site_only';
    my $user_id  = $c->session->{user_id};
    my $sitename = $c->session->{SiteName} // '';

    unless ($url =~ m{^https?://}i) {
        $c->flash->{error_msg} = 'URL must start with http:// or https://';
        $c->response->redirect($c->uri_for('/workshop/resources'));
        return;
    }

    unless ($title) {
        ($title) = ($url =~ m{/([^/?#]+)(?:[?#].*)?$});
        $title //= $url;
    }

    my ($ext) = ($title =~ /\.([^.]+)$/);
    $ext = lc($ext // '');

    eval {
        $c->model('DBEncy')->resultset('WorkshopResource')->create({
            file_name    => $title,
            file_path    => '',
            external_url => $url,
            file_type    => $MIME_MAP{$ext} // 'application/octet-stream',
            file_ext     => $ext,
            file_size    => 0,
            description  => $desc,
            uploaded_by  => $user_id,
            sitename     => $sitename,
            access_level => $access,
        });
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'workshop', "resource_add_url DB error: $@");
        $c->flash->{error_msg} = "Failed to save link: $@";
    } else {
        $c->flash->{success_msg} = "Link '$title' added successfully.";
    }

    $c->response->redirect($c->uri_for('/workshop/resources'));
}

sub resource_download :Path('/workshop/resource_download') :Args(1) {
    my ($self, $c, $resource_id) = @_;

    my $user_id = $c->session->{user_id};
    unless ($user_id) {
        $c->flash->{error_msg} = 'Please log in to download workshop files.';
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }

    my ($resource, $find_err);
    eval { $resource = $c->model('DBEncy::WorkshopResource')->find($resource_id) };
    $find_err = $@;

    if ($find_err || !$resource) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'workshop', "resource_download find error: " . ($find_err || 'not found'));
        $c->flash->{error_msg} = 'File not found.';
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }

    # Determine the associated workshop (if any)
    my $workshop_id = $resource->workshop_id;
    my $back_url    = $workshop_id
        ? $c->uri_for('/workshop/details', { id => $workshop_id })
        : $c->uri_for($self->action_for('index'));

    # Access: admin, workshop leader, file owner, or registered attendee
    my $admin_auth = Comserv::Util::AdminAuth->new();
    my $admin_type = $admin_auth->get_admin_type($c);
    my $is_admin   = $admin_type && $admin_type ne 'none';

    my $is_owner   = ($resource->uploaded_by && $resource->uploaded_by == $user_id);

    my $is_leader  = 0;
    my $is_registered = 0;
    if ($workshop_id) {
        my $workshop = eval { $c->model('DBEncy::WorkShop')->find($workshop_id) };
        if ($workshop) {
            $is_leader = $self->_is_workshop_leader($c, $workshop);
            my $participant = eval {
                $c->model('DBEncy')->resultset('Participant')->search({
                    workshop_id => $workshop_id,
                    user_id     => $user_id,
                    status      => { -in => ['registered', 'attended', 'waitlist'] },
                })->first;
            };
            $is_registered = 1 if $participant;
        }
    }

    unless ($is_admin || $is_owner || $is_leader || $is_registered) {
        $c->flash->{error_msg} = 'Access denied. You must be registered for this workshop to download its files.';
        $c->response->redirect($back_url);
        return;
    }

    # Serve the file
    my $full_path = $self->_resolve_storage_path($c, $resource->file_path // '');

    if ($resource->external_url) {
        $c->response->redirect($resource->external_url);
        return;
    }

    unless (-f $full_path) {
        $c->flash->{error_msg} = 'File not found on storage. It may have been moved or deleted.';
        $c->response->redirect($back_url);
        return;
    }

    my $data;
    eval {
        open my $fh, '<:raw', $full_path or die "Cannot open: $!";
        $data = do { local $/; <$fh> };
        close $fh;
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'workshop', "resource_download read error: $@");
        $c->flash->{error_msg} = "Could not read file.";
        $c->response->redirect($back_url);
        return;
    }

    my ($ext) = (($resource->file_name // '') =~ /\.([^.]+)$/);
    my $content_type = $self->_normalized_mime($resource->file_type, $ext);
    $c->response->content_type($content_type);
    $c->response->header('Content-Disposition' => 'attachment; filename="' . ($resource->file_name // 'file') . '"');
    $c->response->body($data);
}

sub resource_view :Path('/workshop/resource_view') :Args(1) {
    my ($self, $c, $resource_id) = @_;

    my $json_error = sub {
        my ($status, $msg) = @_;
        $c->response->status($status);
        $c->response->content_type('application/json');
        $msg =~ s/"/\\"/g;
        $c->response->body('{"error":"' . $msg . '"}');
    };

    unless ($c->session->{user_id}) {
        return $json_error->(403, 'Not logged in');
    }

    my ($resource, $find_err);
    eval { $resource = $c->model('DBEncy::WorkshopResource')->find($resource_id) };
    if ($@ || !$resource) {
        return $json_error->(404, $@ ? "DB error: $@" : 'Not found');
    }

    my $full_path  = $self->_resolve_storage_path($c, $resource->file_path // '');
    my ($ext) = (($resource->file_name // '') =~ /\.([^.]+)$/);
    my $mime       = $self->_normalized_mime($resource->file_type, $ext);
    my $is_image   = $mime =~ m{^image/};
    my $is_pdf     = $mime eq 'application/pdf';
    my $is_video   = $mime =~ m{^video/};
    my $is_audio   = $mime =~ m{^audio/};
    my $is_text    = $mime =~ m{^text/};
    my $want_info  = $c->req->param('info');
    my $can_inline = $is_image || $is_pdf || $is_video || $is_audio || $is_text;

    if (!$want_info && $can_inline && -f $full_path) {
        my $inline = $is_image || $is_pdf || $is_video || $is_audio || $is_text;
        eval {
            open my $fh, '<:raw', $full_path or die "Cannot open: $!";
            my $data = do { local $/; <$fh> };
            close $fh;
            $c->response->content_type($mime);
            $c->response->header('Content-Disposition' =>
                ($inline ? 'inline' : 'attachment') . '; filename="' . ($resource->file_name // 'file') . '"');
            $c->response->body($data);
        };
        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'workshop', "resource_view serve error: $@");
            return $json_error->(500, "Cannot read file: $@");
        }
        return;
    }

    eval {
        my $size_kb = int(($resource->file_size || 0) / 1024);
        my $uploader = eval { $resource->uploader };
        my $uploader_name = $uploader
            ? (join(' ', grep { $_ } ($uploader->first_name // '', $uploader->last_name // '')) || $uploader->username // 'Unknown')
            : 'Unknown';
        my $preview = $is_image ? 'image'
                    : $is_pdf   ? 'pdf'
                    : $is_video ? 'video'
                    : $is_audio ? 'audio'
                    : $is_text  ? 'text'
                    : 'none';
        my %safe = (
            file_name    => $resource->file_name    // '',
            file_type    => $mime,
            file_ext     => $resource->file_ext     // '',
            file_size_kb => $size_kb,
            description  => $resource->description  // '',
            sitename     => $resource->sitename     // '',
            access_level => $resource->access_level // '',
            uploaded_by  => $uploader_name,
            preview      => $preview,
        );
        for (grep { $_ ne 'file_size_kb' && $_ ne 'preview' } keys %safe) {
            $safe{$_} =~ s/"/\\"/g; $safe{$_} =~ s/\n/ /g;
        }
        $c->response->content_type('application/json; charset=utf-8');
        $c->response->body(
            '{"file_name":"'    . $safe{file_name}    . '",' .
            '"file_type":"'     . $safe{file_type}    . '",' .
            '"file_ext":"'      . $safe{file_ext}     . '",' .
            '"file_size_kb":'   . $safe{file_size_kb} . ','  .
            '"description":"'   . $safe{description}  . '",' .
            '"sitename":"'      . $safe{sitename}     . '",' .
            '"access_level":"'  . $safe{access_level} . '",' .
            '"uploaded_by":"'   . $safe{uploaded_by}  . '",' .
            '"preview":"'       . $safe{preview}      . '"}'
        );
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'workshop', "resource_view metadata error: $@");
        return $json_error->(500, "Error building metadata: $@");
    }
}

sub resource_delete :Path('/workshop/resource_delete') :Args(1) {
    my ($self, $c, $resource_id) = @_;

    unless ($c->session->{user_id}) {
        $c->flash->{error_msg} = 'Please log in to delete files.';
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }

    my ($resource, $find_err);
    eval { $resource = $c->model('DBEncy::WorkshopResource')->find($resource_id) };
    if ($@ || !$resource) {
        $c->flash->{error_msg} = $@ ? "Database error: $@" : 'File not found.';
        $c->response->redirect($c->uri_for('/workshop/resources'));
        return;
    }

    unless ($self->_can_manage_resource($c, $resource)) {
        $c->flash->{error_msg} = 'Access denied. Only the file owner or site admin can delete files.';
        $c->response->redirect($c->uri_for('/workshop/resources'));
        return;
    }

    my $full_path = $self->_resolve_storage_path($c, $resource->file_path // '');
    if (-f $full_path) {
        unlink($full_path) or $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'workshop', "Could not delete NFS file '$full_path': $!");
    }

    my $name = $resource->file_name;
    eval { $resource->delete };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'workshop', "resource_delete DB error: $@");
        $c->flash->{error_msg} = "Failed to remove database record: $@";
    } else {
        $c->flash->{success_msg} = "File '$name' deleted.";
    }

    $c->response->redirect($c->uri_for('/workshop/resources'));
}

sub resource_fs_download :Path('/workshop/resource_fs_download') :Args(0) {
    my ($self, $c) = @_;

    unless ($c->session->{user_id}) {
        $c->flash->{error_msg} = 'Please log in to download files.';
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }

    unless ($self->_can_access_resources($c)) {
        $c->flash->{error_msg} = 'Access denied.';
        $c->response->redirect($c->uri_for('/workshop/resources'));
        return;
    }

    my $stored_path = $c->req->param('path') // '';
    my $full_path = $self->_resolve_storage_path($c, $stored_path);
    unless (-f $full_path) {
        $c->flash->{error_msg} = 'File not found on storage.';
        $c->response->redirect($c->uri_for('/workshop/resources'));
        return;
    }

    my ($filename) = ($full_path =~ m{([^/]+)$});
    my ($ext) = ($filename =~ /\.([^.]+)$/);
    my $content_type = $self->_normalized_mime('', $ext);

    my $data;
    eval {
        open my $fh, '<:raw', $full_path or die "Cannot open: $!";
        $data = do { local $/; <$fh> };
        close $fh;
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'workshop', "resource_fs_download read error: $@");
        $c->flash->{error_msg} = "Could not read file: $@";
        $c->response->redirect($c->uri_for('/workshop/resources'));
        return;
    }

    $c->response->content_type($content_type);
    $c->response->header('Content-Disposition' => 'attachment; filename="' . $filename . '"');
    $c->response->body($data);
}

sub resource_fs_delete :Path('/workshop/resource_fs_delete') :Args(0) {
    my ($self, $c) = @_;

    unless ($c->session->{user_id}) {
        $c->flash->{error_msg} = 'Please log in.';
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }

    my $admin_auth = Comserv::Util::AdminAuth->new();
    my $admin_type = $admin_auth->get_admin_type($c);
    unless ($admin_type eq 'csc' || $admin_type eq 'special') {
        $c->flash->{error_msg} = 'Only CSC admins can delete NFS files directly.';
        $c->response->redirect($c->uri_for('/workshop/resources'));
        return;
    }

    unless ($c->req->method eq 'POST') {
        $c->response->redirect($c->uri_for('/workshop/resources'));
        return;
    }

    my $rel_path = $c->req->param('path') // '';
    $rel_path =~ s{\.\.}{}g;
    $rel_path =~ s{^/+}{};

    my $full_path = $self->_nfs_root() . '/' . $rel_path;
    my ($filename) = ($rel_path =~ m{([^/]+)$});

    if (-f $full_path) {
        unlink($full_path) or do {
            $c->flash->{error_msg} = "Could not delete '$filename': $!";
            $c->response->redirect($c->uri_for('/workshop/resources'));
            return;
        };
        $c->flash->{success_msg} = "File '$filename' deleted from NFS.";
    } else {
        $c->flash->{error_msg} = "File not found: $rel_path";
    }

    $c->response->redirect($c->uri_for('/workshop/resources'));
}

sub resource_sync :Path('/workshop/resource_sync') :Args(0) {
    my ($self, $c) = @_;

    unless ($c->session->{user_id}) {
        $c->flash->{error_msg} = 'Please log in to access the sync tool.';
        $c->response->redirect($c->uri_for('/'));
        return;
    }

    my $admin_auth = Comserv::Util::AdminAuth->new();
    my $admin_type = $admin_auth->get_admin_type($c);
    unless ($admin_type eq 'csc' || $admin_type eq 'special') {
        $c->flash->{error_msg} = 'Only CSC admins can access the NFS sync tool.';
        $c->response->redirect($c->uri_for('/workshop/resources'));
        return;
    }

    my $nfs_root      = $self->_nfs_root();
    my $nfs_available = -d $nfs_root;
    my @subdirs;

    if ($nfs_available) {
        eval {
            opendir(my $dh, $nfs_root) or die "Cannot open $nfs_root: $!";
            while (my $entry = readdir($dh)) {
                next if $entry =~ /^\./;
                push @subdirs, $entry if -d "$nfs_root/$entry";
            }
            closedir($dh);
            @subdirs = sort @subdirs;
        };
    }

    my @workshops = eval {
        $c->model('DBEncy')->resultset('WorkShop')->search(
            {},
            { columns => ['id', 'title', 'sitename'], order_by => 'title' }
        )->all;
    };

    my @sitenames;
    eval {
        my @rows = $c->model('DBEncy')->resultset('WorkShop')->search(
            {}, { columns => ['sitename'], distinct => 1, order_by => 'sitename' }
        )->all;
        @sitenames = map { $_->sitename } grep { $_->sitename } @rows;
    };

    my $files_columns = [
        { col => 'file_name',    desc => 'File name (required)',               source => 'auto' },
        { col => 'file_type',    desc => 'MIME type',                           source => 'auto' },
        { col => 'file_format',  desc => 'File extension (auto)',               source => 'auto' },
        { col => 'file_size',    desc => 'File size in bytes (auto)',           source => 'auto' },
        { col => 'nfs_path',     desc => 'Full NFS path (auto)',                source => 'auto' },
        { col => 'file_path',    desc => 'File path (same as nfs_path)',        source => 'auto' },
        { col => 'source_type',  desc => 'Source: nfs / upload / external',    source => 'form' },
        { col => 'access_level', desc => 'Access: site_only / all_leaders',    source => 'form' },
        { col => 'sitename',     desc => 'Site the file belongs to',           source => 'form' },
        { col => 'user_id',      desc => 'Owner (logged-in user)',             source => 'auto' },
        { col => 'upload_date',  desc => 'Upload timestamp (NOW)',             source => 'auto' },
        { col => 'is_duplicate', desc => 'Duplicate flag (auto-detected)',     source => 'auto' },
        { col => 'duplicate_of', desc => 'ID of original if duplicate',        source => 'auto' },
        { col => 'description',  desc => 'Human-readable description',         source => 'form' },
        { col => 'workshop_id',  desc => 'Link to a workshop (optional)',      source => 'form' },
        { col => 'site_id',      desc => 'Site ID (not currently mapped)',     source => 'n/a'  },
        { col => 'category_id',  desc => 'Category ID (not currently mapped)', source => 'n/a'  },
        { col => 'share_id',     desc => 'Share ID (not currently mapped)',    source => 'n/a'  },
        { col => 'reference_id', desc => 'Reference ID (not currently mapped)',source => 'n/a'  },
        { col => 'file_url',     desc => 'Public URL (set if external_url)',   source => 'auto' },
        { col => 'file_status',  desc => 'Status (active by default)',         source => 'form' },
        { col => 'external_url', desc => 'External URL for off-site links',    source => 'form' },
        { col => 'file_data',    desc => 'Binary blob (upload only)',          source => 'upload'},
    ];

    my $wr_columns = [
        { col => 'file_name',    desc => 'File name',                          source => 'auto' },
        { col => 'file_path',    desc => 'Full NFS path',                      source => 'auto' },
        { col => 'file_ext',     desc => 'Extension',                          source => 'auto' },
        { col => 'file_type',    desc => 'MIME type',                          source => 'auto' },
        { col => 'file_size',    desc => 'File size in bytes',                 source => 'auto' },
        { col => 'external_url', desc => 'External URL',                       source => 'form' },
        { col => 'description',  desc => 'Description',                        source => 'form' },
        { col => 'uploaded_by',  desc => 'Uploader user ID (logged-in user)',  source => 'auto' },
        { col => 'sitename',     desc => 'Site name',                          source => 'form' },
        { col => 'access_level', desc => 'Access level',                       source => 'form' },
        { col => 'file_id',      desc => 'Link to files table ID (auto)',      source => 'auto' },
        { col => 'workshop_id',  desc => 'Associated workshop (optional)',      source => 'form' },
    ];

    $c->stash(
        nfs_root      => $nfs_root,
        nfs_available => $nfs_available,
        subdirs       => \@subdirs,
        workshops     => \@workshops,
        sitenames     => \@sitenames,
        files_columns => $files_columns,
        wr_columns    => $wr_columns,
        template      => 'WorkShops/Sync.tt',
    );
}

sub resource_scan_nfs :Path('/workshop/resource_scan_nfs') :Args(0) {
    my ($self, $c) = @_;

    unless ($c->session->{user_id}) {
        $c->flash->{error_msg} = 'Please log in.';
        $c->response->redirect($c->uri_for('/'));
        return;
    }

    my $admin_auth = Comserv::Util::AdminAuth->new();
    my $admin_type = $admin_auth->get_admin_type($c);
    unless ($admin_type eq 'csc' || $admin_type eq 'special') {
        $c->flash->{error_msg} = 'Only CSC admins can run the NFS scan.';
        $c->response->redirect($c->uri_for('/workshop/resources'));
        return;
    }

    unless ($c->req->method eq 'POST') {
        $c->response->redirect($c->uri_for('/workshop/resources'));
        return;
    }

    my $nfs_root = $self->_nfs_root();
    unless (-d $nfs_root) {
        $c->flash->{error_msg} = "NFS root not available: $nfs_root";
        $c->response->redirect($c->uri_for('/workshop/resources'));
        return;
    }

    my $schema   = $c->model('DBEncy');
    my $files_rs = $schema->resultset('File');
    my $user_id   = $c->session->{user_id};
    my $sitename  = $c->session->{SiteName} // '';

    # Parameters — accept from both the old inline form and the new Sync.tt form
    my $sub_dir      = $c->req->param('scan_dir')      // 'full';
    my $max_files    = int($c->req->param('max_files') // 2000);
    my $target_table = $c->req->param('target_table')  // 'files';
    my $ext_filter   = $c->req->param('ext_filter')    // '';
    my $form_sitename= $c->req->param('sitename')       || $sitename;
    my $access_level = $c->req->param('access_level')  // 'site_only';
    my $workshop_id  = $c->req->param('workshop_id')   // undef;
    my $auto_cat     = $c->req->param('auto_categorize') // 0;
    my $file_status  = $c->req->param('file_status')   // 'active';
    my $description  = $c->req->param('description')   // '';

    $max_files  = 10000 if $max_files > 10000;
    $max_files  = 100   if $max_files < 100;
    $workshop_id = undef unless $workshop_id && $workshop_id =~ /^\d+$/;

    # Build allowed extensions lookup from comma-separated filter
    my %allowed_exts;
    if ($ext_filter) {
        for my $e (split /[\s,]+/, lc($ext_filter)) {
            $e =~ s/^\.//;
            $allowed_exts{$e} = 1 if $e;
        }
    }

    my $scan_root;
    if ($sub_dir eq 'full') {
        $scan_root = $nfs_root;
    } else {
        my $sub = "$nfs_root/$sub_dir";
        $scan_root = -d $sub ? $sub : $nfs_root;
    }

    unless (-d $scan_root) {
        $c->flash->{error_msg} = "Scan directory not available: $scan_root";
        $c->response->redirect($c->uri_for('/workshop/resource_sync'));
        return;
    }

    # Build lookup of existing nfs_path records to detect duplicates
    my %existing_files;
    eval {
        my @rows = $files_rs->search(
            { nfs_path => { '!=' => undef } },
            { columns => ['id', 'nfs_path', 'file_name', 'file_size'] }
        )->all;
        for my $r (@rows) {
            $existing_files{ $r->nfs_path } = $r;
        }
    };

    my $wr_rs = $schema->resultset('WorkshopResource');
    my %existing_wr;
    if ($target_table ne 'files') {
        eval {
            my @rows = $wr_rs->search(
                { file_path => { '!=' => undef } },
                { columns => ['id', 'file_path'] }
            )->all;
            for my $r (@rows) {
                $existing_wr{ $r->file_path } = $r;
            }
        };
    }

    my ($inserted, $skipped, $duplicates, $errors, $total_seen) = (0, 0, 0, 0, 0);
    my $limit_hit = 0;

    my $scan;
    $scan = sub {
        my ($dir) = @_;
        return if $limit_hit;
        return unless opendir(my $dh, $dir);
        while (my $entry = readdir($dh)) {
            last if $limit_hit;
            next if $entry =~ /^\./;
            my $full = "$dir/$entry";
            if (-d $full) {
                $scan->($full);
            } elsif (-f $full) {
                $total_seen++;
                if ($total_seen > $max_files) {
                    $limit_hit = 1;
                    last;
                }
                my ($ext) = ($entry =~ /\.([^.]+)$/);
                $ext = lc($ext // '');

                # Apply extension filter if set
                next if %allowed_exts && !$allowed_exts{$ext};

                my $size = -s $full;
                my $mime = $MIME_MAP{$ext} // 'application/octet-stream';

                # Auto-categorize by directory name if requested
                my $cat_desc = $description;
                if ($auto_cat && !$cat_desc) {
                    my ($dir_part) = ($full =~ m{$nfs_root/([^/]+)/});
                    $cat_desc = $dir_part // '';
                }

                # If sitename is not provided, infer it from top-level NFS directory.
                # This supports a root layout where each directory name matches SiteName.
                my $sitename_for_file = $form_sitename;
                if (!defined $sitename_for_file || $sitename_for_file eq '') {
                    my $relative = $full;
                    $relative =~ s{^\Q$nfs_root\E/?}{};
                    my ($top) = split('/', $relative, 2);
                    $sitename_for_file = $top || $sitename || 'CSC';
                }

                if ($target_table eq 'files' || $target_table eq 'both') {
                    if ($existing_files{$full}) {
                        $skipped++;
                    } else {
                        my $dup_check;
                        eval {
                            $dup_check = $files_rs->search(
                                { file_name => $entry, file_size => $size, nfs_path => { '!=' => $full } },
                                { rows => 1 }
                            )->first;
                        };
                        my $new_file_id;
                        eval {
                            my $rec = $files_rs->create({
                                file_name    => $entry,
                                nfs_path     => $full,
                                file_path    => $full,
                                file_type    => $mime,
                                file_format  => $ext,
                                file_size    => $size,
                                source_type  => 'nfs',
                                sitename     => $sitename_for_file,
                                access_level => $access_level,
                                user_id      => $user_id,
                                workshop_id  => $workshop_id,
                                file_status  => $file_status,
                                description  => $cat_desc || undef,
                                is_duplicate => ($dup_check ? 1 : 0),
                                duplicate_of => ($dup_check ? $dup_check->id : undef),
                                upload_date  => \'NOW()',
                            });
                            $new_file_id = $rec->id;
                            $dup_check ? $duplicates++ : $inserted++;
                            $existing_files{$full} = $rec;
                        };
                        if ($@) {
                            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'workshop', "resource_scan_nfs files insert error for $full: $@");
                            $errors++;
                        }
                    }
                }

                if ($target_table eq 'workshop_resource' || $target_table eq 'both') {
                    next if $existing_wr{$full};
                    my $linked_file_id = $existing_files{$full} ? $existing_files{$full}->id : undef;
                    eval {
                        $wr_rs->create({
                            file_name    => $entry,
                            file_path    => $full,
                            file_ext     => $ext,
                            file_type    => $mime,
                            file_size    => $size,
                            sitename     => $sitename_for_file,
                            access_level => $access_level,
                            uploaded_by  => $user_id,
                            workshop_id  => $workshop_id,
                            description  => $cat_desc || undef,
                            file_id      => $linked_file_id,
                        });
                        $inserted++ if $target_table eq 'workshop_resource';
                    };
                    if ($@) {
                        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'workshop', "resource_scan_nfs workshop_resource insert error for $full: $@");
                        $errors++ if $target_table eq 'workshop_resource';
                    }
                }
            }
        }
        closedir($dh);
    };

    eval { $scan->($scan_root) };
    $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'workshop', "NFS scan failed: $@") if $@;

    my $target_label = $target_table eq 'both' ? 'files + workshop_resource' : $target_table;
    my $msg = "NFS scan of '$scan_root' → $target_label: $inserted new, $skipped already in DB, $duplicates duplicates, $errors errors.";
    $msg   .= " (Limit of $max_files files reached — run again to continue.)" if $limit_hit;
    $c->flash->{success_msg} = $msg;
    $c->response->redirect($c->uri_for('/workshop/resource_sync'));
}

sub file_view :Path('/workshop/file_view') :Args(1) {
    my ($self, $c, $file_id) = @_;

    unless ($c->session->{user_id}) {
        $c->response->status(403);
        $c->response->body('Not authenticated');
        return;
    }

    my $file = eval { $c->model('DBEncy')->resultset('File')->find($file_id) };
    unless ($file) {
        $c->response->status(404);
        $c->response->body('File not found');
        return;
    }

    my $want_info = $c->req->param('info');

    if ($want_info) {
        my $mime_i = $file->file_type // '';
        my $kb     = int(($file->file_size || 0) / 1024);
        my $preview = $mime_i =~ m{^image/}  ? 'image'
                    : $mime_i eq 'application/pdf' ? 'pdf'
                    : $mime_i =~ m{^video/}  ? 'video'
                    : $mime_i =~ m{^audio/}  ? 'audio'
                    : $mime_i =~ m{^text/}   ? 'text'
                    : 'none';
        (my $safe_name = $file->file_name   // '') =~ s/"/\\"/g;
        (my $safe_desc = $file->description // '') =~ s/"/\\"/g;
        (my $safe_mime = $mime_i)                  =~ s/"/\\"/g;
        $c->response->content_type('application/json; charset=utf-8');
        $c->response->body('{"file_name":"' . $safe_name . '","file_type":"' . $safe_mime . '","file_ext":"' . ($file->file_format // '') . '","file_size_kb":' . $kb . ',"description":"' . $safe_desc . '","sitename":"' . ($file->sitename // '') . '","preview":"' . $preview . '"}');
        return;
    }

    my $mime     = $self->_normalized_mime($file->file_type, $file->file_format);
    my $is_image = $mime =~ m{^image/};
    my $is_pdf   = $mime eq 'application/pdf';
    my $is_text  = $mime =~ m{^text/};
    my $is_av    = $mime =~ m{^(audio|video)/};
    my $inline   = $is_image || $is_pdf || $is_text || $is_av;

    if ($file->file_data) {
        $c->response->content_type($mime);
        $c->response->header('Content-Disposition' => ($inline ? 'inline' : 'attachment') . '; filename="' . ($file->file_name // 'file') . '"');
        $c->response->body($file->file_data);
        return;
    }

    my $path = $self->_resolve_storage_path($c, ($file->nfs_path || $file->file_path || ''));
    unless ($path && -f $path) {
        $c->response->status(404);
        $c->response->body('File not found on storage');
        return;
    }

    eval {
        open my $fh, '<:raw', $path or die "Cannot open: $!";
        my $data = do { local $/; <$fh> };
        close $fh;
        $c->response->content_type($mime);
        $c->response->header('Content-Disposition' => ($inline ? 'inline' : 'attachment') . '; filename="' . ($file->file_name // 'file') . '"');
        $c->response->body($data);
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'workshop', "file_view read error: $@");
        $c->response->status(500);
        $c->response->body('Could not read file');
    }
}

sub resource_attach :Path('/workshop/resource_attach') :Args(0) {
    my ($self, $c) = @_;

    unless ($c->session->{user_id}) {
        $c->flash->{error_msg} = 'Please log in.';
        $c->response->redirect($c->uri_for('/'));
        return;
    }

    unless ($self->_can_access_resources($c)) {
        $c->flash->{error_msg} = 'Access denied. Workshop leader or admin access required.';
        $c->response->redirect($c->uri_for('/workshop/resources'));
        return;
    }

    unless ($c->req->method eq 'POST') {
        $c->response->redirect($c->uri_for('/workshop/resources'));
        return;
    }

    my $file_id     = $c->req->param('file_id');
    my $workshop_id = $c->req->param('workshop_id');
    my $access_level= $c->req->param('access_level') // 'site_only';
    my $user_id     = $c->session->{user_id};
    my $sitename    = $c->session->{SiteName} // '';

    unless ($file_id && $file_id =~ /^\d+$/) {
        $c->flash->{error_msg} = 'Invalid file ID.';
        $c->response->redirect($c->uri_for('/workshop/resources'));
        return;
    }

    my $schema = $c->model('DBEncy');

    # Check file exists
    my $file = eval { $schema->resultset('File')->find($file_id) };
    unless ($file) {
        $c->flash->{error_msg} = "File #$file_id not found.";
        $c->response->redirect($c->uri_for('/workshop/resources'));
        return;
    }

    # Check not already attached to this workshop
    my $already = eval {
        my $filter = { file_id => $file_id };
        $filter->{workshop_id} = $workshop_id if $workshop_id && $workshop_id =~ /^\d+$/;
        $schema->resultset('WorkshopResource')->search($filter, { rows => 1 })->first;
    };
    if ($already) {
        $c->flash->{error_msg} = 'This file is already attached' . ($workshop_id ? ' to that workshop.' : '.');
        $c->response->redirect($c->uri_for('/workshop/resources'));
        return;
    }

    my $ext  = lc($file->file_format // ($file->file_name =~ /\.([^.]+)$/ ? $1 : ''));
    my $mime = $file->file_type // 'application/octet-stream';

    eval {
        $schema->resultset('WorkshopResource')->create({
            file_name    => $file->file_name,
            file_path    => $file->nfs_path // $file->file_path // '',
            file_ext     => $ext,
            file_type    => $mime,
            file_size    => $file->file_size,
            sitename     => $file->sitename // $sitename,
            access_level => $access_level,
            uploaded_by  => $user_id,
            workshop_id  => ($workshop_id && $workshop_id =~ /^\d+$/) ? $workshop_id : undef,
            description  => $file->description,
            file_id      => $file_id,
        });
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'workshop', "resource_attach error: $@");
        $c->flash->{error_msg} = 'Failed to attach file: ' . (split /\n/, $@)[0];
    } else {
        my $ws_label = ($workshop_id && $workshop_id =~ /^\d+$/) ? " to workshop #$workshop_id" : '';
        $c->flash->{success_msg} = "File '" . $file->file_name . "' attached$ws_label successfully.";
    }

    $c->response->redirect($c->uri_for('/workshop/resources'));
}

sub file_update :Path('/workshop/file_update') :Args(0) {
    my ($self, $c) = @_;

    unless ($c->session->{user_id}) {
        $c->flash->{error_msg} = 'Please log in.';
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }

    unless ($self->_can_access_resources($c)) {
        $c->flash->{error_msg} = 'Access denied.';
        $c->response->redirect($c->uri_for('/workshop/resources'));
        return;
    }

    unless ($c->req->method eq 'POST') {
        $c->response->redirect($c->uri_for('/workshop/resources'));
        return;
    }

    my $file_id = $c->req->param('file_id');
    unless ($file_id && $file_id =~ /^\d+$/) {
        $c->flash->{error_msg} = 'Invalid file ID.';
        $c->response->redirect($c->uri_for('/workshop/resources'));
        return;
    }

    my $schema = $c->model('DBEncy');
    my $file = eval { $schema->resultset('File')->find($file_id) };
    unless ($file) {
        $c->flash->{error_msg} = 'File record not found.';
        $c->response->redirect($c->uri_for('/workshop/resources'));
        return;
    }

    my $admin_auth = Comserv::Util::AdminAuth->new();
    my $admin_type = $admin_auth->get_admin_type($c);
    my $is_csc_admin = ($admin_type eq 'csc' || $admin_type eq 'special');
    my $is_site_admin = ($admin_type eq 'standard' && ($c->session->{SiteName} // '') eq ($file->sitename // ''));
    my $is_owner = (($file->user_id // 0) == ($c->session->{user_id} // -1));
    unless ($is_csc_admin || $is_site_admin || $is_owner) {
        $c->flash->{error_msg} = 'Access denied for editing this file.';
        $c->response->redirect($c->uri_for('/workshop/resources'));
        return;
    }

    my $new_name = $c->req->param('file_name');
    $new_name = $file->file_name unless defined $new_name;
    $new_name =~ s/^\s+|\s+$//g;
    $new_name =~ s{[/\\]}{}g;
    $new_name = $file->file_name unless length $new_name;

    my $description = $c->req->param('description');
    $description = '' unless defined $description;
    $description =~ s/^\s+|\s+$//g;

    my $access_level = $c->req->param('access_level') // ($file->access_level // 'site_only');
    my %allowed_access = map { $_ => 1 } qw(site_only all_leaders workshop_specific);
    $access_level = 'site_only' unless $allowed_access{$access_level};

    my $sitename = $c->req->param('sitename');
    $sitename = $file->sitename unless defined $sitename;
    $sitename =~ s/^\s+|\s+$//g;
    $sitename = $file->sitename unless length $sitename;
    $sitename = $file->sitename unless $is_csc_admin || $is_site_admin;

    my $file_status = $c->req->param('file_status') // ($file->file_status // 'active');
    my %allowed_status = map { $_ => 1 } qw(active pending archived);
    $file_status = 'active' unless $allowed_status{$file_status};

    my $workshop_action = $c->req->param('workshop_action') // 'keep';
    $workshop_action = 'keep' unless $workshop_action =~ /^(keep|attach|detach)$/;
    my $workshop_id = $c->req->param('workshop_id');
    $workshop_id = undef unless defined $workshop_id && $workshop_id =~ /^\d+$/;

    my $ok = eval {
        $file->update({
            file_name    => $new_name,
            description  => $description,
            access_level => $access_level,
            sitename     => $sitename,
            file_status  => $file_status,
        });

        my $wr_rs = $schema->resultset('WorkshopResource');
        my $ext = lc($file->file_format // ($new_name =~ /\.([^.]+)$/ ? $1 : ''));
        my $mime = $self->_normalized_mime($file->file_type, $ext);

        # Keep workshop_resource metadata aligned with edited file record.
        $wr_rs->search({ file_id => $file_id })->update({
            file_name    => $new_name,
            sitename     => $sitename,
            access_level => $access_level,
            description  => $description,
            file_ext     => $ext,
            file_type    => $mime,
        });

        if ($workshop_action eq 'detach') {
            my $filter = { file_id => $file_id };
            $filter->{workshop_id} = $workshop_id if defined $workshop_id;
            $wr_rs->search($filter)->delete;
        } elsif ($workshop_action eq 'attach' && defined $workshop_id) {
            my $existing = $wr_rs->search(
                { file_id => $file_id, workshop_id => $workshop_id },
                { rows => 1 }
            )->first;
            unless ($existing) {
                $wr_rs->create({
                    file_name    => $new_name,
                    file_path    => $file->nfs_path // $file->file_path // '',
                    file_ext     => $ext,
                    file_type    => $mime,
                    file_size    => $file->file_size,
                    sitename     => $sitename,
                    access_level => $access_level,
                    uploaded_by  => $c->session->{user_id},
                    workshop_id  => $workshop_id,
                    description  => $description,
                    file_id      => $file_id,
                });
            }
            $file->update({ workshop_id => $workshop_id }) unless ($file->workshop_id // '') eq "$workshop_id";
        }
        1;
    };

    if (!$ok || $@) {
        my $err = $@ || 'unknown error';
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'workshop', "file_update failed for file_id=$file_id: $err");
        $c->flash->{error_msg} = 'Failed to update file record.';
    } else {
        $c->flash->{success_msg} = "Updated file '$new_name'.";
    }

    $c->response->redirect($c->uri_for('/workshop/resources'));
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
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'workshop', "Failed to create content: $@");
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
            content => $content_record,
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
            content => $content_record,
            form_data => $params,
            template => 'WorkShops/AddContent.tt',
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
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'workshop', "Failed to update content: $@");
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
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'workshop', "Failed to delete content: $@");
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
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'workshop', "Failed to update sort_order for content $content_id: $@");
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

    my @workshop_templates = $c->model('DBEncy::WorkshopMailTemplate')->search(
        { workshop_id => $id, is_active => 1 },
        { order_by => { -asc => 'name' } }
    )->all;
    my @global_templates = $c->model('DBEncy::WorkshopMailTemplate')->search(
        { workshop_id => undef, is_active => 1 },
        { order_by => { -asc => 'name' } }
    )->all;

    
    # Fetch all other workshops this leader owns (or all workshops for CSC admin)
    my $user_id    = $c->session->{user_id};
    my $admin_auth = Comserv::Util::AdminAuth->new();
    my $admin_type = $admin_auth->get_admin_type($c);
    my @leader_workshops_raw;
    if ($admin_type eq 'CSC') {
        @leader_workshops_raw = $c->model('DBEncy::WorkShop')->search(
            { id => { '!=' => $id } },
            { order_by => { -asc => 'title' } }
        )->all;
    } elsif ($user_id) {
        @leader_workshops_raw = $c->model('DBEncy::WorkShop')->search(
            { created_by => $user_id, id => { '!=' => $id } },
            { order_by => { -asc => 'title' } }
        )->all;
    }

    # Pre-compute participant counts — TT cannot call .search({}) on DBIC relationships
    my @leader_workshops = map {
        my $ws = $_;
        my $cnt = $c->model('DBEncy::Participant')->search({
            workshop_id => $ws->id,
            status      => 'registered',
        })->count;
        { workshop => $ws, count => $cnt }
    } @leader_workshops_raw;

    leader_workshops   => \@leader_workshops,
        template           => 'WorkShops/ComposeEmail.tt',
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

    # Collect all workshop IDs to include (primary + any extras checked)
    my @extra_ids;
    if (ref $params->{extra_workshop_ids} eq 'ARRAY') {
        @extra_ids = @{ $params->{extra_workshop_ids} };
    } elsif ($params->{extra_workshop_ids}) {
        @extra_ids = ($params->{extra_workshop_ids});
    }
    my @all_workshop_ids = ($id, @extra_ids);
    
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
            workshop_id => \@all_workshop_ids,
            'me.status' => 'registered'
        },
        { prefetch => 'user' }
    )->all;
    
    unless (@registered_participants) {
        $c->flash->{error_msg} = 'No registered participants to email.';
        $c->response->redirect($c->uri_for($self->action_for('participants'), [$id]));
        return;
    }
    
    my @recipient_emails;
    my %seen_emails;
    for my $participant (@registered_participants) {
        my $email = $participant->email;
        next unless $email && $email =~ /\@/;
        next if $seen_emails{lc $email}++;
        push @recipient_emails, $email;
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
    
    my $formatted_date = do {
        my $d = $workshop->date;
        $d ? (ref($d) && $d->can('strftime') ? $d->strftime('%Y-%m-%d') : do { (my $s = "$d") =~ s/ .*$//; $s }) : 'TBD';
    };
    my $formatted_time = do {
        my $t = $workshop->time;
        $t ? (ref($t) && $t->can('strftime') ? $t->strftime('%H:%M') : substr("$t", 0, 5)) : 'TBD';
    };
    my $formatted_end_time = $workshop->end_time || '';

    # Build leader name for [[leader.name]] placeholder
    my $leader_name = '';
    if ($workshop->created_by) {
        my $leader_user = $c->model('DBEncy::User')->find($workshop->created_by);
        if ($leader_user) {
            $leader_name = $leader_user->first_name || $leader_user->username || '';
            $leader_name .= ' ' . $leader_user->last_name if $leader_user->last_name;
            $leader_name =~ s/^\s+|\s+$//g;
        }
    }
    $leader_name ||= $workshop->instructor || '';

    # Process workshop-level [[placeholders]] in subject (same for all recipients)
    (my $processed_subject = $subject) =~ s/\[\[workshop\.title\]\]/${\($workshop->title || '')}/g;
    $processed_subject =~ s/\[\[workshop\.date\]\]/$formatted_date/g;
    $processed_subject =~ s/\[\[workshop\.location\]\]/${\($workshop->location || '')}/g;
    $processed_subject =~ s/\[\[leader\.name\]\]/$leader_name/g;

    my $sent_count = 0;
    my $failed_count = 0;
    my @failed_emails;
    my %sent_to;

    for my $participant (@registered_participants) {
        my $email = $participant->email;
        next unless $email && $email =~ /\@/;
        next if $sent_to{lc $email}++;
        
        my $user_name = '';
        if ($participant->user) {
            $user_name = $participant->user->first_name || $participant->user->username || '';
            if ($participant->user->last_name) {
                $user_name .= ' ' . $participant->user->last_name;
            }
        } elsif ($participant->name) {
            $user_name = $participant->name;
        }
        $user_name =~ s/^\s+|\s+$//g if $user_name;
        my $first_name = (split /\s+/, $user_name)[0] || $user_name;

        # Process per-participant [[placeholders]] in body
        my $processed_body = $body;
        $processed_body =~ s/\[\[participant\.name\]\]/$user_name/g;
        $processed_body =~ s/\[\[participant\.first_name\]\]/$first_name/g;
        $processed_body =~ s/\[\[workshop\.title\]\]/${\($workshop->title || '')}/g;
        $processed_body =~ s/\[\[workshop\.date\]\]/$formatted_date/g;
        $processed_body =~ s/\[\[workshop\.time\]\]/$formatted_time/g;
        $processed_body =~ s/\[\[workshop\.location\]\]/${\($workshop->location || '')}/g;
        $processed_body =~ s/\[\[workshop\.instructor\]\]/${\($workshop->instructor || '')}/g;
        $processed_body =~ s/\[\[leader\.name\]\]/$leader_name/g;
        $processed_body =~ s/\[\[workshop\.url\]\]/$full_url/g;

        eval {
            $c->stash->{email} = {
                to       => $email,
                from     => $from_address,
                reply_to => $reply_to,
                subject  => $processed_subject,
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
                    message_body => $processed_body,
                },
            };
            
            $c->forward($c->view('Email::Template'));
            $sent_count++;
        };
        
        if ($@) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'workshop', "Failed to send email to $email: $@");
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
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'workshop', "Failed to record email in database: $@");
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

sub _send_error_notification {
    my ($self, $c, $error_details) = @_;
    
    # Get site admin email from config or database
    my $admin_email = $c->config->{admin_email} || 'admin@' . lc($error_details->{site}) . '.ca';
    
    # Get site from database to get proper admin email
    my $site = $c->model('DBEncy::Site')->search({ name => $error_details->{site} })->first;
    if ($site && $site->admin_email) {
        $admin_email = $site->admin_email;
    }
    
    # Format error details for email
    my $error_report = sprintf(
        "Error Type: %s\n\nError Message:\n%s\n\nUser Details:\n- User ID: %s\n- Username: %s\n- Site: %s\n\nTimestamp: %s\n\nRequest URI: %s\n\n",
        $error_details->{error_type} || 'Unknown Error',
        $error_details->{error_message} || 'No error message provided',
        $error_details->{user_id} || 'N/A',
        $error_details->{username} || 'N/A',
        $error_details->{site} || 'N/A',
        DateTime->now->strftime('%Y-%m-%d %H:%M:%S'),
        $c->req->uri || 'N/A'
    );
    
    # Add form data if provided
    if ($error_details->{form_data}) {
        $error_report .= "Form Data:\n";
        for my $key (sort keys %{$error_details->{form_data}}) {
            my $value = $error_details->{form_data}->{$key} || '';
            # Truncate long values
            $value = substr($value, 0, 200) . '...' if length($value) > 200;
            $error_report .= "  $key: $value\n";
        }
    }
    
    # Send email notification
    eval {
        $c->stash->{email} = {
            to       => $admin_email,
            from     => $c->config->{system_email} || 'noreply@comserv.ca',
            subject  => '[Workshop System Error] ' . $error_details->{error_type},
            body     => $error_report,
        };
        
        $c->forward($c->view('Email'));
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'workshop', "Error notification sent to admin: $admin_email");
    };
    
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'workshop', "Failed to send error notification email: $@");
    }
}


sub mail_templates :Local :Args(1) {
    my ($self, $c, $id) = @_;

    my $workshop = $c->model('DBEncy::WorkShop')->find($id);
    unless ($workshop) {
        $c->flash->{error_msg} = 'Workshop not found.';
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }
    unless ($self->_check_workshop_access($c, $workshop, 'leader')) {
        $c->flash->{error_msg} = 'Access denied.';
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }

    my @workshop_templates = $c->model('DBEncy::WorkshopMailTemplate')->search(
        { workshop_id => $id, is_active => 1 },
        { order_by => { -asc => 'name' } }
    )->all;

    my @global_templates = $c->model('DBEncy::WorkshopMailTemplate')->search(
        { workshop_id => undef, is_active => 1 },
        { order_by => { -asc => 'name' } }
    )->all;

    $c->stash(
        workshop          => $workshop,
        workshop_templates => \@workshop_templates,
        global_templates  => \@global_templates,
        template          => 'WorkShops/MailTemplates.tt',
    );
}

sub add_mail_template :Local :Args(1) {
    my ($self, $c, $id) = @_;

    my $workshop = $c->model('DBEncy::WorkShop')->find($id);
    unless ($workshop) {
        $c->flash->{error_msg} = 'Workshop not found.';
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }
    unless ($self->_check_workshop_access($c, $workshop, 'leader')) {
        $c->flash->{error_msg} = 'Access denied.';
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }

    $c->stash(
        workshop => $workshop,
        template => 'WorkShops/AddMailTemplate.tt',
    );
}

sub save_mail_template :Local :Args(1) {
    my ($self, $c, $id) = @_;

    my $workshop = $c->model('DBEncy::WorkShop')->find($id);
    unless ($workshop) {
        $c->flash->{error_msg} = 'Workshop not found.';
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }
    unless ($self->_check_workshop_access($c, $workshop, 'leader')) {
        $c->flash->{error_msg} = 'Access denied.';
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }

    my $params = $c->request->body_parameters;
    my $name          = $params->{name} || '';
    my $subject       = $params->{subject} || '';
    my $body_text     = $params->{body_text} || '';
    my $body_html     = $params->{body_html} || '';
    my $template_type = $params->{template_type} || 'custom';
    my $is_global     = $params->{is_global} ? 1 : 0;
    my $template_id   = $params->{template_id} || '';

    unless ($name && $subject && $body_text) {
        $c->stash(
            workshop      => $workshop,
            error_msg     => 'Name, subject, and body are required.',
            form_data     => $params,
            template      => 'WorkShops/AddMailTemplate.tt',
        );
        $c->forward($c->view('TT'));
        return;
    }

    my $err;
    eval {
        my $workshop_id = $is_global ? undef : $id;

        if ($template_id) {
            my $tmpl = $c->model('DBEncy::WorkshopMailTemplate')->find($template_id);
            if ($tmpl) {
                $tmpl->update({
                    name          => $name,
                    subject       => $subject,
                    body_text     => $body_text,
                    body_html     => $body_html,
                    template_type => $template_type,
                    workshop_id   => $workshop_id,
                });
            }
        } else {
            $c->model('DBEncy::WorkshopMailTemplate')->create({
                name          => $name,
                subject       => $subject,
                body_text     => $body_text,
                body_html     => $body_html,
                template_type => $template_type,
                workshop_id   => $workshop_id,
                created_by    => $c->session->{user_id},
                is_active     => 1,
            });
        }
    };
    $err = "$@" if $@;

    if ($err) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'save_mail_template',
            "Error saving mail template: $err");
        $c->stash(
            workshop  => $workshop,
            error_msg => "Error saving template: $err",
            form_data => $params,
            template  => 'WorkShops/AddMailTemplate.tt',
        );
        $c->forward($c->view('TT'));
        return;
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'save_mail_template',
        "Mail template '$name' saved for workshop $id");
    $c->flash->{success_msg} = "Template '$name' saved successfully.";
    $c->response->redirect($c->uri_for($self->action_for('mail_templates'), [$id]));
}

sub edit_mail_template :Local :Args(2) {
    my ($self, $c, $workshop_id, $template_id) = @_;

    my $workshop = $c->model('DBEncy::WorkShop')->find($workshop_id);
    unless ($workshop) {
        $c->flash->{error_msg} = 'Workshop not found.';
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }
    unless ($self->_check_workshop_access($c, $workshop, 'leader')) {
        $c->flash->{error_msg} = 'Access denied.';
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }

    my $tmpl = $c->model('DBEncy::WorkshopMailTemplate')->find($template_id);
    unless ($tmpl) {
        $c->flash->{error_msg} = 'Template not found.';
        $c->response->redirect($c->uri_for($self->action_for('mail_templates'), [$workshop_id]));
        return;
    }

    $c->stash(
        workshop     => $workshop,
        mail_template => $tmpl,
        template     => 'WorkShops/AddMailTemplate.tt',
    );
}

sub delete_mail_template :Local :Args(2) {
    my ($self, $c, $workshop_id, $template_id) = @_;

    my $workshop = $c->model('DBEncy::WorkShop')->find($workshop_id);
    unless ($workshop) {
        $c->flash->{error_msg} = 'Workshop not found.';
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }
    unless ($self->_check_workshop_access($c, $workshop, 'leader')) {
        $c->flash->{error_msg} = 'Access denied.';
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }

    my $err;
    eval {
        my $tmpl = $c->model('DBEncy::WorkshopMailTemplate')->find($template_id);
        $tmpl->update({ is_active => 0 }) if $tmpl;
    };
    $err = "$@" if $@;

    if ($err) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'delete_mail_template',
            "Error deleting template $template_id: $err");
        $c->flash->{error_msg} = "Error deleting template: $err";
    } else {
        $c->flash->{success_msg} = 'Template deleted.';
    }
    $c->response->redirect($c->uri_for($self->action_for('mail_templates'), [$workshop_id]));
}

__PACKAGE__->meta->make_immutable;

1;
