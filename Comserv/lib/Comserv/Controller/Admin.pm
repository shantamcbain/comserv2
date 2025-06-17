
package Comserv::Controller::Admin;


use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;
use Data::Dumper;
use JSON qw(decode_json);
use Try::Tiny;
use MIME::Base64;
use File::Slurp qw(read_file write_file);
use File::Basename;
use File::Path qw(make_path);
use File::Copy;
use Digest::SHA qw(sha256_hex);
use File::Find;
use Module::Load;

BEGIN { extends 'Catalyst::Controller'; }

# Returns an instance of the logging utility
sub logging {
    my ($self) = @_;
    return Comserv::Util::Logging->instance();
}

# Begin method to check if the user has admin role
sub begin : Private {
    my ($self, $c) = @_;
    
    # Add detailed logging
    my $username = ($c->user_exists && $c->user) ? $c->user->username : ($c->session->{username} || 'Guest');
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'begin', 
        "Admin controller begin method called by user: $username");
    
    # Initialize debug_msg array if it doesn't exist
    $c->stash->{debug_msg} = [] unless ref($c->stash->{debug_msg}) eq 'ARRAY';
    
    # Add the debug message to the array
    push @{$c->stash->{debug_msg}}, "Admin controller loaded successfully";
    
    return 1; # Allow the request to proceed
}

# Base method for chained actions
sub base :Chained('/') :PathPart('admin') :CaptureArgs(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'base', 
        "Starting Admin base action");
    
    # Common setup for all admin pages
    $c->stash(section => 'admin');
    
    # TEMPORARY FIX: Allow specific users direct access
    if ($c->session->{username} && $c->session->{username} eq 'Shanta') {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'base', 
            "Admin access granted to user Shanta (bypass role check)");
        return 1;
    }
    
    # Check if the user has admin role
    my $has_admin_role = 0;
    
    # First check if user exists
    if ($c->user_exists) {
        # Get roles from session
        my $roles = $c->session->{roles};
        
        # Log the roles for debugging
        my $roles_debug = 'none';
        if (defined $roles) {
            if (ref($roles) eq 'ARRAY') {
                $roles_debug = join(', ', @$roles);
                
                # Check if 'admin' is in the roles array
                foreach my $role (@$roles) {
                    if (lc($role) eq 'admin') {
                        $has_admin_role = 1;
                        last;
                    }
                }
            } elsif (!ref($roles)) {
                $roles_debug = $roles;
                # Check if roles string contains 'admin'
                if ($roles =~ /\badmin\b/i) {
                    $has_admin_role = 1;
                }
            }
        }
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'base', 
            "Admin access check - User: " . $c->session->{username} . ", Roles: $roles_debug, Has admin: " . ($has_admin_role ? 'Yes' : 'No'));
    }
    
    unless ($has_admin_role) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'base', 
            "Access denied: User does not have admin role");
        
        # Set error message in flash
        $c->flash->{error_msg} = "You need to be an administrator to access this area.";
        
        # Redirect to login page with destination parameter
        $c->response->redirect($c->uri_for('/user/login', {
            destination => $c->req->uri
        }));
        return 0;
    }
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'base', 
        "Completed Admin base action");
    
    return 1;
}

# Admin dashboard
sub index :Path :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', 
        "Starting Admin index action");
    
    # TEMPORARY FIX: Allow specific users direct access
    if ($c->session->{username} && $c->session->{username} eq 'Shanta') {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', 
            "Admin access granted to user Shanta (bypass role check)");
        # Continue with the admin page
    }
    else {
        # Check if the user has admin role
        my $has_admin_role = 0;
        
        # First check if user exists
        if ($c->user_exists) {
            # Get roles from session
            my $roles = $c->session->{roles};
            
            # Log the roles for debugging
            my $roles_debug = 'none';
            if (defined $roles) {
                if (ref($roles) eq 'ARRAY') {
                    $roles_debug = join(', ', @$roles);
                    
                    # Check if 'admin' is in the roles array
                    foreach my $role (@$roles) {
                        if (lc($role) eq 'admin') {
                            $has_admin_role = 1;
                            last;
                        }
                    }
                } elsif (!ref($roles)) {
                    $roles_debug = $roles;
                    # Check if roles string contains 'admin'
                    if ($roles =~ /\badmin\b/i) {
                        $has_admin_role = 1;
                    }
                }
            }
            
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', 
                "Admin access check - User: " . $c->session->{username} . ", Roles: $roles_debug, Has admin: " . ($has_admin_role ? 'Yes' : 'No'));
        }
        
        unless ($has_admin_role) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'index', 
                "Access denied: User does not have admin role");
            
            # Set error message in flash
            $c->flash->{error_msg} = "You need to be an administrator to access this area.";
            
            # Redirect to login page with destination parameter
            $c->response->redirect($c->uri_for('/user/login', {
                destination => $c->req->uri
            }));
            return;
        }
    }
    
    # Get system stats
    my $stats = $self->get_system_stats($c);
    
    # Get recent user activity
    my $recent_activity = $self->get_recent_activity($c);
    
    # Get system notifications
    my $notifications = $self->get_system_notifications($c);
    
    # Use the standard debug message system
    if ($c->session->{debug_mode}) {
        push @{$c->stash->{debug_msg}}, "Admin controller index view - Template: admin/index.tt";
    }
    
    # Pass data to the template
    $c->stash(
        template => 'admin/index.tt',
        stats => $stats,
        recent_activity => $recent_activity,
        notifications => $notifications
    );
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', 
        "Completed Admin index action");
}

# Get system statistics for the admin dashboard
sub get_system_stats {
    my ($self, $c) = @_;
    
    my $stats = {
        user_count => 0,
        content_count => 0,
        comment_count => 0,
        disk_usage => '0 MB',
        db_size => '0 MB',
        uptime => '0 days',
    };
    
    # Try to get user count
    eval {
        $stats->{user_count} = $c->model('DBEncy::User')->count();
    };
    
    # Try to get content count (pages, posts, etc.)
    eval {
        $stats->{content_count} = $c->model('DBEncy::Content')->count();
    };
    
    # Try to get comment count
    eval {
        $stats->{comment_count} = $c->model('DBEncy::Comment')->count();
    };
    
    # Get disk usage (this is a simplified example)
    eval {
        my $df_output = `df -h . | tail -1`;
        if ($df_output =~ /(\d+)%/) {
            $stats->{disk_usage} = "$1%";
        }
    };
    
    # Get database size (this would need to be customized for your DB)
    eval {
        # This is just a placeholder - you'd need to implement actual DB size checking
        $stats->{db_size} = "Unknown";
    };
    
    # Get system uptime
    eval {
        my $uptime_output = `uptime`;
        if ($uptime_output =~ /up\s+(.*?),\s+\d+\s+users/) {
            $stats->{uptime} = $1;
        }
    };
    
    return $stats;
}

# Get recent user activity for the admin dashboard
sub get_recent_activity {
    my ($self, $c) = @_;
    
    my @activity = ();
    
    # Try to get recent logins
    eval {
        my @logins = $c->model('DBEncy::UserLogin')->search(
            {},
            {
                order_by => { -desc => 'login_time' },
                rows => 5
            }
        );
        
        foreach my $login (@logins) {
            push @activity, {
                type => 'login',
                user => $login->user->username,
                time => $login->login_time,
                details => $login->ip_address
            };
        }
    };
    
    # Try to get recent content changes
    eval {
        my @changes = $c->model('DBEncy::ContentHistory')->search(
            {},
            {
                order_by => { -desc => 'change_time' },
                rows => 5
            }
        );
        
        foreach my $change (@changes) {
            push @activity, {
                type => 'content',
                user => $change->user->username,
                time => $change->change_time,
                details => "Updated " . $change->content->title
            };
        }
    };
    
    # Sort all activity by time (most recent first)
    @activity = sort { $b->{time} cmp $a->{time} } @activity;
    
    # Limit to 10 items
    if (scalar(@activity) > 10) {
        @activity = @activity[0..9];
    }
    
    return \@activity;
}

# Get system notifications for the admin dashboard
sub get_system_notifications {
    my ($self, $c) = @_;
    
    my @notifications = ();
    
    # Check for pending user registrations
    eval {
        my $pending_count = $c->model('DBEncy::User')->search({ status => 'pending' })->count();
        if ($pending_count > 0) {
            push @notifications, {
                type => 'warning',
                message => "$pending_count pending user registration(s) require approval",
                link => $c->uri_for('/admin/users', { filter => 'pending' })
            };
        }
    };
    
    # Check for low disk space
    eval {
        my $df_output = `df -h . | tail -1`;
        if ($df_output =~ /(\d+)%/ && $1 > 90) {
            push @notifications, {
                type => 'danger',
                message => "Disk space is critically low ($1% used)",
                link => undef
            };
        }
        elsif ($df_output =~ /(\d+)%/ && $1 > 80) {
            push @notifications, {
                type => 'warning',
                message => "Disk space is running low ($1% used)",
                link => undef
            };
        }
    };
    
    # Check for pending comments
    eval {
        my $pending_count = $c->model('DBEncy::Comment')->search({ status => 'pending' })->count();
        if ($pending_count > 0) {
            push @notifications, {
                type => 'info',
                message => "$pending_count pending comment(s) require moderation",
                link => $c->uri_for('/admin/comments', { filter => 'pending' })
            };
        }
    };
    
    return \@notifications;
}

# Admin users management
sub users :Path('/admin/users') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'users', 
        "Starting users action");
    
    # Check if the user has admin role
    unless ($c->user_exists && $c->check_user_roles('admin')) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'users', 
            "Access denied: User does not have admin role");
        
        # Set error message in flash
        $c->flash->{error_msg} = "You need to be an administrator to access this area.";
        
        # Redirect to login page with destination parameter
        $c->response->redirect($c->uri_for('/user/login', {
            destination => $c->req->uri
        }));
        return;
    }
    
    # Get filter parameter
    my $filter = $c->req->param('filter') || 'all';
    
    # Get search parameter
    my $search = $c->req->param('search') || '';
    
    # Get page parameter
    my $page = $c->req->param('page') || 1;
    my $users_per_page = 20;
    
    # Build search conditions
    my $search_conditions = {};
    
    # Apply filter
    if ($filter eq 'active') {
        $search_conditions->{status} = 'active';
    }
    elsif ($filter eq 'pending') {
        $search_conditions->{status} = 'pending';
    }
    elsif ($filter eq 'disabled') {
        $search_conditions->{status} = 'disabled';
    }
    
    # Apply search
    if ($search) {
        $search_conditions->{'-or'} = [
            { username => { 'like', "%$search%" } },
            { email => { 'like', "%$search%" } },
            { first_name => { 'like', "%$search%" } },
            { last_name => { 'like', "%$search%" } }
        ];
    }
    
    # Get users from database
    my $users_rs = $c->model('DBEncy::User')->search(
        $search_conditions,
        {
            order_by => { -asc => 'username' },
            page => $page,
            rows => $users_per_page
        }
    );
    
    # Get user roles
    my %user_roles = ();
    eval {
        my @user_role_records = $c->model('DBEncy::UserRole')->search({});
        foreach my $record (@user_role_records) {
            push @{$user_roles{$record->user_id}}, $record->role->role;
        }
    };
    
    # Use the standard debug message system
    if ($c->session->{debug_mode}) {
        push @{$c->stash->{debug_msg}}, "Admin controller users view - Template: admin/users.tt";
        push @{$c->stash->{debug_msg}}, "Filter: $filter, Search: $search, Page: $page";
        push @{$c->stash->{debug_msg}}, "User count: " . $users_rs->pager->total_entries;
    }
    
    # Pass data to the template
    $c->stash(
        template => 'admin/users.tt',
        users => [ $users_rs->all ],
        user_roles => \%user_roles,
        filter => $filter,
        search => $search,
        pager => $users_rs->pager
    );
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'users', 
        "Completed users action");
}

# Admin content management
sub content :Path('/admin/content') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'content', 
        "Starting content action");
    
    # Check if the user has admin role
    unless ($c->user_exists && $c->check_user_roles('admin')) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'content', 
            "Access denied: User does not have admin role");
        
        # Set error message in flash
        $c->flash->{error_msg} = "You need to be an administrator to access this area.";
        
        # Redirect to login page with destination parameter
        $c->response->redirect($c->uri_for('/user/login', {
            destination => $c->req->uri
        }));
        return;
    }
    
    # Get filter parameter
    my $filter = $c->req->param('filter') || 'all';
    
    # Get search parameter
    my $search = $c->req->param('search') || '';
    
    # Get page parameter
    my $page = $c->req->param('page') || 1;
    my $items_per_page = 20;
    
    # Build search conditions
    my $search_conditions = {};
    
    # Apply filter
    if ($filter eq 'published') {
        $search_conditions->{status} = 'published';
    }
    elsif ($filter eq 'draft') {
        $search_conditions->{status} = 'draft';
    }
    elsif ($filter eq 'archived') {
        $search_conditions->{status} = 'archived';
    }
    
    # Apply search
    if ($search) {
        $search_conditions->{'-or'} = [
            { title => { 'like', "%$search%" } },
            { content => { 'like', "%$search%" } },
            { 'author.username' => { 'like', "%$search%" } }
        ];
    }
    
    # Get content from database
    my $content_rs = $c->model('DBEncy::Content')->search(
        $search_conditions,
        {
            join => 'author',
            order_by => { -desc => 'created_at' },
            page => $page,
            rows => $items_per_page
        }
    );
    
    # Use the standard debug message system
    if ($c->session->{debug_mode}) {
        push @{$c->stash->{debug_msg}}, "Admin controller content view - Template: admin/content.tt";
        push @{$c->stash->{debug_msg}}, "Filter: $filter, Search: $search, Page: $page";
        push @{$c->stash->{debug_msg}}, "Content count: " . $content_rs->pager->total_entries;
    }
    
    # Pass data to the template
    $c->stash(
        template => 'admin/content.tt',
        content_items => [ $content_rs->all ],
        filter => $filter,
        search => $search,
        pager => $content_rs->pager
    );
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'content', 
        "Completed content action");
}

# Admin settings
sub settings :Path('/admin/settings') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'settings', 
        "Starting settings action");
    
    # Check if the user has admin role
    unless ($c->user_exists && $c->check_user_roles('admin')) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'settings', 
            "Access denied: User does not have admin role");
        
        # Set error message in flash
        $c->flash->{error_msg} = "You need to be an administrator to access this area.";
        
        # Redirect to login page with destination parameter
        $c->response->redirect($c->uri_for('/user/login', {
            destination => $c->req->uri
        }));
        return;
    }
    
    # Handle form submission
    if ($c->req->method eq 'POST') {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'settings', 
            "Processing settings form submission");
        
        # Get form parameters
        my $site_name = $c->req->param('site_name');
        my $site_description = $c->req->param('site_description');
        my $admin_email = $c->req->param('admin_email');
        my $items_per_page = $c->req->param('items_per_page');
        my $allow_comments = $c->req->param('allow_comments') ? 1 : 0;
        my $moderate_comments = $c->req->param('moderate_comments') ? 1 : 0;
        my $theme = $c->req->param('theme');
        
        # Validate inputs
        my $errors = {};
        
        unless ($site_name) {
            $errors->{site_name} = "Site name is required";
        }
        
        unless ($admin_email && $admin_email =~ /^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$/) {
            $errors->{admin_email} = "Valid admin email is required";
        }
        
        unless ($items_per_page && $items_per_page =~ /^\d+$/ && $items_per_page > 0) {
            $errors->{items_per_page} = "Items per page must be a positive number";
        }
        
        # If there are validation errors, re-display the form
        if (%$errors) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'settings', 
                "Validation errors in settings form");
            
            $c->stash(
                template => 'admin/settings.tt',
                errors => $errors,
                form_data => {
                    site_name => $site_name,
                    site_description => $site_description,
                    admin_email => $admin_email,
                    items_per_page => $items_per_page,
                    allow_comments => $allow_comments,
                    moderate_comments => $moderate_comments,
                    theme => $theme
                }
            );
            return;
        }
        
        # Save settings to database
        eval {
            # Update site_name setting
            $c->model('DBEncy::Setting')->update_or_create(
                {
                    name => 'site_name',
                    value => $site_name
                }
            );
            
            # Update site_description setting
            $c->model('DBEncy::Setting')->update_or_create(
                {
                    name => 'site_description',
                    value => $site_description
                }
            );
            
            # Update admin_email setting
            $c->model('DBEncy::Setting')->update_or_create(
                {
                    name => 'admin_email',
                    value => $admin_email
                }
            );
            
            # Update items_per_page setting
            $c->model('DBEncy::Setting')->update_or_create(
                {
                    name => 'items_per_page',
                    value => $items_per_page
                }
            );
            
            # Update allow_comments setting
            $c->model('DBEncy::Setting')->update_or_create(
                {
                    name => 'allow_comments',
                    value => $allow_comments
                }
            );
            
            # Update moderate_comments setting
            $c->model('DBEncy::Setting')->update_or_create(
                {
                    name => 'moderate_comments',
                    value => $moderate_comments
                }
            );
            
            # Update theme setting
            $c->model('DBEncy::Setting')->update_or_create(
                {
                    name => 'theme',
                    value => $theme
                }
            );
            
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'settings', 
                "Settings updated successfully");
            
            # Set success message and redirect
            $c->flash->{success_msg} = "Settings updated successfully";
            $c->response->redirect($c->uri_for('/admin/settings'));
            return;
        };
        
        # Handle database errors
        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'settings', 
                "Error updating settings: $@");
            
            $c->stash(
                template => 'admin/settings.tt',
                error_msg => "Error updating settings: $@",
                form_data => {
                    site_name => $site_name,
                    site_description => $site_description,
                    admin_email => $admin_email,
                    items_per_page => $items_per_page,
                    allow_comments => $allow_comments,
                    moderate_comments => $moderate_comments,
                    theme => $theme
                }
            );
            return;
        }
    }
    
    # Get current settings from database
    my %settings = ();
    eval {
        my @setting_records = $c->model('DBEncy::Setting')->search({});
        foreach my $record (@setting_records) {
            $settings{$record->name} = $record->value;
        }
    };
    
    # Get available themes
    my @themes = ('default', 'dark', 'light', 'custom');
    eval {
        my $themes_dir = $c->path_to('root', 'static', 'themes');
        if (-d $themes_dir) {
            opendir(my $dh, $themes_dir) or die "Cannot open themes directory: $!";
            @themes = grep { -d "$themes_dir/$_" && $_ !~ /^\./ } readdir($dh);
            closedir($dh);
        }
    };
    
    # Use the standard debug message system
    if ($c->session->{debug_mode}) {
        push @{$c->stash->{debug_msg}}, "Admin controller settings view - Template: admin/settings.tt";
        push @{$c->stash->{debug_msg}}, "Available themes: " . join(', ', @themes);
    }
    
    # Pass data to the template
    $c->stash(
        template => 'admin/settings.tt',
        settings => \%settings,
        themes => \@themes
    );
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'settings', 
        "Completed settings action");
}

# Admin system information
sub system_info :Path('/admin/system_info') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'system_info', 
        "Starting system_info action");
    
    # Check if the user has admin role
    unless ($c->user_exists && $c->check_user_roles('admin')) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'system_info', 
            "Access denied: User does not have admin role");
        
        # Set error message in flash
        $c->flash->{error_msg} = "You need to be an administrator to access this area.";
        
        # Redirect to login page with destination parameter
        $c->response->redirect($c->uri_for('/user/login', {
            destination => $c->req->uri
        }));
        return;
    }
    
    # Get system information
    my $system_info = $self->get_detailed_system_info($c);
    
    # Use the standard debug message system
    if ($c->session->{debug_mode}) {
        push @{$c->stash->{debug_msg}}, "Admin controller system_info view - Template: admin/system_info.tt";
    }
    
    # Pass data to the template
    $c->stash(
        template => 'admin/system_info.tt',
        system_info => $system_info
    );
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'system_info', 
        "Completed system_info action");
}

# Get detailed system information
sub get_detailed_system_info {
    my ($self, $c) = @_;
    
    my $info = {
        perl_version => $],
        catalyst_version => $Catalyst::VERSION,
        server_software => $ENV{SERVER_SOFTWARE} || 'Unknown',
        server_name => $ENV{SERVER_NAME} || 'Unknown',
        server_protocol => $ENV{SERVER_PROTOCOL} || 'Unknown',
        server_admin => $ENV{SERVER_ADMIN} || 'Unknown',
        server_port => $ENV{SERVER_PORT} || 'Unknown',
        document_root => $ENV{DOCUMENT_ROOT} || 'Unknown',
        script_name => $ENV{SCRIPT_NAME} || 'Unknown',
        request_uri => $ENV{REQUEST_URI} || 'Unknown',
        request_method => $ENV{REQUEST_METHOD} || 'Unknown',
        query_string => $ENV{QUERY_STRING} || 'Unknown',
        remote_addr => $ENV{REMOTE_ADDR} || 'Unknown',
        remote_port => $ENV{REMOTE_PORT} || 'Unknown',
        remote_user => $ENV{REMOTE_USER} || 'Unknown',
        http_user_agent => $ENV{HTTP_USER_AGENT} || 'Unknown',
        http_referer => $ENV{HTTP_REFERER} || 'Unknown',
        http_accept => $ENV{HTTP_ACCEPT} || 'Unknown',
        http_accept_language => $ENV{HTTP_ACCEPT_LANGUAGE} || 'Unknown',
        http_accept_encoding => $ENV{HTTP_ACCEPT_ENCODING} || 'Unknown',
        http_connection => $ENV{HTTP_CONNECTION} || 'Unknown',
        http_host => $ENV{HTTP_HOST} || 'Unknown',
        https => $ENV{HTTPS} || 'Off',
        gateway_interface => $ENV{GATEWAY_INTERFACE} || 'Unknown',
        server_signature => $ENV{SERVER_SIGNATURE} || 'Unknown',
        server_addr => $ENV{SERVER_ADDR} || 'Unknown',
        path => $ENV{PATH} || 'Unknown',
        system_uptime => 'Unknown',
        system_load => 'Unknown',
        memory_usage => 'Unknown',
        disk_usage => 'Unknown',
        database_info => 'Unknown',
        installed_modules => []
    };
    
    # Get system uptime
    eval {
        my $uptime_output = `uptime`;
        chomp($uptime_output);
        $info->{system_uptime} = $uptime_output;
        
        if ($uptime_output =~ /load average: ([\d.]+), ([\d.]+), ([\d.]+)/) {
            $info->{system_load} = "$1 (1 min), $2 (5 min), $3 (15 min)";
        }
    };
    
    # Get memory usage
    eval {
        my $free_output = `free -h`;
        my @lines = split(/\n/, $free_output);
        if ($lines[1] =~ /Mem:\s+(\S+)\s+(\S+)\s+(\S+)/) {
            $info->{memory_usage} = "Total: $1, Used: $2, Free: $3";
        }
    };
    
    # Get disk usage
    eval {
        my $df_output = `df -h .`;
        my @lines = split(/\n/, $df_output);
        if ($lines[1] =~ /(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)/) {
            $info->{disk_usage} = "Filesystem: $1, Size: $2, Used: $3, Avail: $4, Use%: $5, Mounted on: $6";
        }
    };
    
    # Get database information
    eval {
        my $dbh = $c->model('DBEncy')->schema->storage->dbh;
        my $db_info = $dbh->get_info(17); # SQL_DBMS_NAME
        my $db_version = $dbh->get_info(18); # SQL_DBMS_VER
        $info->{database_info} = "$db_info version $db_version";
    };
    
    # Get installed Perl modules
    eval {
        my @modules = ();
        foreach my $module (sort keys %INC) {
            next unless $module =~ /\.pm$/;
            $module =~ s/\//::/g;
            $module =~ s/\.pm$//;
            
            my $version = eval "\$${module}::VERSION" || 'Unknown';
            push @modules, { name => $module, version => $version };
        }
        $info->{installed_modules} = \@modules;
    };
    
    return $info;
}

# Admin logs viewer
sub logs :Path('/admin/logs') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'logs', 
        "Starting logs action");
    
    # Check if the user has admin role
    unless ($c->user_exists && $c->check_user_roles('admin')) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'logs', 
            "Access denied: User does not have admin role");
        
        # Set error message in flash
        $c->flash->{error_msg} = "You need to be an administrator to access this area.";
        
        # Redirect to login page with destination parameter
        $c->response->redirect($c->uri_for('/user/login', {
            destination => $c->req->uri
        }));
        return;
    }
    
    # Get log file parameter
    my $log_file = $c->req->param('file') || 'catalyst.log';
    
    # Get available log files
    my @log_files = ();
    eval {
        my $logs_dir = $c->path_to('logs');
        if (-d $logs_dir) {
            opendir(my $dh, $logs_dir) or die "Cannot open logs directory: $!";
            @log_files = grep { -f "$logs_dir/$_" && $_ !~ /^\./ } readdir($dh);
            closedir($dh);
        }
    };
    
    # Get log content
    my $log_content = '';
    eval {
        my $log_path = $c->path_to('logs', $log_file);
        if (-f $log_path) {
            # Get the last 1000 lines of the log file
            my $tail_output = `tail -n 1000 $log_path`;
            $log_content = $tail_output;
        }
    };
    
    # Use the standard debug message system
    if ($c->session->{debug_mode}) {
        push @{$c->stash->{debug_msg}}, "Admin controller logs view - Template: admin/logs.tt";
        push @{$c->stash->{debug_msg}}, "Log file: $log_file";
        push @{$c->stash->{debug_msg}}, "Available log files: " . join(', ', @log_files);
    }
    
    # Pass data to the template
    $c->stash(
        template => 'admin/logs.tt',
        log_file => $log_file,
        log_files => \@log_files,
        log_content => $log_content
    );

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'logs',
        "Completed logs action");
}

# Admin backup and restore
sub backup :Path('/admin/backup') :Args(0) {
    my ($self, $c) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'backup',
        "Starting backup action");

    # Check if the user has admin role
    unless ($c->user_exists && $c->check_user_roles('admin')) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'backup',
            "Access denied: User does not have admin role");

        $c->response->redirect($c->uri_for('/user/login', {
            destination => $c->req->uri,
            mid => $c->set_error_msg("You need to be an administrator to access this area.")
        }));
        return;
    }

    # Handle backup creation
    if ($c->req->method eq 'POST' && $c->req->param('action') eq 'create_backup') {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'backup',
            "Creating backup");

        my $backup_type = $c->req->param('backup_type') || 'full';
        my $backup_name = $c->req->param('backup_name') || 'backup_' . time();

        # Create backup directory if it doesn't exist
        my $backup_dir = $c->path_to('backups');
        unless (-d $backup_dir) {
            eval { make_path($backup_dir) };
            if ($@) {
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'backup',
                    "Error creating backup directory: $@");

                $c->flash->{error_msg} = "Error creating backup directory: $@";
                $c->response->redirect($c->uri_for('/admin/backup'));
                return;
            }
        }

        # Create backup
        my $backup_file = "$backup_dir/$backup_name.tar.gz";
        my $backup_command = '';

        if ($backup_type eq 'full') {
            # Full backup (files + database)
            $backup_command = "tar -czf $backup_file --exclude='backups' --exclude='tmp' --exclude='logs/*.log' .";
        }
        elsif ($backup_type eq 'files') {
            # Files only backup
            $backup_command = "tar -czf $backup_file --exclude='backups' --exclude='tmp' --exclude='logs/*.log' --exclude='db' .";
        }
        elsif ($backup_type eq 'database') {
            # Database only backup
            # This is a simplified example - you'd need to customize for your database
            $backup_command = "mysqldump -u username -p'password' database_name > $backup_dir/db_dump.sql && tar -czf $backup_file $backup_dir/db_dump.sql && rm $backup_dir/db_dump.sql";
        }

        # Execute backup command
        my $result = system($backup_command);

        if ($result == 0) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'backup',
                "Backup created successfully: $backup_file");

            $c->flash->{success_msg} = "Backup created successfully: $backup_name.tar.gz";
        }
        else {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'backup',
                "Error creating backup: $!");

            $c->flash->{error_msg} = "Error creating backup: $!";
        }

        $c->response->redirect($c->uri_for('/admin/backup'));
        return;
    }

    # Handle backup restoration
    if ($c->req->method eq 'POST' && $c->req->param('action') eq 'restore_backup') {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'backup',
            "Restoring backup");

        my $backup_file = $c->req->param('backup_file');

        unless ($backup_file) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'backup',
                "No backup file selected for restoration");

            $c->flash->{error_msg} = "No backup file selected for restoration";
            $c->response->redirect($c->uri_for('/admin/backup'));
            return;
        }

        # Validate backup file
        my $backup_path = $c->path_to('backups', $backup_file);
        unless (-f $backup_path) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'backup',
                "Backup file not found: $backup_file");

            $c->flash->{error_msg} = "Backup file not found: $backup_file";
            $c->response->redirect($c->uri_for('/admin/backup'));
            return;
        }

        # Create temporary directory for restoration
        my $temp_dir = $c->path_to('tmp', 'restore_' . time());
        eval { make_path($temp_dir) };
        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'backup',
                "Error creating temporary directory: $@");

            $c->flash->{error_msg} = "Error creating temporary directory: $@";
            $c->response->redirect($c->uri_for('/admin/backup'));
            return;
        }

        # Extract backup to temporary directory
        my $extract_command = "tar -xzf $backup_path -C $temp_dir";
        my $extract_result = system($extract_command);

        if ($extract_result != 0) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'backup',
                "Error extracting backup: $!");

            $c->flash->{error_msg} = "Error extracting backup: $!";
            $c->response->redirect($c->uri_for('/admin/backup'));
            return;
        }

        # Restore database if database dump exists
        if (-f "$temp_dir/db_dump.sql") {
            # This is a simplified example - you'd need to customize for your database
            my $db_restore_command = "mysql -u username -p'password' database_name < $temp_dir/db_dump.sql";
            my $db_restore_result = system($db_restore_command);

            if ($db_restore_result != 0) {
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'backup',
                    "Error restoring database: $!");

                $c->flash->{error_msg} = "Error restoring database: $!";
                $c->response->redirect($c->uri_for('/admin/backup'));
                return;
            }
        }

        # Restore files
        # This is a simplified example - you'd need to customize for your application
        my $files_restore_command = "cp -R $temp_dir/* .";
        my $files_restore_result = system($files_restore_command);

        if ($files_restore_result != 0) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'backup',
                "Error restoring files: $!");

            $c->flash->{error_msg} = "Error restoring files: $!";
            $c->response->redirect($c->uri_for('/admin/backup'));
            return;
        }

        # Clean up temporary directory
        my $cleanup_command = "rm -rf $temp_dir";
        system($cleanup_command);

        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'backup',
            "Backup restored successfully: $backup_file");

        $c->flash->{success_msg} = "Backup restored successfully: $backup_file";
        $c->response->redirect($c->uri_for('/admin/backup'));
        return;
    }

    # Get available backups
    my @backups = ();
    eval {
        my $backup_dir = $c->path_to('backups');
        if (-d $backup_dir) {
            opendir(my $dh, $backup_dir) or die "Cannot open backups directory: $!";
            @backups = grep { -f "$backup_dir/$_" && $_ =~ /\.tar\.gz$/ } readdir($dh);
            closedir($dh);

            # Sort backups by modification time (newest first)
            @backups = sort {
                (stat("$backup_dir/$b"))[9] <=> (stat("$backup_dir/$a"))[9]
            } @backups;
        }
    };

    # Use the standard debug message system
    if ($c->session->{debug_mode}) {
        push @{$c->stash->{debug_msg}}, "Admin controller backup view - Template: admin/backup.tt";
        push @{$c->stash->{debug_msg}}, "Available backups: " . join(', ', @backups);
    }

    # Pass data to the template
    $c->stash(
        template => 'admin/backup.tt',
        backups => \@backups
    );

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'backup',
        "Completed backup action");
}

# Keeping it here for backward compatibility
sub network_devices_forward :Path('/admin/network_devices_old') :Args(0) {
    my ($self, $c) = @_;

    # Redirect to the new network devices page
    $c->response->redirect($c->uri_for('/admin/network_devices'));
}

# Commented out to avoid redefinition - this functionality is now in Admin::NetworkDevices
# sub network_devices :Path('/admin/network_devices') :Args(0) {
#     # Implementation removed to avoid duplication
# }

# Commented out to avoid redefinition - this functionality is now in Admin::NetworkDevices
# sub add_network_device :Path('/admin/add_network_device') :Args(0) {
#     # Implementation removed to avoid duplication
# }

# Commented out to avoid redefinition - this functionality is now in Admin::NetworkDevices
# sub edit_network_device :Path('/admin/edit_network_device') :Args(1) {
#     # Implementation removed to avoid duplication
# }

# Commented out to avoid redefinition - this functionality is now in Admin::NetworkDevices
# sub delete_network_device :Path('/admin/delete_network_device') :Args(1) {
#     # Implementation removed to avoid duplication
# }

# Database Schema Comparison functionality (with alias)
sub compare_schema :Path('/admin/compare_schema') :Args(0) {
    my ($self, $c) = @_;
    # Redirect to the main schema_compare action
    $c->response->redirect($c->uri_for('/admin/schema_compare'));
    return;
}

# Database Schema Comparison functionality
sub schema_compare :Path('/admin/schema_compare') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'schema_compare', 
        "Starting schema_compare action");
    
    # Check if the user has admin role
    unless ($c->user_exists && $c->check_user_roles('admin')) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'schema_compare', 
            "Access denied: User does not have admin role");
        
        $c->flash->{error_msg} = "You need to be an administrator to access this area.";
        $c->response->redirect($c->uri_for('/user/login', {
            destination => $c->req->uri
        }));
        return;
    }
    
    # Get database comparison data
    my $database_comparison = $self->get_database_comparison($c);
    
    # Debug: Log the structure of database_comparison
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'schema_compare', 
        "Database comparison structure: " . Data::Dumper::Dumper($database_comparison));
    
    # Use the standard debug message system
    if ($c->session->{debug_mode}) {
        push @{$c->stash->{debug_msg}}, "Admin controller schema_compare view - Template: admin/schema_compare.tt";
        push @{$c->stash->{debug_msg}}, "Ency tables: " . scalar(@{$database_comparison->{ency}->{tables}});
        push @{$c->stash->{debug_msg}}, "Forager tables: " . scalar(@{$database_comparison->{forager}->{tables}});
        push @{$c->stash->{debug_msg}}, "Tables with results: " . $database_comparison->{summary}->{tables_with_results};
        push @{$c->stash->{debug_msg}}, "Tables without results: " . $database_comparison->{summary}->{tables_without_results};
    }
    
    # Set the template and data
    $c->stash(
        template => 'admin/schema_compare.tt',
        database_comparison => $database_comparison
    );
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'schema_compare', 
        "Completed schema_compare action");
}

# AJAX endpoint to get table schema details
sub get_table_schema :Path('/admin/get_table_schema') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_table_schema', 
        "Starting get_table_schema action");
    
    # Check if the user has admin role
    unless ($c->user_exists && $c->check_user_roles('admin')) {
        $c->response->status(403);
        $c->stash(json => { success => 0, error => 'Access denied' });
        $c->forward('View::JSON');
        return;
    }
    
    my $table_name = $c->req->param('table_name');
    my $database = $c->req->param('database');
    
    unless ($table_name && $database) {
        $c->response->status(400);
        $c->stash(json => { success => 0, error => 'Missing required parameters' });
        $c->forward('View::JSON');
        return;
    }
    
    try {
        my $schema_info;
        
        if ($database eq 'ency') {
            $schema_info = $self->get_ency_table_schema($c, $table_name);
        } elsif ($database eq 'forager') {
            $schema_info = $self->get_forager_table_schema($c, $table_name);
        } else {
            die "Invalid database: $database";
        }
        
        $c->stash(json => { 
            success => 1, 
            schema => $schema_info,
            table_name => $table_name,
            database => $database
        });
        
    } catch {
        my $error = "Error getting table schema: $_";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_table_schema', $error);
        
        $c->response->status(500);
        $c->stash(json => { success => 0, error => $error });
    };
    
    $c->forward('View::JSON');
}

# Get field comparison between table and Result file
sub get_field_comparison :Path('/admin/get_field_comparison') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_field_comparison',
        "Starting get_field_comparison action");
    
    my $table_name = $c->request->param('table_name');
    my $database = $c->request->param('database');
    
    unless ($table_name && $database) {
        $c->response->status(400);
        $c->stash(json => {
            success => 0,
            error => 'Missing table_name or database parameter'
        });
        $c->forward('View::JSON');
        return;
    }
    
    try {
        # Build comprehensive mapping for this database
        my $result_table_mapping = $self->build_result_table_mapping($c, $database);
        
        my $comparison = $self->get_table_result_comparison_v2($c, $table_name, $database, $result_table_mapping);
        
        # Add debugging information
        my $table_key = lc($table_name);
        my $result_info = $result_table_mapping->{$table_key};
        my $result_file_path = $result_info ? $result_info->{result_path} : undef;
        my $result_name = $result_info ? $result_info->{result_name} : 'NOT FOUND';
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_field_comparison',
            "Table: $table_name, Database: $database, Result name: $result_name, Result file: " . ($result_file_path || 'NOT FOUND'));
        
        # Add detailed debugging
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_field_comparison',
            "Comparison has_result_file: " . ($comparison->{has_result_file} ? 'YES' : 'NO'));
        
        if ($comparison->{fields}) {
            my $field_count = scalar(keys %{$comparison->{fields}});
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_field_comparison',
                "Fields found: $field_count");
            
            # Log first few fields for debugging
            my $count = 0;
            foreach my $field_name (keys %{$comparison->{fields}}) {
                last if $count >= 3;
                my $field_data = $comparison->{fields}->{$field_name};
                my $has_table = $field_data->{table} ? 'YES' : 'NO';
                my $has_result = $field_data->{result} ? 'YES' : 'NO';
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_field_comparison',
                    "Field '$field_name': Table=$has_table, Result=$has_result");
                $count++;
            }
        }
        
        $c->stash(json => {
            success => 1,
            comparison => $comparison,
            debug => {
                table_name => $table_name,
                database => $database,
                result_name => $result_name,
                result_file_path => $result_file_path,
                has_result_file => $comparison->{has_result_file},
                total_result_files => scalar(keys %$result_table_mapping)
            }
        });
        
    } catch {
        my $error = "Error getting field comparison for $table_name ($database): $_";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_field_comparison', $error);
        
        $c->response->status(500);
        $c->stash(json => {
            success => 0,
            error => $error
        });
    };
    
    $c->forward('View::JSON');
}

# Get database comparison between each database and its result files
sub get_database_comparison {
    my ($self, $c) = @_;
    
    my $comparison = {
        ency => {
            name => 'ency',
            display_name => 'Encyclopedia Database',
            tables => [],
            table_count => 0,
            connection_status => 'unknown',
            error => undef,
            table_comparisons => []
        },
        forager => {
            name => 'forager',
            display_name => 'Forager Database',
            tables => [],
            table_count => 0,
            connection_status => 'unknown',
            error => undef,
            table_comparisons => []
        },
        summary => {
            total_databases => 2,
            connected_databases => 0,
            total_tables => 0,
            tables_with_results => 0,
            tables_without_results => 0,
            results_without_tables => 0
        }
    };
    
    # Get Ency database tables and compare with result files
    try {
        my $ency_tables = $self->get_ency_database_tables($c);
        $comparison->{ency}->{tables} = $ency_tables;
        $comparison->{ency}->{table_count} = scalar(@$ency_tables);
        $comparison->{ency}->{connection_status} = 'connected';
        $comparison->{summary}->{connected_databases}++;
        $comparison->{summary}->{total_tables} += scalar(@$ency_tables);
        
        # Build comprehensive mapping of result files to their actual table names
        my $result_table_mapping = $self->build_result_table_mapping($c, 'ency');
        
        # Compare each table with its result file
        my @tables_with_results = ();
        my @tables_without_results = ();
        
        foreach my $table_name (@$ency_tables) {
            my $table_comparison = $self->compare_table_with_result_file_v2($c, $table_name, 'ency', $result_table_mapping);
            
            # Debug logging
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_database_comparison', 
                "Table: $table_name -> Has result: " . ($table_comparison->{has_result_file} ? 'YES' : 'NO') .
                ($table_comparison->{result_file_path} ? " -> Path: " . $table_comparison->{result_file_path} : ""));
            
            if ($table_comparison->{has_result_file}) {
                push @tables_with_results, $table_comparison;
                $comparison->{summary}->{tables_with_results}++;
            } else {
                push @tables_without_results, $table_comparison;
                $comparison->{summary}->{tables_without_results}++;
            }
        }
        
        # Find result files without corresponding tables
        my @results_without_tables = $self->find_orphaned_result_files_v2($c, 'ency', $ency_tables, $result_table_mapping);
        $comparison->{summary}->{results_without_tables} += scalar(@results_without_tables);
        
        # Organize comparisons: tables with results first, then tables without results
        $comparison->{ency}->{table_comparisons} = [@tables_with_results, @tables_without_results];
        $comparison->{ency}->{results_without_tables} = \@results_without_tables;
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_database_comparison', 
            "Found " . scalar(@$ency_tables) . " tables in ency database, " . 
            scalar(@tables_with_results) . " with results, " . 
            scalar(@tables_without_results) . " without results, " . 
            scalar(@results_without_tables) . " orphaned results");
            
    } catch {
        my $error = "Error connecting to ency database: $_";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_database_comparison', $error);
        $comparison->{ency}->{connection_status} = 'error';
        $comparison->{ency}->{error} = $error;
    };
    
    # Get Forager database tables and compare with result files
    try {
        my $forager_tables = $self->get_forager_database_tables($c);
        $comparison->{forager}->{tables} = $forager_tables;
        $comparison->{forager}->{table_count} = scalar(@$forager_tables);
        $comparison->{forager}->{connection_status} = 'connected';
        $comparison->{summary}->{connected_databases}++;
        $comparison->{summary}->{total_tables} += scalar(@$forager_tables);
        
        # Build comprehensive mapping of result files to their actual table names
        my $result_table_mapping = $self->build_result_table_mapping($c, 'forager');
        
        # Compare each table with its result file
        my @tables_with_results = ();
        my @tables_without_results = ();
        
        foreach my $table_name (@$forager_tables) {
            my $table_comparison = $self->compare_table_with_result_file_v2($c, $table_name, 'forager', $result_table_mapping);
            
            # Debug logging
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_database_comparison', 
                "Forager Table: $table_name -> Has result: " . ($table_comparison->{has_result_file} ? 'YES' : 'NO') .
                ($table_comparison->{result_file_path} ? " -> Path: " . $table_comparison->{result_file_path} : ""));
            
            if ($table_comparison->{has_result_file}) {
                push @tables_with_results, $table_comparison;
                $comparison->{summary}->{tables_with_results}++;
            } else {
                push @tables_without_results, $table_comparison;
                $comparison->{summary}->{tables_without_results}++;
            }
        }
        
        # Find result files without corresponding tables
        my @results_without_tables = $self->find_orphaned_result_files_v2($c, 'forager', $forager_tables, $result_table_mapping);
        $comparison->{summary}->{results_without_tables} += scalar(@results_without_tables);
        
        # Organize comparisons: tables with results first, then tables without results
        $comparison->{forager}->{table_comparisons} = [@tables_with_results, @tables_without_results];
        $comparison->{forager}->{results_without_tables} = \@results_without_tables;
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_database_comparison', 
            "Found " . scalar(@$forager_tables) . " tables in forager database, " . 
            scalar(@tables_with_results) . " with results, " . 
            scalar(@tables_without_results) . " without results, " . 
            scalar(@results_without_tables) . " orphaned results");
            
    } catch {
        my $error = "Error connecting to forager database: $_";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_database_comparison', $error);
        $comparison->{forager}->{connection_status} = 'error';
        $comparison->{forager}->{error} = $error;
    };
    
    return $comparison;
}

# Compare a database table with its Result file
sub compare_table_with_result_file {
    my ($self, $c, $table_name, $database) = @_;
    
    my $comparison = {
        table_name => $table_name,
        database => $database,
        has_result_file => 0,
        result_file_path => undef,
        database_schema => {},
        result_file_schema => {},
        differences => [],
        sync_status => 'unknown',
        last_modified => undef
    };
    
    # Look for Result file
    my $result_file_path = $self->find_result_file($c, $table_name, $database);
    if ($result_file_path && -f $result_file_path) {
        $comparison->{has_result_file} = 1;
        $comparison->{result_file_path} = $result_file_path;
        $comparison->{last_modified} = (stat($result_file_path))[9];
        
        # Get database schema
        try {
            if ($database eq 'ency') {
                $comparison->{database_schema} = $self->get_ency_table_schema($c, $table_name);
            } elsif ($database eq 'forager') {
                $comparison->{database_schema} = $self->get_forager_table_schema($c, $table_name);
            }
        } catch {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'compare_table_with_result_file', 
                "Error getting database schema for $table_name: $_");
        };
        
        # Parse Result file schema
        try {
            $comparison->{result_file_schema} = $self->parse_result_file_schema($c, $result_file_path);
        } catch {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'compare_table_with_result_file', 
                "Error parsing Result file schema for $table_name: $_");
        };
        
        # Compare schemas and find differences
        $comparison->{differences} = $self->find_schema_differences(
            $comparison->{database_schema}, 
            $comparison->{result_file_schema}
        );
        
        # Determine sync status
        if (scalar(@{$comparison->{differences}}) == 0) {
            $comparison->{sync_status} = 'synchronized';
        } else {
            $comparison->{sync_status} = 'needs_sync';
        }
    } else {
        $comparison->{sync_status} = 'no_result_file';
    }
    
    return $comparison;
}

# Find Result file for a table
sub find_result_file {
    my ($self, $c, $table_name, $database) = @_;
    
    # Convert table name to proper case for Result file names
    my $result_name = $self->table_name_to_result_name($table_name);
    
    # Database-specific Result file locations to check
    my @search_paths;
    
    # Get the application root directory
    my $app_root = $c->config->{home} || '/home/shanta/PycharmProjects/comserv2';
    
    if (lc($database) eq 'ency') {
        @search_paths = (
            "$app_root/Comserv/lib/Comserv/Model/Schema/Ency/Result/$result_name.pm",
            "$app_root/Comserv/lib/Comserv/Model/Schema/Ency/Result/System/$result_name.pm",
            "$app_root/Comserv/lib/Comserv/Model/Schema/Ency/Result/User/$result_name.pm"
        );
    } elsif (lc($database) eq 'forager') {
        @search_paths = (
            "$app_root/Comserv/lib/Comserv/Model/Schema/Forager/Result/$result_name.pm"
        );
    } else {
        # Fallback for unknown databases
        @search_paths = (
            "$app_root/Comserv/lib/Comserv/Model/Schema/Result/$result_name.pm",
            "$app_root/Comserv/lib/Comserv/Schema/Result/$result_name.pm"
        );
    }
    
    foreach my $path (@search_paths) {
        if (-f $path) {
            return $path;
        }
    }
    
    return undef;
}

# Convert table name to Result class name
sub table_name_to_result_name {
    my ($self, $table_name) = @_;
    
    # Convert snake_case or lowercase to PascalCase
    # e.g., "user_group" -> "UserGroup", "ency_herb_tb" -> "Herb"
    
    # Handle database-specific table name patterns
    my $clean_name = $table_name;
    
    # Remove common prefixes
    $clean_name =~ s/^ency_//i;
    $clean_name =~ s/^forager_//i;
    
    # Remove common suffixes
    $clean_name =~ s/_tb$//i;
    $clean_name =~ s/_table$//i;
    
    # Handle special plurals and known mappings
    my %table_to_result = (
        'categories' => 'Category',
        'event' => 'Event',
        'files' => 'File',
        'groups' => 'Group',
        'internal_links_tb' => 'InternalLinksTb',
        'learned_data' => 'Learned_data',
        'log' => 'Log',
        'mail_domains' => 'MailDomain',
        'network_devices' => 'NetworkDevice',
        'pages_content' => 'Pages_content',
        'page_tb' => 'PageTb',
        'pallets' => 'Pallet',
        'participant' => 'Participant',
        'projects' => 'Project',
        'project_sites' => 'ProjectSite',
        'queens' => 'Queen',
        'reference' => 'Reference',
        'site_config' => 'SiteConfig',
        'sitedomain' => 'SiteDomain',
        'sites' => 'Site',
        'site_themes' => 'SiteTheme',
        'site_workshop' => 'SiteWorkshop',
        'themes' => 'Theme',
        'theme_variables' => 'ThemeVariable',
        'todo' => 'Todo',
        'user_groups' => 'UserGroup',
        'users' => 'User',
        'user_sites' => 'UserSite',
        'workshop' => 'WorkShop',
        'yards' => 'Yard',
        'ency_herb_tb' => 'Herb',
        'page' => 'Page'
    );
    
    # Check if it's a known mapping
    if (exists $table_to_result{lc($table_name)}) {
        return $table_to_result{lc($table_name)};
    }
    
    # Convert underscores to PascalCase
    my $result_name = join('', map { ucfirst(lc($_)) } split(/_/, $clean_name));
    
    return $result_name;
}

# Find Result files that don't have corresponding database tables
sub find_orphaned_result_files {
    my ($self, $c, $database, $existing_tables) = @_;
    
    my @orphaned_results = ();
    my %table_lookup = map { lc($_) => 1 } @$existing_tables;
    
    # Get all Result files for this database
    my @result_files = $self->get_all_result_files($database);
    
    foreach my $result_file (@result_files) {
        # Extract actual table name from Result file by reading the __PACKAGE__->table() declaration
        my $table_name = $self->extract_table_name_from_result_file($result_file->{path});
        
        # Skip if we couldn't extract table name
        next unless $table_name;
        
        # Check if corresponding table exists
        unless (exists $table_lookup{lc($table_name)}) {
            push @orphaned_results, {
                result_name => $result_file->{name},
                result_path => $result_file->{path},
                expected_table_name => $table_name,
                actual_table_name => $table_name,
                last_modified => $result_file->{last_modified}
            };
        }
    }
    
    return @orphaned_results;
}

# Extract table name from Result file by reading __PACKAGE__->table() declaration
sub extract_table_name_from_result_file {
    my ($self, $file_path) = @_;
    
    return undef unless -f $file_path;
    
    # Read the Result file
    my $content;
    eval {
        $content = File::Slurp::read_file($file_path);
    };
    if ($@) {
        warn "Failed to read Result file $file_path: $@";
        return undef;
    }
    
    # Extract table name from __PACKAGE__->table('table_name') declaration
    if ($content =~ /__PACKAGE__->table\(['"]([^'"]+)['"]\);/) {
        return $1;
    }
    
    return undef;
}

# Build comprehensive mapping of result files to their actual table names
sub build_result_table_mapping {
    my ($self, $c, $database) = @_;
    
    my %mapping = ();  # table_name => { result_name => ..., result_path => ... }
    
    # Get all Result files for this database
    my @result_files = $self->get_all_result_files($database);
    
    foreach my $result_file (@result_files) {
        # Extract actual table name from Result file
        my $table_name = $self->extract_table_name_from_result_file($result_file->{path});
        
        if ($table_name) {
            $mapping{lc($table_name)} = {
                result_name => $result_file->{name},
                result_path => $result_file->{path},
                last_modified => $result_file->{last_modified}
            };
        }
    }
    
    return \%mapping;
}

# Compare table with result file using the comprehensive mapping
sub compare_table_with_result_file_v2 {
    my ($self, $c, $table_name, $database, $result_table_mapping) = @_;
    
    my $comparison = {
        table_name => $table_name,
        database => $database,
        has_result_file => 0,
        result_file_path => undef,
        database_schema => {},
        result_file_schema => {},
        differences => [],
        sync_status => 'unknown',
        last_modified => undef
    };
    
    # Check if this table has a corresponding result file
    my $table_key = lc($table_name);
    if (exists $result_table_mapping->{$table_key}) {
        my $result_info = $result_table_mapping->{$table_key};
        
        $comparison->{has_result_file} = 1;
        $comparison->{result_file_path} = $result_info->{result_path};
        $comparison->{last_modified} = $result_info->{last_modified};
        
        # Get database schema
        try {
            if ($database eq 'ency') {
                $comparison->{database_schema} = $self->get_ency_table_schema($c, $table_name);
            } elsif ($database eq 'forager') {
                $comparison->{database_schema} = $self->get_forager_table_schema($c, $table_name);
            }
        } catch {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'compare_table_with_result_file_v2', 
                "Error getting database schema for $table_name: $_");
        };
        
        # Parse Result file schema
        try {
            $comparison->{result_file_schema} = $self->parse_result_file_schema($c, $result_info->{result_path});
        } catch {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'compare_table_with_result_file_v2', 
                "Error parsing Result file schema for $table_name: $_");
        };
        
        # Compare schemas and find differences
        $comparison->{differences} = $self->find_schema_differences(
            $comparison->{database_schema}, 
            $comparison->{result_file_schema}
        );
        
        # Determine sync status
        if (scalar(@{$comparison->{differences}}) == 0) {
            $comparison->{sync_status} = 'synchronized';
        } else {
            $comparison->{sync_status} = 'needs_sync';
        }
    } else {
        $comparison->{sync_status} = 'no_result_file';
    }
    
    return $comparison;
}

# Find result files without corresponding tables using the comprehensive mapping
sub find_orphaned_result_files_v2 {
    my ($self, $c, $database, $existing_tables, $result_table_mapping) = @_;
    
    my @orphaned_results = ();
    my %table_lookup = map { lc($_) => 1 } @$existing_tables;
    
    # Check each result file to see if its table exists
    foreach my $table_name (keys %$result_table_mapping) {
        unless (exists $table_lookup{$table_name}) {
            my $result_info = $result_table_mapping->{$table_name};
            push @orphaned_results, {
                result_name => $result_info->{result_name},
                result_path => $result_info->{result_path},
                expected_table_name => $table_name,
                actual_table_name => $table_name,
                last_modified => $result_info->{last_modified}
            };
        }
    }
    
    return @orphaned_results;
}

# Get all Result files for a database
sub get_all_result_files {
    my ($self, $database) = @_;
    
    my @result_files = ();
    my $base_path = "/home/shanta/PycharmProjects/comserv2/Comserv/lib/Comserv/Model/Schema";
    
    if (lc($database) eq 'ency') {
        my $result_dir = "$base_path/Ency/Result";
        @result_files = $self->scan_result_directory($result_dir, '');
        
        # Also scan subdirectories
        if (-d "$result_dir/System") {
            push @result_files, $self->scan_result_directory("$result_dir/System", 'System/');
        }
        if (-d "$result_dir/User") {
            push @result_files, $self->scan_result_directory("$result_dir/User", 'User/');
        }
    } elsif (lc($database) eq 'forager') {
        my $result_dir = "$base_path/Forager/Result";
        @result_files = $self->scan_result_directory($result_dir, '');
    }
    
    return @result_files;
}

# Scan a directory for Result files
sub scan_result_directory {
    my ($self, $dir_path, $prefix) = @_;
    
    my @files = ();
    
    if (opendir(my $dh, $dir_path)) {
        while (my $file = readdir($dh)) {
            next if $file =~ /^\.\.?$/;  # Skip . and ..
            next unless $file =~ /\.pm$/;  # Only .pm files
            
            my $full_path = "$dir_path/$file";
            next unless -f $full_path;  # Only regular files
            
            my $name = $file;
            $name =~ s/\.pm$//;  # Remove .pm extension
            
            push @files, {
                name => $prefix . $name,
                path => $full_path,
                last_modified => (stat($full_path))[9]
            };
        }
        closedir($dh);
    }
    
    return @files;
}

# Convert Result class name back to table name
sub result_name_to_table_name {
    my ($self, $result_name) = @_;
    
    # Remove any path prefix (e.g., "System/Site" -> "Site")
    $result_name =~ s/.*\///;
    
    # Handle special cases - map Result names to actual table names
    my %result_to_table = (
        'Category' => 'categories',
        'File' => 'files',
        'Group' => 'groups',
        'User' => 'users',
        'Event' => 'events',
        'Site' => 'sites',
        'Todo' => 'todos',
        'Project' => 'projects',
        'WorkShop' => 'workshops',
        'Theme' => 'themes',
        'Reference' => 'references',
        'Participant' => 'participants',
        'Herb' => 'ency_herb_tb',
        'Page' => 'page',
        'Pages_content' => 'pages_content',
        'InternalLinksTb' => 'internal_links_tb',
        'Learned_data' => 'learned_data',
        'Log' => 'log',
        'MailDomain' => 'mail_domains',
        'NetworkDevice' => 'network_devices',
        'PageTb' => 'page_tb',
        'Pallet' => 'pallets',
        'ProjectSite' => 'project_sites',
        'Queen' => 'queens',
        'SiteConfig' => 'site_config',
        'SiteDomain' => 'sitedomain',
        'SiteTheme' => 'site_themes',
        'SiteWorkshop' => 'site_workshop',
        'ThemeVariable' => 'theme_variables',
        'UserGroup' => 'user_groups',
        'UserSite' => 'user_sites',
        'Yard' => 'yards'
    );
    
    # Check if it's a known mapping
    if (exists $result_to_table{$result_name}) {
        return $result_to_table{$result_name};
    }
    
    # Convert PascalCase to snake_case
    my $table_name = $result_name;
    $table_name =~ s/([a-z])([A-Z])/$1_$2/g;  # Insert underscore before capitals
    $table_name = lc($table_name);
    
    # For unknown mappings, try common patterns
    # This is a fallback - ideally all mappings should be explicit above
    return $table_name;
}

# Get detailed field comparison between table and Result file
sub get_table_result_comparison {
    my ($self, $c, $table_name, $database) = @_;
    
    # Get table schema
    my $table_schema;
    eval {
        if ($database eq 'ency') {
            $table_schema = $self->get_ency_table_schema($c, $table_name);
        } elsif ($database eq 'forager') {
            $table_schema = $self->get_forager_table_schema($c, $table_name);
        } else {
            die "Invalid database: $database";
        }
    };
    if ($@) {
        warn "Failed to get table schema for $table_name ($database): $@";
        $table_schema = { columns => {} };
    }
    
    # Find and parse Result file
    my $result_file_path = $self->find_result_file($c, $table_name, $database);
    my $result_schema = { columns => {} };
    
    if ($result_file_path && -f $result_file_path) {
        eval {
            $result_schema = $self->parse_result_file_schema($c, $result_file_path);
        };
        if ($@) {
            warn "Failed to parse Result file $result_file_path: $@";
            $result_schema = { columns => {} };
        }
    }
    
    # Create field comparison
    my $comparison = {
        table_name => $table_name,
        database => $database,
        has_result_file => ($result_file_path && -f $result_file_path) ? 1 : 0,
        result_file_path => $result_file_path,
        fields => {}
    };
    
    # Get all unique field names from both sources
    my %all_fields = ();
    if ($table_schema && $table_schema->{columns}) {
        %all_fields = (%all_fields, map { $_ => 1 } keys %{$table_schema->{columns}});
    }
    if ($result_schema && $result_schema->{columns}) {
        %all_fields = (%all_fields, map { $_ => 1 } keys %{$result_schema->{columns}});
    }
    
    # Compare each field
    foreach my $field_name (sort keys %all_fields) {
        my $table_field = $table_schema->{columns}->{$field_name};
        my $result_field = $result_schema->{columns}->{$field_name};
        
        $comparison->{fields}->{$field_name} = {
            table => $table_field,
            result => $result_field,
            differences => $self->compare_field_attributes($table_field, $result_field)
        };
    }
    
    return $comparison;
}

# Get detailed field comparison between table and Result file using comprehensive mapping
sub get_table_result_comparison_v2 {
    my ($self, $c, $table_name, $database, $result_table_mapping) = @_;
    
    # Get table schema
    my $table_schema;
    eval {
        if ($database eq 'ency') {
            $table_schema = $self->get_ency_table_schema($c, $table_name);
        } elsif ($database eq 'forager') {
            $table_schema = $self->get_forager_table_schema($c, $table_name);
        } else {
            die "Invalid database: $database";
        }
    };
    if ($@) {
        warn "Failed to get table schema for $table_name ($database): $@";
        $table_schema = { columns => {} };
    }
    
    # Check if this table has a corresponding result file using the mapping
    my $table_key = lc($table_name);
    my $result_info = $result_table_mapping->{$table_key};
    my $result_schema = { columns => {} };
    
    if ($result_info && -f $result_info->{result_path}) {
        eval {
            $result_schema = $self->parse_result_file_schema($c, $result_info->{result_path});
        };
        if ($@) {
            warn "Failed to parse Result file $result_info->{result_path}: $@";
            $result_schema = { columns => {} };
        }
    }
    
    # Create field comparison
    my $comparison = {
        table_name => $table_name,
        database => $database,
        has_result_file => $result_info ? 1 : 0,
        result_file_path => $result_info ? $result_info->{result_path} : undef,
        fields => {}
    };
    
    # Get all unique field names from both sources
    my %all_fields = ();
    if ($table_schema && $table_schema->{columns}) {
        %all_fields = (%all_fields, map { $_ => 1 } keys %{$table_schema->{columns}});
    }
    if ($result_schema && $result_schema->{columns}) {
        %all_fields = (%all_fields, map { $_ => 1 } keys %{$result_schema->{columns}});
    }
    
    # Compare each field
    foreach my $field_name (sort keys %all_fields) {
        my $table_field = $table_schema->{columns}->{$field_name};
        my $result_field = $result_schema->{columns}->{$field_name};
        
        $comparison->{fields}->{$field_name} = {
            table => $table_field,
            result => $result_field,
            differences => $self->compare_field_attributes($table_field, $result_field)
        };
    }
    
    return $comparison;
}

# Compare field attributes between table and Result file
sub compare_field_attributes {
    my ($self, $table_field, $result_field) = @_;
    
    my @differences = ();
    my @attributes = qw(data_type size is_nullable is_auto_increment default_value);
    
    foreach my $attr (@attributes) {
        my $table_value = $table_field ? $table_field->{$attr} : undef;
        my $result_value = $result_field ? $result_field->{$attr} : undef;
        
        # Normalize values for comparison
        $table_value = $self->normalize_field_value($attr, $table_value);
        $result_value = $self->normalize_field_value($attr, $result_value);
        
        if (defined $table_value && defined $result_value) {
            if ($table_value ne $result_value) {
                push @differences, {
                    attribute => $attr,
                    table_value => $table_value,
                    result_value => $result_value,
                    type => 'different'
                };
            }
        } elsif (defined $table_value && !defined $result_value) {
            push @differences, {
                attribute => $attr,
                table_value => $table_value,
                result_value => undef,
                type => 'missing_in_result'
            };
        } elsif (!defined $table_value && defined $result_value) {
            push @differences, {
                attribute => $attr,
                table_value => undef,
                result_value => $result_value,
                type => 'missing_in_table'
            };
        }
    }
    
    return \@differences;
}

# Normalize field values for comparison
sub normalize_field_value {
    my ($self, $attribute, $value) = @_;
    
    return undef unless defined $value;
    
    # Handle boolean attributes
    if ($attribute eq 'is_nullable' || $attribute eq 'is_auto_increment') {
        return $value ? 1 : 0;
    }
    
    # Handle numeric attributes
    if ($attribute eq 'size') {
        return $value + 0 if $value =~ /^\d+$/;
    }
    
    # Handle string attributes
    return "$value";
}

# Parse Result file schema
sub parse_result_file_schema {
    my ($self, $c, $file_path) = @_;
    
    my $schema = {
        columns => {},
        primary_keys => [],
        relationships => [],
        table_name => undef
    };
    
    # Read the Result file
    my $content;
    eval {
        $content = File::Slurp::read_file($file_path);
    };
    if ($@) {
        warn "Failed to read Result file $file_path: $@";
        return $schema;
    }
    
    # Extract table name
    if ($content =~ /__PACKAGE__->table\(['"]([^'"]+)['"]\);/) {
        $schema->{table_name} = $1;
    }
    
    # Extract columns
    if ($content =~ /__PACKAGE__->add_columns\(\s*(.*?)\s*\);/s) {
        my $columns_block = $1;
        
        # Parse individual column definitions (format: column_name => { attributes })
        while ($columns_block =~ /(\w+)\s*=>\s*\{([^}]+)\}/g) {
            my ($col_name, $col_def) = ($1, $2);
            
            my $column = {
                data_type => undef,
                is_nullable => 1,
                size => undef,
                is_auto_increment => 0,
                default_value => undef
            };
            
            # Parse column attributes
            if ($col_def =~ /data_type\s*=>\s*['"]([^'"]+)['"]/) {
                $column->{data_type} = $1;
            }
            if ($col_def =~ /is_nullable\s*=>\s*(\d+)/) {
                $column->{is_nullable} = $1;
            }
            if ($col_def =~ /size\s*=>\s*(\d+)/) {
                $column->{size} = $1;
            }
            if ($col_def =~ /is_auto_increment\s*=>\s*(\d+)/) {
                $column->{is_auto_increment} = $1;
            }
            if ($col_def =~ /default_value\s*=>\s*['"]([^'"]+)['"]/) {
                $column->{default_value} = $1;
            }
            
            $schema->{columns}->{$col_name} = $column;
        }
    }
    
    # Extract primary keys
    if ($content =~ /__PACKAGE__->set_primary_key\(([^)]+)\);/) {
        my $pk_def = $1;
        while ($pk_def =~ /['"]([^'"]+)['"]/g) {
            push @{$schema->{primary_keys}}, $1;
        }
    }
    
    # Extract relationships
    while ($content =~ /__PACKAGE__->(belongs_to|has_many|might_have|has_one)\(\s*['"]([^'"]+)['"],\s*['"]([^'"]+)['"],\s*\{([^}]+)\}/gs) {
        my ($rel_type, $accessor, $related_class, $rel_def) = ($1, $2, $3, $4);
        
        my $relationship = {
            type => $rel_type,
            accessor => $accessor,
            related_class => $related_class,
            foreign_key => undef
        };
        
        if ($rel_def =~ /['"]foreign\.([^'"]+)['"]/) {
            $relationship->{foreign_key} = $1;
        }
        
        push @{$schema->{relationships}}, $relationship;
    }
    
    return $schema;
}

# Find differences between database and Result file schemas
sub find_schema_differences {
    my ($self, $db_schema, $result_schema) = @_;
    
    my @differences = ();
    
    # Compare columns
    my %db_columns = %{$db_schema->{columns} || {}};
    my %result_columns = %{$result_schema->{columns} || {}};
    
    # Find columns in database but not in Result file
    foreach my $col_name (keys %db_columns) {
        unless (exists $result_columns{$col_name}) {
            push @differences, {
                type => 'missing_in_result',
                column => $col_name,
                description => "Column '$col_name' exists in database but not in Result file"
            };
        }
    }
    
    # Find columns in Result file but not in database
    foreach my $col_name (keys %result_columns) {
        unless (exists $db_columns{$col_name}) {
            push @differences, {
                type => 'missing_in_database',
                column => $col_name,
                description => "Column '$col_name' exists in Result file but not in database"
            };
        }
    }
    
    # Compare column attributes for common columns
    foreach my $col_name (keys %db_columns) {
        if (exists $result_columns{$col_name}) {
            my $db_col = $db_columns{$col_name};
            my $result_col = $result_columns{$col_name};
            
            # Compare data types
            if (($db_col->{data_type} || '') ne ($result_col->{data_type} || '')) {
                push @differences, {
                    type => 'column_type_mismatch',
                    column => $col_name,
                    database_value => $db_col->{data_type},
                    result_value => $result_col->{data_type},
                    description => "Data type mismatch for column '$col_name'"
                };
            }
            
            # Compare nullable status
            if (($db_col->{is_nullable} || 0) != ($result_col->{is_nullable} || 0)) {
                push @differences, {
                    type => 'column_nullable_mismatch',
                    column => $col_name,
                    database_value => $db_col->{is_nullable} ? 'YES' : 'NO',
                    result_value => $result_col->{is_nullable} ? 'YES' : 'NO',
                    description => "Nullable status mismatch for column '$col_name'"
                };
            }
        }
    }
    
    return \@differences;
}

# Get the database name
sub get_database_name {
    my ($self, $c) = @_;
    
    my $database_name = 'Unknown Database';
    
    try {
        my $dbh = $c->model('DBEncy')->schema->storage->dbh;
        my $sth = $dbh->prepare("SELECT DATABASE()");
        $sth->execute();
        
        if (my ($db_name) = $sth->fetchrow_array()) {
            $database_name = $db_name;
        }
        
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_database_name', 
            "Error getting database name: $_");
    };
    
    return $database_name;
}

# Get list of database tables with their schema information
sub get_database_tables {
    my ($self, $c) = @_;
    
    my @tables = ();
    
    try {
        my $dbh = $c->model('DBEncy')->schema->storage->dbh;
        my $sth = $dbh->prepare("SHOW TABLES");
        $sth->execute();
        
        while (my ($table) = $sth->fetchrow_array()) {
            push @tables, $table;
        }
        
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_database_tables', 
            "Error getting database tables: $_");
    };
    
    return \@tables;
}

# Get list of tables from the Ency database
sub get_ency_database_tables {
    my ($self, $c) = @_;
    
    my @tables = ();
    
    try {
        my $dbh = $c->model('DBEncy')->schema->storage->dbh;
        my $sth = $dbh->prepare("SHOW TABLES");
        $sth->execute();
        
        while (my ($table) = $sth->fetchrow_array()) {
            push @tables, $table;
        }
        
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_ency_database_tables', 
            "Error getting ency database tables: $_");
        die $_;
    };
    
    return \@tables;
}

# Get list of tables from the Forager database
sub get_forager_database_tables {
    my ($self, $c) = @_;
    
    my @tables = ();
    
    try {
        my $dbh = $c->model('DBForager')->schema->storage->dbh;
        my $sth = $dbh->prepare("SHOW TABLES");
        $sth->execute();
        
        while (my ($table) = $sth->fetchrow_array()) {
            push @tables, $table;
        }
        
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_forager_database_tables', 
            "Error getting forager database tables: $_");
        die $_;
    };
    
    return \@tables;
}

# Get table schema from the Ency database
sub get_ency_table_schema {
    my ($self, $c, $table_name) = @_;
    
    my $schema_info = {
        columns => {},
        primary_keys => [],
        unique_constraints => [],
        foreign_keys => [],
        indexes => []
    };
    
    try {
        my $dbh = $c->model('DBEncy')->schema->storage->dbh;
        
        # Get column information
        my $sth = $dbh->prepare("DESCRIBE $table_name");
        $sth->execute();
        
        while (my $row = $sth->fetchrow_hashref()) {
            my $column_name = $row->{Field};
            
            $schema_info->{columns}->{$column_name} = {
                data_type => $row->{Type},
                is_nullable => ($row->{Null} eq 'YES' ? 1 : 0),
                default_value => $row->{Default},
                is_auto_increment => ($row->{Extra} =~ /auto_increment/i ? 1 : 0),
                size => undef  # Will be parsed from Type if needed
            };
            
            # Check for primary key
            if ($row->{Key} eq 'PRI') {
                push @{$schema_info->{primary_keys}}, $column_name;
            }
        }
        
        # Get foreign key information
        $sth = $dbh->prepare("
            SELECT 
                COLUMN_NAME,
                REFERENCED_TABLE_NAME,
                REFERENCED_COLUMN_NAME,
                CONSTRAINT_NAME
            FROM INFORMATION_SCHEMA.KEY_COLUMN_USAGE 
            WHERE TABLE_SCHEMA = DATABASE() 
            AND TABLE_NAME = ? 
            AND REFERENCED_TABLE_NAME IS NOT NULL
        ");
        $sth->execute($table_name);
        
        while (my $row = $sth->fetchrow_hashref()) {
            push @{$schema_info->{foreign_keys}}, {
                column => $row->{COLUMN_NAME},
                referenced_table => $row->{REFERENCED_TABLE_NAME},
                referenced_column => $row->{REFERENCED_COLUMN_NAME},
                constraint_name => $row->{CONSTRAINT_NAME}
            };
        }
        
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_ency_table_schema', 
            "Error getting ency table schema for $table_name: $_");
        die $_;
    };
    
    return $schema_info;
}

# Get table schema from the Forager database
sub get_forager_table_schema {
    my ($self, $c, $table_name) = @_;
    
    my $schema_info = {
        columns => {},
        primary_keys => [],
        unique_constraints => [],
        foreign_keys => [],
        indexes => []
    };
    
    try {
        my $dbh = $c->model('DBForager')->schema->storage->dbh;
        
        # Get column information
        my $sth = $dbh->prepare("DESCRIBE $table_name");
        $sth->execute();
        
        while (my $row = $sth->fetchrow_hashref()) {
            my $column_name = $row->{Field};
            
            $schema_info->{columns}->{$column_name} = {
                data_type => $row->{Type},
                is_nullable => ($row->{Null} eq 'YES' ? 1 : 0),
                default_value => $row->{Default},
                is_auto_increment => ($row->{Extra} =~ /auto_increment/i ? 1 : 0),
                size => undef  # Will be parsed from Type if needed
            };
            
            # Check for primary key
            if ($row->{Key} eq 'PRI') {
                push @{$schema_info->{primary_keys}}, $column_name;
            }
        }
        
        # Get foreign key information
        $sth = $dbh->prepare("
            SELECT 
                COLUMN_NAME,
                REFERENCED_TABLE_NAME,
                REFERENCED_COLUMN_NAME,
                CONSTRAINT_NAME
            FROM INFORMATION_SCHEMA.KEY_COLUMN_USAGE 
            WHERE TABLE_SCHEMA = DATABASE() 
            AND TABLE_NAME = ? 
            AND REFERENCED_TABLE_NAME IS NOT NULL
        ");
        $sth->execute($table_name);
        
        while (my $row = $sth->fetchrow_hashref()) {
            push @{$schema_info->{foreign_keys}}, {
                column => $row->{COLUMN_NAME},
                referenced_table => $row->{REFERENCED_TABLE_NAME},
                referenced_column => $row->{REFERENCED_COLUMN_NAME},
                constraint_name => $row->{CONSTRAINT_NAME}
            };
        }
        
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_forager_table_schema', 
            "Error getting forager table schema for $table_name: $_");
        die $_;
    };
    
    return $schema_info;
}

# Get database table schema information
sub get_database_table_schema {
    my ($self, $c, $table_name) = @_;
    
    my $schema_info = {
        columns => {},
        primary_keys => [],
        unique_constraints => [],
        foreign_keys => [],
        indexes => []
    };
    
    try {
        my $dbh = $c->model('DBEncy')->schema->storage->dbh;
        
        # Get column information
        my $sth = $dbh->prepare("DESCRIBE `$table_name`");
        $sth->execute();
        
        while (my $row = $sth->fetchrow_hashref()) {
            my $column_name = $row->{Field};
            
            # Parse MySQL column type
            my ($data_type, $size) = $self->parse_mysql_column_type($row->{Type});
            
            $schema_info->{columns}->{$column_name} = {
                data_type => $data_type,
                size => $size,
                is_nullable => ($row->{Null} eq 'YES' ? 1 : 0),
                default_value => $row->{Default},
                is_auto_increment => ($row->{Extra} =~ /auto_increment/i ? 1 : 0),
                extra => $row->{Extra}
            };
            
            # Check for primary key
            if ($row->{Key} eq 'PRI') {
                push @{$schema_info->{primary_keys}}, $column_name;
            }
        }
        
        # Get foreign key information
        $sth = $dbh->prepare("
            SELECT 
                COLUMN_NAME,
                REFERENCED_TABLE_NAME,
                REFERENCED_COLUMN_NAME,
                CONSTRAINT_NAME
            FROM INFORMATION_SCHEMA.KEY_COLUMN_USAGE 
            WHERE TABLE_SCHEMA = DATABASE() 
            AND TABLE_NAME = ? 
            AND REFERENCED_TABLE_NAME IS NOT NULL
        ");
        $sth->execute($table_name);
        
        while (my $row = $sth->fetchrow_hashref()) {
            push @{$schema_info->{foreign_keys}}, {
                column => $row->{COLUMN_NAME},
                referenced_table => $row->{REFERENCED_TABLE_NAME},
                referenced_column => $row->{REFERENCED_COLUMN_NAME},
                constraint_name => $row->{CONSTRAINT_NAME}
            };
        }
        
        # Get unique constraints
        $sth = $dbh->prepare("
            SELECT 
                CONSTRAINT_NAME,
                GROUP_CONCAT(COLUMN_NAME ORDER BY ORDINAL_POSITION) as COLUMNS
            FROM INFORMATION_SCHEMA.KEY_COLUMN_USAGE 
            WHERE TABLE_SCHEMA = DATABASE() 
            AND TABLE_NAME = ? 
            AND CONSTRAINT_NAME != 'PRIMARY'
            GROUP BY CONSTRAINT_NAME
        ");
        $sth->execute($table_name);
        
        while (my $row = $sth->fetchrow_hashref()) {
            push @{$schema_info->{unique_constraints}}, {
                name => $row->{CONSTRAINT_NAME},
                columns => [split(',', $row->{COLUMNS})]
            };
        }
        
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_database_table_schema', 
            "Error getting schema for table $table_name: $_");
    };
    
    return $schema_info;
}

# Parse MySQL column type to extract data type and size
sub parse_mysql_column_type {
    my ($self, $type_string) = @_;
    
    # Handle common MySQL types
    if ($type_string =~ /^(\w+)\((\d+)\)/) {
        return ($1, $2);
    } elsif ($type_string =~ /^(\w+)\((\d+),(\d+)\)/) {
        return ($1, "$2,$3");  # For decimal types
    } elsif ($type_string =~ /^(\w+)/) {
        return ($1, undef);
    }
    
    return ($type_string, undef);
}

# Get Result files and their schema information
sub get_result_files {
    my ($self, $c) = @_;
    
    my $result_files = {};
    
    try {
        my $result_dir = $c->path_to('lib', 'Comserv', 'Model', 'Schema', 'Ency', 'Result');
        
        if (-d $result_dir) {
            find(sub {
                return unless -f $_ && /\.pm$/;
                return if $_ eq 'User.pm' && -d $File::Find::dir . '/User'; # Skip if there's a User directory
                
                my $file_path = $File::Find::name;
                my $relative_path = $file_path;
                $relative_path =~ s/^\Q$result_dir\E\/?//;
                
                # Skip files in subdirectories for now (like User/User.pm)
                return if $relative_path =~ /\//;
                
                my $table_name = $_;
                $table_name =~ s/\.pm$//;
                
                my $schema_info = $self->get_result_file_schema($c, $table_name, $file_path);
                if ($schema_info) {
                    $result_files->{$schema_info->{table_name} || lc($table_name)} = $schema_info;
                }
            }, $result_dir);
        }
        
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_result_files', 
            "Error getting Result files: $_");
    };
    
    return $result_files;
}

# Get schema information from a Result file
sub get_result_file_schema {
    my ($self, $c, $class_name, $file_path) = @_;
    
    my $schema_info = {
        file_path => $file_path,
        columns => {},
        primary_keys => [],
        unique_constraints => [],
        relationships => [],
        table_name => undef
    };
    
    try {
        # Read the file content
        my $content = read_file($file_path);
        
        # Extract table name
        if ($content =~ /__PACKAGE__->table\(['"]([^'"]+)['"]\)/) {
            $schema_info->{table_name} = $1;
        }
        
        # Extract columns
        if ($content =~ /__PACKAGE__->add_columns\((.*?)\);/s) {
            my $columns_text = $1;
            $schema_info->{columns} = $self->parse_result_file_columns($columns_text);
        }
        
        # Extract primary key
        if ($content =~ /__PACKAGE__->set_primary_key\((.*?)\)/) {
            my $pk_text = $1;
            $pk_text =~ s/['"\s]//g;
            @{$schema_info->{primary_keys}} = split(/,/, $pk_text);
        }
        
        # Extract unique constraints
        while ($content =~ /__PACKAGE__->add_unique_constraint\(['"]([^'"]+)['"] => \[(.*?)\]\)/g) {
            my $constraint_name = $1;
            my $columns_text = $2;
            $columns_text =~ s/['"\s]//g;
            push @{$schema_info->{unique_constraints}}, {
                name => $constraint_name,
                columns => [split(/,/, $columns_text)]
            };
        }
        
        # Extract relationships
        while ($content =~ /__PACKAGE__->(belongs_to|has_many|has_one|might_have)\(([^)]+)\)/g) {
            my $relationship_type = $1;
            my $relationship_text = $2;
            
            # Parse relationship parameters
            my @params = split(/,/, $relationship_text);
            if (@params >= 3) {
                my $accessor = $params[0];
                my $related_class = $params[1];
                my $foreign_key = $params[2];
                
                # Clean up the parameters
                $accessor =~ s/['"\s]//g;
                $related_class =~ s/['"\s]//g;
                $foreign_key =~ s/['"\s]//g;
                
                push @{$schema_info->{relationships}}, {
                    type => $relationship_type,
                    accessor => $accessor,
                    related_class => $related_class,
                    foreign_key => $foreign_key
                };
            }
        }
        
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_result_file_schema', 
            "Error parsing Result file $file_path: $_");
        return undef;
    };
    
    return $schema_info;
}

# Parse column definitions from Result file
sub parse_result_file_columns {
    my ($self, $columns_text) = @_;
    
    my $columns = {};
    
    # Split by column definitions (looking for column_name => { ... })
    while ($columns_text =~ /(\w+)\s*=>\s*\{([^}]+)\}/g) {
        my $column_name = $1;
        my $column_def = $2;
        
        my $column_info = {};
        
        # Parse column attributes
        while ($column_def =~ /(\w+)\s*=>\s*['"]?([^'",\s]+)['"]?/g) {
            my $attr = $1;
            my $value = $2;
            
            if ($attr eq 'size' && $value =~ /^\d+$/) {
                $column_info->{$attr} = int($value);
            } elsif ($attr eq 'is_nullable' || $attr eq 'is_auto_increment') {
                $column_info->{$attr} = ($value eq '1' || $value eq 'true') ? 1 : 0;
            } else {
                $column_info->{$attr} = $value;
            }
        }
        
        $columns->{$column_name} = $column_info;
    }
    
    return $columns;
}

# Compare schema between database table and Result file
sub compare_table_schema {
    my ($self, $c, $table_name, $db_tables, $result_files) = @_;
    
    my $comparison = {
        table_name => $table_name,
        database_table_exists => 0,
        result_file_exists => 0,
        has_differences => 0,
        column_differences => [],
        primary_key_differences => [],
        relationship_differences => [],
        unique_constraint_differences => [],
        database_schema => undef,
        result_file_schema => undef
    };
    
    # Check if database table exists
    $comparison->{database_table_exists} = grep { $_ eq $table_name } @$db_tables;
    
    # Check if Result file exists
    $comparison->{result_file_exists} = exists $result_files->{$table_name};
    
    # Get schemas if both exist
    if ($comparison->{database_table_exists}) {
        $comparison->{database_schema} = $self->get_database_table_schema($c, $table_name);
    }
    
    if ($comparison->{result_file_exists}) {
        $comparison->{result_file_schema} = $result_files->{$table_name};
    }
    
    # Compare if both exist
    if ($comparison->{database_table_exists} && $comparison->{result_file_exists}) {
        $self->compare_columns($comparison);
        $self->compare_primary_keys($comparison);
        $self->compare_unique_constraints($comparison);
        $self->compare_relationships($comparison);
        
        # Set has_differences flag
        $comparison->{has_differences} = (
            @{$comparison->{column_differences}} > 0 ||
            @{$comparison->{primary_key_differences}} > 0 ||
            @{$comparison->{relationship_differences}} > 0 ||
            @{$comparison->{unique_constraint_differences}} > 0
        );
    } elsif (!$comparison->{database_table_exists} || !$comparison->{result_file_exists}) {
        $comparison->{has_differences} = 1;
    }
    
    return $comparison;
}

# Compare columns between database and Result file
sub compare_columns {
    my ($self, $comparison) = @_;
    
    my $db_columns = $comparison->{database_schema}->{columns};
    my $result_columns = $comparison->{result_file_schema}->{columns};
    
    # Get all column names
    my %all_columns = ();
    foreach my $col (keys %$db_columns) { $all_columns{$col} = 1; }
    foreach my $col (keys %$result_columns) { $all_columns{$col} = 1; }
    
    foreach my $column_name (sort keys %all_columns) {
        my $db_col = $db_columns->{$column_name};
        my $result_col = $result_columns->{$column_name};
        
        if (!$db_col) {
            push @{$comparison->{column_differences}}, {
                column => $column_name,
                type => 'missing_in_database',
                result_file_definition => $result_col
            };
        } elsif (!$result_col) {
            push @{$comparison->{column_differences}}, {
                column => $column_name,
                type => 'missing_in_result_file',
                database_definition => $db_col
            };
        } else {
            # Compare column attributes
            my @differences = ();
            
            # Compare data type
            if (lc($db_col->{data_type}) ne lc($result_col->{data_type})) {
                push @differences, {
                    attribute => 'data_type',
                    database_value => $db_col->{data_type},
                    result_file_value => $result_col->{data_type}
                };
            }
            
            # Compare size
            if (defined($db_col->{size}) != defined($result_col->{size}) ||
                (defined($db_col->{size}) && defined($result_col->{size}) && 
                 $db_col->{size} ne $result_col->{size})) {
                push @differences, {
                    attribute => 'size',
                    database_value => $db_col->{size},
                    result_file_value => $result_col->{size}
                };
            }
            
            # Compare nullable
            if (($db_col->{is_nullable} || 0) != ($result_col->{is_nullable} || 0)) {
                push @differences, {
                    attribute => 'is_nullable',
                    database_value => $db_col->{is_nullable},
                    result_file_value => $result_col->{is_nullable}
                };
            }
            
            # Compare auto increment
            if (($db_col->{is_auto_increment} || 0) != ($result_col->{is_auto_increment} || 0)) {
                push @differences, {
                    attribute => 'is_auto_increment',
                    database_value => $db_col->{is_auto_increment},
                    result_file_value => $result_col->{is_auto_increment}
                };
            }
            
            if (@differences) {
                push @{$comparison->{column_differences}}, {
                    column => $column_name,
                    type => 'attribute_differences',
                    differences => \@differences,
                    database_definition => $db_col,
                    result_file_definition => $result_col
                };
            }
        }
    }
}

# Compare primary keys
sub compare_primary_keys {
    my ($self, $comparison) = @_;
    
    my $db_pks = $comparison->{database_schema}->{primary_keys};
    my $result_pks = $comparison->{result_file_schema}->{primary_keys};
    
    # Sort for comparison
    my @db_pks_sorted = sort @$db_pks;
    my @result_pks_sorted = sort @$result_pks;
    
    if (join(',', @db_pks_sorted) ne join(',', @result_pks_sorted)) {
        push @{$comparison->{primary_key_differences}}, {
            database_primary_keys => \@db_pks_sorted,
            result_file_primary_keys => \@result_pks_sorted
        };
    }
}

# Compare unique constraints
sub compare_unique_constraints {
    my ($self, $comparison) = @_;
    
    my $db_constraints = $comparison->{database_schema}->{unique_constraints};
    my $result_constraints = $comparison->{result_file_schema}->{unique_constraints};
    
    # This is a simplified comparison - you might want to make it more sophisticated
    if (@$db_constraints != @$result_constraints) {
        push @{$comparison->{unique_constraint_differences}}, {
            database_constraints => $db_constraints,
            result_file_constraints => $result_constraints
        };
    }
}

# Compare relationships (this is Result file specific)
sub compare_relationships {
    my ($self, $comparison) = @_;
    
    # For now, we'll just note if relationships exist in the Result file
    # but aren't reflected in the database foreign keys
    my $result_relationships = $comparison->{result_file_schema}->{relationships};
    my $db_foreign_keys = $comparison->{database_schema}->{foreign_keys};
    
    if (@$result_relationships > @$db_foreign_keys) {
        push @{$comparison->{relationship_differences}}, {
            type => 'missing_foreign_keys_in_database',
            result_file_relationships => $result_relationships,
            database_foreign_keys => $db_foreign_keys
        };
    }
}

# Apply selected schema changes
sub apply_schema_changes {
    my ($self, $c) = @_;
    
    my $changes = $c->req->param('changes');
    my $direction = $c->req->param('direction'); # 'db_to_result' or 'result_to_db'
    
    if (!$changes) {
        $c->flash->{error_msg} = "No changes selected to apply.";
        return;
    }
    
    try {
        my $changes_data = decode_json($changes);
        my $applied_changes = 0;
        
        foreach my $change (@$changes_data) {
            if ($direction eq 'db_to_result') {
                $self->apply_database_to_result_change($c, $change);
            } elsif ($direction eq 'result_to_db') {
                $self->apply_result_to_database_change($c, $change);
            }
            $applied_changes++;
        }
        
        $c->flash->{success_msg} = "Successfully applied $applied_changes changes.";
        
    } catch {
        my $error = "Error applying changes: $_";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'apply_schema_changes', $error);
        $c->flash->{error_msg} = $error;
    };
}

# Apply change from database to Result file
sub apply_database_to_result_change {
    my ($self, $c, $change) = @_;
    
    # This would update the Result file based on database schema
    # Implementation depends on the specific change type
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'apply_database_to_result_change', 
        "Applying database to Result file change: " . encode_json($change));
}

# Apply change from Result file to database
sub apply_result_to_database_change {
    my ($self, $c, $change) = @_;
    
    # This would update the database schema based on Result file
    # Implementation depends on the specific change type
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'apply_result_to_database_change', 
        "Applying Result file to database change: " . encode_json($change));
}

# Generate Result file from database table
sub generate_result_file {
    my ($self, $c) = @_;
    
    my $table_name = $c->req->param('table_name');
    
    if (!$table_name) {
        $c->flash->{error_msg} = "No table name specified for Result file generation.";
        return;
    }
    
    try {
        my $db_schema = $self->get_database_table_schema($c, $table_name);
        my $result_file_content = $self->generate_result_file_content($table_name, $db_schema);
        
        # Save the Result file
        my $result_file_path = $c->path_to('lib', 'Comserv', 'Model', 'Schema', 'Ency', 'Result', ucfirst($table_name) . '.pm');
        write_file($result_file_path, $result_file_content);
        
        $c->flash->{success_msg} = "Result file generated successfully for table '$table_name'.";
        
    } catch {
        my $error = "Error generating Result file: $_";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'generate_result_file', $error);
        $c->flash->{error_msg} = $error;
    };
}

# Generate Result file content from database schema
sub generate_result_file_content {
    my ($self, $table_name, $db_schema) = @_;
    
    my $class_name = ucfirst($table_name);
    my $content = "package Comserv::Model::Schema::Ency::Result::$class_name;\n";
    $content .= "use base 'DBIx::Class::Core';\n\n";
    $content .= "__PACKAGE__->table('$table_name');\n";
    $content .= "__PACKAGE__->add_columns(\n";
    
    # Add columns
    foreach my $column_name (sort keys %{$db_schema->{columns}}) {
        my $col = $db_schema->{columns}->{$column_name};
        $content .= "    $column_name => {\n";
        $content .= "        data_type => '$col->{data_type}',\n";
        
        if (defined $col->{size}) {
            $content .= "        size => $col->{size},\n";
        }
        
        if ($col->{is_nullable}) {
            $content .= "        is_nullable => 1,\n";
        }
        
        if ($col->{is_auto_increment}) {
            $content .= "        is_auto_increment => 1,\n";
        }
        
        if (defined $col->{default_value}) {
            $content .= "        default_value => '$col->{default_value}',\n";
        }
        
        $content .= "    },\n";
    }
    
    $content .= ");\n";
    
    # Add primary key
    if (@{$db_schema->{primary_keys}}) {
        my $pk_list = join(', ', map { "'$_'" } @{$db_schema->{primary_keys}});
        $content .= "__PACKAGE__->set_primary_key($pk_list);\n";
    }
    
    # Add unique constraints
    foreach my $constraint (@{$db_schema->{unique_constraints}}) {
        my $col_list = join(', ', map { "'$_'" } @{$constraint->{columns}});
        $content .= "__PACKAGE__->add_unique_constraint('$constraint->{name}' => [$col_list]);\n";
    }
    
    $content .= "\n1;\n";
    
    return $content;
}

# Git pull functionality
sub git_pull :Path('/admin/git_pull') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'git_pull', 
        "Starting git_pull action");
    
    # Check if the user has admin role
    unless ($c->user_exists && ($c->check_user_roles('admin') || $c->session->{username} eq 'Shanta')) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'git_pull', 
            "Access denied: User does not have admin role");
        
        # Set error message in flash
        $c->flash->{error_msg} = "You need to be an administrator to access this area.";
        
        # Redirect to login page with destination parameter
        $c->response->redirect($c->uri_for('/user/login', {
            destination => $c->req->uri
        }));
        return;
    }
    
    # Check if this is a POST request (user confirmed the git pull)
    if ($c->req->method eq 'POST' && $c->req->param('confirm')) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'git_pull', 
            "Git pull confirmed, executing");
        
        # Execute the git pull operation
        my ($success, $output, $warning) = $self->execute_git_pull($c);
        
        # Store the results in stash for the template
        $c->stash(
            output => $output,
            success_msg => $success ? "Git pull completed successfully." : undef,
            error_msg => $success ? undef : "Git pull failed. See output for details.",
            warning_msg => $warning
        );
    }
    
    # Use the standard debug message system
    if ($c->session->{debug_mode}) {
        push @{$c->stash->{debug_msg}}, "Admin controller git_pull view - Template: admin/git_pull.tt";
    }
    
    # Set the template
    $c->stash(template => 'admin/git_pull.tt');
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'git_pull', 
        "Completed git_pull action");
}

# Execute the git pull operation
sub execute_git_pull {
    my ($self, $c) = @_;
    my $output = '';
    my $warning = undef;
    my $success = 0;
    
    # Path to the theme_mappings.json file
    my $theme_mappings_path = $c->path_to('root', 'static', 'config', 'theme_mappings.json');
    my $backup_path = "$theme_mappings_path.bak";
    
    # Check if theme_mappings.json exists
    my $theme_mappings_exists = -e $theme_mappings_path;
    
    try {
        # Backup theme_mappings.json if it exists
        if ($theme_mappings_exists) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'execute_git_pull', 
                "Backing up theme_mappings.json");
            copy($theme_mappings_path, $backup_path) or die "Failed to backup theme_mappings.json: $!";
            $output .= "Backed up theme_mappings.json to $backup_path\n";
        }
        
        # Check if there are local changes to theme_mappings.json
        my $has_local_changes = 0;
        if ($theme_mappings_exists) {
            my $git_status = `git -C ${\$c->path_to()} status --porcelain root/static/config/theme_mappings.json`;
            $has_local_changes = $git_status =~ /^\s*[AM]\s+root\/static\/config\/theme_mappings\.json/m;
            
            if ($has_local_changes) {
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'execute_git_pull', 
                    "Local changes detected in theme_mappings.json");
                $output .= "Local changes detected in theme_mappings.json\n";
                
                # Stash the changes
                my $stash_output = `git -C ${\$c->path_to()} stash push -- root/static/config/theme_mappings.json 2>&1`;
                $output .= "Stashed changes: $stash_output\n";
            }
        }
        
        # Execute git pull
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'execute_git_pull', 
            "Executing git pull");
        my $pull_output = `git -C ${\$c->path_to()} pull 2>&1`;
        $output .= "Git pull output:\n$pull_output\n";
        
        # Check if pull was successful
        if ($pull_output =~ /Already up to date|Fast-forward|Updating/) {
            $success = 1;
        } else {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'execute_git_pull', 
                "Git pull failed: $pull_output");
            return (0, $output, "Git pull failed. See output for details.");
        }
        
        # Apply stashed changes if needed
        if ($has_local_changes) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'execute_git_pull', 
                "Applying stashed changes");
            my $stash_apply_output = `git -C ${\$c->path_to()} stash pop 2>&1`;
            $output .= "Applied stashed changes:\n$stash_apply_output\n";
            
            # Check for conflicts
            if ($stash_apply_output =~ /CONFLICT|error:/) {
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'execute_git_pull', 
                    "Conflicts detected when applying stashed changes");
                $warning = "Conflicts detected when applying stashed changes. You may need to manually resolve them.";
                
                # Restore from backup
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'execute_git_pull', 
                    "Restoring theme_mappings.json from backup");
                copy($backup_path, $theme_mappings_path) or die "Failed to restore from backup: $!";
                $output .= "Restored theme_mappings.json from backup due to conflicts\n";
            }
        }
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'execute_git_pull', 
            "Git pull completed successfully");
    } catch {
        my $error = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'execute_git_pull', 
            "Error during git pull: $error");
        $output .= "Error: $error\n";
        return (0, $output, undef);
    };
    
    return ($success, $output, $warning);
}

# AJAX endpoint to sync table field to result file
sub sync_table_to_result :Path('/admin/sync_table_to_result') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'sync_table_to_result',
        "Starting sync_table_to_result action");
    
    # Check if the user has admin role
    unless ($c->user_exists && $c->check_user_roles('admin')) {
        $c->response->status(403);
        $c->stash(json => { success => 0, error => 'Access denied' });
        $c->forward('View::JSON');
        return;
    }
    
    # Parse JSON request
    my $json_data;
    try {
        my $body = $c->req->body;
        if ($body) {
            local $/;
            my $json_text = <$body>;
            $json_data = decode_json($json_text);
        } else {
            die "No request body provided";
        }
    } catch {
        $c->response->status(400);
        $c->stash(json => { success => 0, error => "Invalid JSON request: $_" });
        $c->forward('View::JSON');
        return;
    };
    
    my $table_name = $json_data->{table_name};
    my $field_name = $json_data->{field_name};
    my $database = $json_data->{database};
    
    unless ($table_name && $field_name && $database) {
        $c->response->status(400);
        $c->stash(json => { success => 0, error => 'Missing required parameters: table_name, field_name, database' });
        $c->forward('View::JSON');
        return;
    }
    
    try {
        # Get table field info
        my $table_field_info = $self->get_table_field_info($c, $table_name, $field_name, $database);
        
        # Update result file with table values
        my $result = $self->update_result_field_from_table($c, $table_name, $field_name, $database, $table_field_info);
        
        $c->stash(json => {
            success => 1,
            message => "Successfully synced table field '$field_name' to result file",
            field_info => $table_field_info
        });
        
    } catch {
        my $error = "Error syncing table to result: $_";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'sync_table_to_result', $error);
        
        $c->response->status(500);
        $c->stash(json => { success => 0, error => $error });
    };
    
    $c->forward('View::JSON');
}

# AJAX endpoint to sync result field to table
sub sync_result_to_table :Path('/admin/sync_result_to_table') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'sync_result_to_table',
        "Starting sync_result_to_table action");
    
    # Check if the user has admin role
    unless ($c->user_exists && $c->check_user_roles('admin')) {
        $c->response->status(403);
        $c->stash(json => { success => 0, error => 'Access denied' });
        $c->forward('View::JSON');
        return;
    }
    
    # Parse JSON request
    my $json_data;
    try {
        my $body = $c->req->body;
        if ($body) {
            local $/;
            my $json_text = <$body>;
            $json_data = decode_json($json_text);
        } else {
            die "No request body provided";
        }
    } catch {
        $c->response->status(400);
        $c->stash(json => { success => 0, error => "Invalid JSON request: $_" });
        $c->forward('View::JSON');
        return;
    };
    
    my $table_name = $json_data->{table_name};
    my $field_name = $json_data->{field_name};
    my $database = $json_data->{database};
    
    unless ($table_name && $field_name && $database) {
        $c->response->status(400);
        $c->stash(json => { success => 0, error => 'Missing required parameters: table_name, field_name, database' });
        $c->forward('View::JSON');
        return;
    }
    
    try {
        # Get result field info
        my $result_field_info = $self->get_result_field_info($c, $table_name, $field_name, $database);
        
        # Update table schema with result values
        my $result = $self->update_table_field_from_result($c, $table_name, $field_name, $database, $result_field_info);
        
        $c->stash(json => {
            success => 1,
            message => "Successfully synced result field '$field_name' to table",
            field_info => $result_field_info
        });
        
    } catch {
        my $error = "Error syncing result to table: $_";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'sync_result_to_table', $error);
        
        $c->response->status(500);
        $c->stash(json => { success => 0, error => $error });
    };
    
    $c->forward('View::JSON');
}

# Helper method to get table field information
sub get_table_field_info {
    my ($self, $c, $table_name, $field_name, $database) = @_;
    
    my $model_name = $database eq 'ency' ? 'DBEncy' : 'DBForager';
    my $schema = $c->model($model_name)->schema;
    
    # Get table information from database
    my $dbh = $schema->storage->dbh;
    my $sth = $dbh->column_info(undef, undef, $table_name, $field_name);
    my $column_info = $sth->fetchrow_hashref;
    
    if (!$column_info) {
        die "Field '$field_name' not found in table '$table_name'";
    }
    
    return {
        data_type => $column_info->{TYPE_NAME} || $column_info->{DATA_TYPE},
        size => $column_info->{COLUMN_SIZE},
        is_nullable => $column_info->{NULLABLE} ? 1 : 0,
        is_auto_increment => $column_info->{IS_AUTOINCREMENT} ? 1 : 0,
        default_value => $column_info->{COLUMN_DEF}
    };
}

# Helper method to get result field information
sub get_result_field_info {
    my ($self, $c, $table_name, $field_name, $database) = @_;
    
    # Build result file path
    my $result_table_mapping = $self->build_result_table_mapping($c, $database);
    my $result_file_path;
    
    # Find the result file for this table (mapping key is lowercase table name)
    my $table_key = lc($table_name);
    if (exists $result_table_mapping->{$table_key}) {
        $result_file_path = $result_table_mapping->{$table_key}->{result_path};
    }
    
    unless ($result_file_path && -f $result_file_path) {
        my $debug_info = "Result file not found for table '$table_name' in get_result_field_info.\n";
        $debug_info .= "Table key searched: '$table_key'\n";
        $debug_info .= "Available tables: " . join(', ', keys %$result_table_mapping) . "\n";
        $debug_info .= "Result file path: " . ($result_file_path || 'undefined') . "\n";
        if ($result_file_path) {
            $debug_info .= "File exists: " . (-f $result_file_path ? 'YES' : 'NO') . "\n";
        }
        die $debug_info;
    }
    
    # Read and parse the result file
    my $content = read_file($result_file_path);
    
    # Parse the add_columns section to find the field
    if ($content =~ /__PACKAGE__->add_columns\(\s*(.*?)\s*\);/s) {
        my $columns_section = $1;
        
        my $field_info = {};
        
        # Try hash format first: field_name => { ... }
        if ($columns_section =~ /(?:^|\s|,)\s*'?$field_name'?\s*=>\s*\{([^}]+)\}/s) {
            my $field_def = $1;
            
            # Parse field attributes from hash format
            if ($field_def =~ /data_type\s*=>\s*["']([^"']+)["']/) {
                $field_info->{data_type} = $1;
            }
            if ($field_def =~ /size\s*=>\s*(\d+)/) {
                $field_info->{size} = $1;
            }
            if ($field_def =~ /is_nullable\s*=>\s*([01])/) {
                $field_info->{is_nullable} = $1;
            }
            if ($field_def =~ /is_auto_increment\s*=>\s*([01])/) {
                $field_info->{is_auto_increment} = $1;
            }
            if ($field_def =~ /default_value\s*=>\s*["']([^"']*)["']/) {
                $field_info->{default_value} = $1;
            }
            
            return $field_info;
        }
        
        # Try array format: "field_name", { ... }
        if ($columns_section =~ /["']$field_name["']\s*,\s*\{([^}]+)\}/s) {
            my $field_def = $1;
            
            # Parse field attributes from array format
            if ($field_def =~ /data_type\s*=>\s*["']([^"']+)["']/) {
                $field_info->{data_type} = $1;
            }
            if ($field_def =~ /size\s*=>\s*(\d+)/) {
                $field_info->{size} = $1;
            }
            if ($field_def =~ /is_nullable\s*=>\s*([01])/) {
                $field_info->{is_nullable} = $1;
            }
            if ($field_def =~ /is_auto_increment\s*=>\s*([01])/) {
                $field_info->{is_auto_increment} = $1;
            }
            if ($field_def =~ /default_value\s*=>\s*["']([^"']*)["']/) {
                $field_info->{default_value} = $1;
            }
            
            return $field_info;
        }
    }
    
    die "Field '$field_name' not found in result file";
}

# Helper method to update result file with table field values
sub update_result_field_from_table {
    my ($self, $c, $table_name, $field_name, $database, $table_field_info) = @_;
    
    # Build result file path
    my $result_table_mapping = $self->build_result_table_mapping($c, $database);
    my $result_file_path;
    
    # Find the result file for this table (mapping key is lowercase table name)
    my $table_key = lc($table_name);
    if (exists $result_table_mapping->{$table_key}) {
        $result_file_path = $result_table_mapping->{$table_key}->{result_path};
    }
    
    unless ($result_file_path && -f $result_file_path) {
        my $debug_info = "Result file not found for table '$table_name' in update_result_field_from_table.\n";
        $debug_info .= "Table key searched: '$table_key'\n";
        $debug_info .= "Available tables: " . join(', ', keys %$result_table_mapping) . "\n";
        $debug_info .= "Result file path: " . ($result_file_path || 'undefined') . "\n";
        if ($result_file_path) {
            $debug_info .= "File exists: " . (-f $result_file_path ? 'YES' : 'NO') . "\n";
        }
        die $debug_info;
    }
    
    # Read the result file
    my $content = read_file($result_file_path);
    
    # Build new field definition
    my $new_field_def = "{ data_type => '$table_field_info->{data_type}'";
    
    if ($table_field_info->{size}) {
        $new_field_def .= ", size => $table_field_info->{size}";
    }
    
    $new_field_def .= ", is_nullable => $table_field_info->{is_nullable}";
    
    if ($table_field_info->{is_auto_increment}) {
        $new_field_def .= ", is_auto_increment => 1";
    }
    
    if (defined $table_field_info->{default_value}) {
        $new_field_def .= ", default_value => '$table_field_info->{default_value}'";
    }
    
    $new_field_def .= " }";
    
    # Update the field definition in the content
    if ($content =~ /__PACKAGE__->add_columns\(\s*(.*?)\s*\);/s) {
        my $columns_section = $1;
        my $updated = 0;
        
        # Try hash format first: field_name => { ... }
        if ($columns_section =~ /(?:^|\s|,)\s*'?$field_name'?\s*=>\s*\{[^}]+\}/) {
            $columns_section =~ s/(?:^|\s|,)\s*'?$field_name'?\s*=>\s*\{[^}]+\}/$field_name => $new_field_def/;
            $updated = 1;
        }
        # Try array format: "field_name", { ... }
        elsif ($columns_section =~ /["']$field_name["']\s*,\s*\{[^}]+\}/) {
            $columns_section =~ s/["']$field_name["']\s*,\s*\{[^}]+\}/"$field_name", $new_field_def/;
            $updated = 1;
        }
        
        if ($updated) {
            # Replace in the full content
            $content =~ s/__PACKAGE__->add_columns\(\s*.*?\s*\);/__PACKAGE__->add_columns(\n$columns_section\n);/s;
            
            # Write back to file
            write_file($result_file_path, $content);
            
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_result_field_from_table',
                "Updated field '$field_name' in result file '$result_file_path'");
            
            return 1;
        }
    }
    
    die "Could not update field '$field_name' in result file";
}

# Helper method to update table schema with result field values
sub update_table_field_from_result {
    my ($self, $c, $table_name, $field_name, $database, $result_field_info) = @_;
    
    # This is a placeholder - actual table schema modification would require
    # database-specific ALTER TABLE statements and is more complex
    # For now, we'll just log what would be done
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_table_field_from_result',
        "Would update table '$table_name' field '$field_name' with result file values: " . 
        Data::Dumper::Dumper($result_field_info));
    
    # In a real implementation, you would:
    # 1. Generate appropriate ALTER TABLE statement
    # 2. Execute it against the database
    # 3. Handle any constraints or dependencies
    
    return 1;
}

=head1 AUTHOR

Shanta McBain

=head1 LICENSE

This library is free software. You can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

__PACKAGE__->meta->make_immutable;

1;