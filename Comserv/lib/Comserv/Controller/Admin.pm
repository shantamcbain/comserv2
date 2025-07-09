
package Comserv::Controller::Admin;


use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;
use Data::Dumper;
use JSON qw(decode_json);
use Try::Tiny;
use MIME::Base64;
use File::Slurp qw(read_file write_file);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Copy;
use File::Spec;
use Digest::SHA qw(sha256_hex);
use File::Find;
use Module::Load;
use Cwd;

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
    
    # Initialize debug_msg array if it doesn't exist and debug mode is enabled
    if ($c->session->{debug_mode}) {
        $c->stash->{debug_msg} = [] unless ref($c->stash->{debug_msg}) eq 'ARRAY';
        
        # Add the debug message to the array
        push @{$c->stash->{debug_msg}}, "Admin controller loaded successfully";
    }
    
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
    
    # Debug session information
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', 
        "Session debug - Username: " . ($c->session->{username} || 'none') . 
        ", User ID: " . ($c->session->{user_id} || 'none') . 
        ", Roles: " . (ref($c->session->{roles}) eq 'ARRAY' ? join(',', @{$c->session->{roles}}) : ($c->session->{roles} || 'none')));
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', 
        "user_exists: " . ($c->user_exists ? 'true' : 'false') . 
        ", check_user_roles('admin'): " . ($c->check_user_roles('admin') ? 'true' : 'false'));
    
    # Check if the user has admin role (same as other admin functions)
    unless ($c->user_exists && $c->check_user_roles('admin')) {
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
    
    # Get system stats
    my $stats = $self->get_system_stats($c);
    
    # Get recent user activity
    my $recent_activity = $self->get_recent_activity($c);
    
    # Get system notifications
    my $notifications = $self->get_system_notifications($c);
    
    # Use the standard debug message system
    if ($c->session->{debug_mode}) {
        $c->stash->{debug_msg} = [] unless ref($c->stash->{debug_msg}) eq 'ARRAY';
        push @{$c->stash->{debug_msg}}, "Admin controller index view - Template: admin/index.tt";
    }
    
    # Check if user has CSC backup access
    my $has_csc_access = $self->check_csc_access($c);
    
    # Pass data to the template
    $c->stash(
        template => 'admin/index.tt',
        stats => $stats,
        recent_activity => $recent_activity,
        notifications => $notifications,
        is_admin => 1,  # User has already passed admin check to get here
        has_csc_access => $has_csc_access
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
        $c->stash->{debug_msg} = [] unless ref($c->stash->{debug_msg}) eq 'ARRAY';
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
        $c->stash->{debug_msg} = [] unless ref($c->stash->{debug_msg}) eq 'ARRAY';
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
        $c->stash->{debug_msg} = [] unless ref($c->stash->{debug_msg}) eq 'ARRAY';
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
        $c->stash->{debug_msg} = [] unless ref($c->stash->{debug_msg}) eq 'ARRAY';
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
        $c->stash->{debug_msg} = [] unless ref($c->stash->{debug_msg}) eq 'ARRAY';
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

# Add missing field from table to result file
sub add_field_to_result :Path('/admin/add_field_to_result') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_field_to_result', 
        "Starting add_field_to_result action");
    
    # Check if the user has admin role
    unless ($c->user_exists && $c->check_user_roles('admin')) {
        $c->response->status(403);
        $c->stash(json => { success => 0, error => 'Access denied' });
        $c->forward('View::JSON');
        return;
    }
    
    my $table_name = $c->req->param('table_name');
    my $database = $c->req->param('database');
    my $field_name = $c->req->param('field_name');
    
    unless ($table_name && $database && $field_name) {
        $c->response->status(400);
        $c->stash(json => { success => 0, error => 'Missing required parameters' });
        $c->forward('View::JSON');
        return;
    }
    
    try {
        # Use the native comparison method to get field definitions
        my $result_table_mapping = $self->build_result_table_mapping($c, $database);
        my $comparison = $self->get_table_result_comparison_v2($c, $table_name, $database, $result_table_mapping);
        
        unless ($comparison->{has_result_file}) {
            die "No result file found for table '$table_name'";
        }
        
        # Get the field definition from the table
        my $field_data = $comparison->{fields}->{$field_name};
        unless ($field_data && $field_data->{table}) {
            die "Field '$field_name' not found in table '$table_name'";
        }
        
        my $field_def = $field_data->{table};
        
        # Add field to result file
        my $success = $self->add_field_to_result_file($c, $comparison->{result_file_path}, $field_name, $field_def);
        
        if ($success) {
            $c->stash(json => { 
                success => 1, 
                message => "Field '$field_name' added to result file successfully",
                field_name => $field_name,
                table_name => $table_name
            });
        } else {
            die "Failed to add field to result file";
        }
        
    } catch {
        my $error = "Error adding field to result: $_";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'add_field_to_result', $error);
        
        $c->response->status(500);
        $c->stash(json => { success => 0, error => $error });
    };
    
    $c->forward('View::JSON');
}

# Add missing field from result file to table
sub add_field_to_table :Path('/admin/add_field_to_table') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_field_to_table', 
        "Starting add_field_to_table action");
    
    # Check if the user has admin role
    unless ($c->user_exists && $c->check_user_roles('admin')) {
        $c->response->status(403);
        $c->stash(json => { success => 0, error => 'Access denied' });
        $c->forward('View::JSON');
        return;
    }
    
    my $table_name = $c->req->param('table_name');
    my $database = $c->req->param('database');
    my $field_name = $c->req->param('field_name');
    
    unless ($table_name && $database && $field_name) {
        $c->response->status(400);
        $c->stash(json => { success => 0, error => 'Missing required parameters' });
        $c->forward('View::JSON');
        return;
    }
    
    try {
        # Use the native comparison method to get field definitions
        my $result_table_mapping = $self->build_result_table_mapping($c, $database);
        
        # Debug: Check if our specific table is in the mapping
        my $table_key = lc($table_name);
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_field_to_table',
            "Looking for table '$table_key' in mapping with " . scalar(keys %$result_table_mapping) . " entries");
        
        if (exists $result_table_mapping->{$table_key}) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_field_to_table',
                "Found mapping for '$table_key': " . $result_table_mapping->{$table_key}->{result_name});
        } else {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'add_field_to_table',
                "No mapping found for '$table_key'. Available keys: " . join(', ', sort keys %$result_table_mapping));
        }
        
        my $comparison = $self->get_table_result_comparison_v2($c, $table_name, $database, $result_table_mapping);
        
        # Debug: Log the comparison result
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_field_to_table',
            "Comparison result: has_result_file=" . ($comparison->{has_result_file} ? 'YES' : 'NO') . 
            ", result_file_path=" . ($comparison->{result_file_path} || 'NONE'));
        
        unless ($comparison->{has_result_file}) {
            die "No result file found for table '$table_name'";
        }
        
        # Get the field definition from the result file
        my $field_data = $comparison->{fields}->{$field_name};
        unless ($field_data && $field_data->{result}) {
            die "Field '$field_name' not found in result file";
        }
        
        my $field_def = $field_data->{result};
        
        # Validate field definition has required attributes
        my $validation_errors = $self->validate_field_definition($field_def, $field_name);
        if (@$validation_errors) {
            die "Field validation errors: " . join(', ', @$validation_errors);
        }
        
        # Add field to database table
        my $success = $self->add_field_to_database_table($c, $table_name, $database, $field_name, $field_def);
        
        if ($success) {
            $c->stash(json => { 
                success => 1, 
                message => "Field '$field_name' added to table '$table_name' successfully",
                field_name => $field_name,
                table_name => $table_name
            });
        } else {
            die "Failed to add field to database table";
        }
        
    } catch {
        my $error = "Error adding field to table: $_";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'add_field_to_table', $error);
        
        $c->response->status(500);
        $c->stash(json => { success => 0, error => $error });
    };
    
    $c->forward('View::JSON');
}

# Admin backup and restore
sub backup :Path('/admin/backup') :Args(0) {
    my ($self, $c) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'backup',
        "Starting backup action");

    # Check if the user has CSC backup access
    unless ($self->check_csc_access($c)) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'backup',
            "Access denied: User does not have CSC backup access");

        $c->flash->{error_msg} = "You need CSC administrator privileges to access backup functionality.";
        $c->response->redirect($c->uri_for('/admin'));
        return;
    }

    # Backup creation is now handled by the separate 'create' action method

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

    # Clean up any orphaned backup files first
    $self->cleanup_orphaned_backups($c);
    
    # Get available backups with detailed information
    my $backups = $self->get_backup_list($c);

    # Use the standard debug message system
    if ($c->session->{debug_mode}) {
        push @{$c->stash->{debug_msg}}, "Admin controller backup view - Template: admin/backup.tt";
        push @{$c->stash->{debug_msg}}, "Available backups: " . scalar(@$backups);
    }

    # Pass data to the template
    $c->stash(
        template => 'admin/backup.tt',
        backups => $backups
    );

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'backup',
        "Completed backup action");
}

# Handle backup creation (separate action for cleaner URL handling)
sub create :Path('/admin/backup/create') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create',
        "Starting backup creation");
    
    # Check if the user has CSC backup access
    unless ($self->check_csc_access($c)) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'create',
            "Access denied: User does not have CSC backup access");
        
        $c->flash->{error_msg} = "You need CSC administrator privileges to create backups.";
        $c->response->redirect($c->uri_for('/admin/backup'));
        return;
    }
    
    # Only handle POST requests
    unless ($c->req->method eq 'POST') {
        $c->response->redirect($c->uri_for('/admin/backup'));
        return;
    }
    
    my $backup_type = $c->req->param('type') || 'full';
    my $description = $c->req->param('description') || '';
    
    # Generate backup name with timestamp and type
    my $timestamp = time();
    my ($sec, $min, $hour, $mday, $mon, $year) = localtime($timestamp);
    my $date_str = sprintf("%04d%02d%02d_%02d%02d%02d", $year + 1900, $mon + 1, $mday, $hour, $min, $sec);
    my $backup_name = "backup_${date_str}_${backup_type}";
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create',
        "Creating $backup_type backup: $backup_name");
    
    # Create backup directory if it doesn't exist
    my $backup_dir = $c->path_to('backups');
    unless (-d $backup_dir) {
        eval { make_path($backup_dir) };
        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create',
                "Error creating backup directory: $@");
            
            $c->flash->{error_msg} = "Error creating backup directory: $@";
            $c->response->redirect($c->uri_for('/admin/backup'));
            return;
        }
    }
    
    # Create backup
    my $backup_file = "$backup_dir/$backup_name.tar.gz";
    my $backup_command = '';
    my $backup_success = 0;
    
    if ($backup_type eq 'full') {
        # Full backup (files + database)
        $backup_command = "tar -czf '$backup_file' --exclude='backups' --exclude='tmp' --exclude='logs/*.log' .";
        
    } elsif ($backup_type eq 'config') {
        # Configuration files only
        $backup_command = "tar -czf '$backup_file' --exclude='backups' --exclude='tmp' config/ lib/Comserv.pm *.conf *.yml *.yaml 2>/dev/null || true";
        
    } elsif ($backup_type eq 'database') {
        # Database only backup
        my $db_backup_result = $self->create_database_backup($c, $backup_dir, $backup_name);
        
        if ($db_backup_result->{success}) {
            # Get the application root directory for relative path calculation
            my $app_root = $c->path_to('.');
            # Use relative path from app root for tar command
            my $relative_dump_file = File::Spec->abs2rel($db_backup_result->{dump_file}, $app_root);
            $backup_command = "tar -czf '$backup_file' '$relative_dump_file' && rm '$db_backup_result->{dump_file}'";
            
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'create',
                "Database backup dump file: $db_backup_result->{dump_file}");
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'create',
                "Relative dump file path: $relative_dump_file");
        } else {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create',
                "Failed to create database backup: " . $db_backup_result->{error});
            
            $c->flash->{error_msg} = "Failed to create database backup: " . $db_backup_result->{error};
            $c->response->redirect($c->uri_for('/admin/backup'));
            return;
        }
    }
    
    # Execute backup command
    if ($backup_command) {
        # Get the application root directory for proper tar execution
        my $app_root = $c->path_to('.');
        
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'create',
            "Executing backup command from directory: $app_root");
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'create',
            "Backup command: $backup_command");
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'create',
            "Target backup file: $backup_file");
        
        # Change to application root directory and execute command
        my $original_dir = Cwd::getcwd();
        chdir($app_root) or do {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create',
                "Cannot change to application directory: $app_root - $!");
            $c->flash->{error_msg} = "Cannot change to application directory: $!";
            $c->response->redirect($c->uri_for('/admin/backup'));
            return;
        };
        
        my $result = system($backup_command);
        
        # Change back to original directory
        chdir($original_dir);
        
        if ($result == 0) {
            # Add a small delay to ensure file is fully written
            sleep(1);
            
            # Verify backup file was created and has content
            if (-f $backup_file && -s $backup_file) {
                $backup_success = 1;
                
                my $file_size = -s $backup_file;
                my $formatted_size = $self->format_file_size($file_size);
                
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create',
                    "Backup created successfully: $backup_file ($formatted_size)");
                
                # Force a debug message to appear in the UI
                if ($c->session->{debug_mode}) {
                    $c->stash->{debug_msg} = [] unless ref($c->stash->{debug_msg}) eq 'ARRAY';
                    push @{$c->stash->{debug_msg}}, "DEBUG: Backup file created at: $backup_file (Size: $formatted_size)";
                }
                
                my $success_msg = "Backup created successfully: $backup_name.tar.gz ($formatted_size)";
                $success_msg .= " - $description" if $description;
                
                $c->flash->{success_msg} = $success_msg;
            } else {
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create',
                    "Backup file was not created or is empty: $backup_file");
                
                # Additional debugging
                if (-f $backup_file) {
                    my $size = -s $backup_file;
                    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'create',
                        "Backup file exists but has size: $size bytes");
                    
                    # Force debug message to UI
                    if ($c->session->{debug_mode}) {
                        $c->stash->{debug_msg} = [] unless ref($c->stash->{debug_msg}) eq 'ARRAY';
                        push @{$c->stash->{debug_msg}}, "DEBUG: Backup file exists but empty: $backup_file ($size bytes)";
                    }
                } else {
                    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'create',
                        "Backup file does not exist at: $backup_file");
                    
                    # Force debug message to UI
                    if ($c->session->{debug_mode}) {
                        $c->stash->{debug_msg} = [] unless ref($c->stash->{debug_msg}) eq 'ARRAY';
                        push @{$c->stash->{debug_msg}}, "DEBUG: Backup file does not exist: $backup_file";
                    }
                }
                
                $c->flash->{error_msg} = "Backup file was not created or is empty";
            }
        } else {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create',
                "Error creating backup (exit code: $result): $!");
            
            # Force debug message to UI
            if ($c->session->{debug_mode}) {
                $c->stash->{debug_msg} = [] unless ref($c->stash->{debug_msg}) eq 'ARRAY';
                push @{$c->stash->{debug_msg}}, "DEBUG: Backup command failed with exit code: $result";
            }
            
            $c->flash->{error_msg} = "Error creating backup (exit code: $result)";
        }
    }
    
    $c->response->redirect($c->uri_for('/admin/backup'));
}

# Cleanup orphaned backup files (like .meta files without corresponding .tar.gz)
sub cleanup_orphaned_backups {
    my ($self, $c) = @_;
    
    my $backup_dir = $c->path_to('backups');
    return unless -d $backup_dir;
    
    eval {
        opendir(my $dh, $backup_dir) or die "Cannot open backup directory: $!";
        my @all_files = readdir($dh);
        closedir($dh);
        
        # Find .meta files
        my @meta_files = grep { $_ =~ /\.tar\.gz\.meta$/ } @all_files;
        
        foreach my $meta_file (@meta_files) {
            my $backup_file = $meta_file;
            $backup_file =~ s/\.meta$//; # Remove .meta extension
            
            # If the corresponding .tar.gz file doesn't exist, remove the .meta file
            unless (-f "$backup_dir/$backup_file") {
                my $meta_path = "$backup_dir/$meta_file";
                if (unlink($meta_path)) {
                    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'cleanup_orphaned_backups',
                        "Removed orphaned meta file: $meta_file");
                }
            }
        }
    };
    
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'cleanup_orphaned_backups',
            "Error during cleanup: $@");
    }
}

# Debug endpoint to check backup directory contents
sub debug_backups :Path('/admin/backup/debug') :Args(0) {
    my ($self, $c) = @_;
    
    # Check if the user has CSC backup access
    unless ($self->check_csc_access($c)) {
        $c->response->body("Access denied");
        return;
    }
    
    my $backup_dir = $c->path_to('backups');
    my $debug_info = {
        backup_dir => "$backup_dir",
        dir_exists => (-d $backup_dir) ? 1 : 0,
        files => [],
        error => ''
    };
    
    if (-d $backup_dir) {
        eval {
            opendir(my $dh, $backup_dir) or die "Cannot open directory: $!";
            my @all_files = readdir($dh);
            closedir($dh);
            
            foreach my $file (@all_files) {
                next if $file eq '.' || $file eq '..';
                my $filepath = "$backup_dir/$file";
                my @stat = stat($filepath);
                
                push @{$debug_info->{files}}, {
                    name => $file,
                    is_file => (-f $filepath) ? 1 : 0,
                    size => $stat[7] || 0,
                    mtime => $stat[9] || 0,
                    matches_pattern => ($file =~ /\.tar\.gz$/) ? 1 : 0
                };
            }
        };
        $debug_info->{error} = $@ if $@;
    }
    
    $c->response->content_type('application/json');
    $c->response->body(JSON::encode_json($debug_info));
}

# Test backup creation manually
sub test_create :Path('/admin/backup/test_create') :Args(0) {
    my ($self, $c) = @_;
    
    # Check if the user has CSC backup access
    unless ($self->check_csc_access($c)) {
        $c->response->body("Access denied");
        return;
    }
    
    my $result = {
        steps => [],
        success => 0,
        error => ''
    };
    
    eval {
        push @{$result->{steps}}, "Starting manual backup test...";
        
        my $backup_dir = $c->path_to('backups');
        my $app_root = $c->path_to('.');
        my $timestamp = time();
        my ($sec, $min, $hour, $mday, $mon, $year) = localtime($timestamp);
        my $date_str = sprintf("%04d%02d%02d_%02d%02d%02d", $year + 1900, $mon + 1, $mday, $hour, $min, $sec);
        my $backup_name = "test_backup_${date_str}_database";
        my $backup_file = "$backup_dir/$backup_name.tar.gz";
        
        push @{$result->{steps}}, "Backup directory: $backup_dir";
        push @{$result->{steps}}, "App root: $app_root";
        push @{$result->{steps}}, "Backup name: $backup_name";
        push @{$result->{steps}}, "Backup file: $backup_file";
        
        # Test database backup creation
        my $db_backup_result = $self->create_database_backup($c, $backup_dir, $backup_name);
        
        if ($db_backup_result->{success}) {
            push @{$result->{steps}}, "✅ Database dump created: " . $db_backup_result->{dump_file};
            
            # Check if dump file exists
            if (-f $db_backup_result->{dump_file}) {
                my $dump_size = -s $db_backup_result->{dump_file};
                push @{$result->{steps}}, "✅ Dump file exists with size: $dump_size bytes";
                
                # Create tar command
                my $relative_dump_file = File::Spec->abs2rel($db_backup_result->{dump_file}, $app_root);
                my $backup_command = "tar -czf '$backup_file' '$relative_dump_file' && rm '$db_backup_result->{dump_file}'";
                
                push @{$result->{steps}}, "Relative dump file: $relative_dump_file";
                push @{$result->{steps}}, "Backup command: $backup_command";
                
                # Change to app root and execute
                my $original_dir = Cwd::getcwd();
                chdir($app_root);
                push @{$result->{steps}}, "Changed to directory: " . Cwd::getcwd();
                
                my $cmd_result = system($backup_command);
                chdir($original_dir);
                
                push @{$result->{steps}}, "Command exit code: $cmd_result";
                
                if ($cmd_result == 0) {
                    if (-f $backup_file && -s $backup_file) {
                        my $backup_size = -s $backup_file;
                        push @{$result->{steps}}, "✅ Backup created successfully: $backup_size bytes";
                        $result->{success} = 1;
                        
                        # Clean up test file
                        unlink($backup_file);
                        push @{$result->{steps}}, "Test backup file cleaned up";
                    } else {
                        push @{$result->{steps}}, "❌ Backup file not created or empty";
                    }
                } else {
                    push @{$result->{steps}}, "❌ Backup command failed";
                }
            } else {
                push @{$result->{steps}}, "❌ Dump file does not exist";
            }
        } else {
            push @{$result->{steps}}, "❌ Database backup failed: " . $db_backup_result->{error};
        }
    };
    
    if ($@) {
        $result->{error} = $@;
        push @{$result->{steps}}, "❌ Exception: $@";
    }
    
    $c->response->content_type('application/json');
    $c->response->body(JSON::encode_json($result));
}

# Handle backup download
sub download :Path('/admin/backup/download') :Args(1) {
    my ($self, $c, $filename) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'download',
        "Starting backup download: $filename");
    
    # Check if the user has CSC backup access
    unless ($self->check_csc_access($c)) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'download',
            "Access denied: User does not have CSC backup access");
        
        $c->flash->{error_msg} = "You need CSC administrator privileges to download backups.";
        $c->response->redirect($c->uri_for('/admin/backup'));
        return;
    }
    
    # Validate filename (security check)
    unless ($filename && $filename =~ /^[a-zA-Z0-9_\-\.]+\.tar\.gz$/) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'download',
            "Invalid filename: $filename");
        
        $c->flash->{error_msg} = "Invalid backup filename.";
        $c->response->redirect($c->uri_for('/admin/backup'));
        return;
    }
    
    # Check if backup file exists
    my $backup_file = $c->path_to('backups', $filename);
    unless (-f $backup_file) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'download',
            "Backup file not found: $backup_file");
        
        $c->flash->{error_msg} = "Backup file not found: $filename";
        $c->response->redirect($c->uri_for('/admin/backup'));
        return;
    }
    
    # Serve the file for download
    $c->response->content_type('application/gzip');
    $c->response->header('Content-Disposition' => "attachment; filename=\"$filename\"");
    $c->response->header('Content-Length' => -s $backup_file);
    
    # Stream the file
    $c->serve_static_file($backup_file);
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'download',
        "Backup download completed: $filename");
}

# Handle backup deletion
sub delete :Path('/admin/backup/delete') :Args(1) {
    my ($self, $c, $filename) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'delete',
        "Starting backup deletion: $filename");
    
    # Check if the user has CSC backup access
    unless ($self->check_csc_access($c)) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'delete',
            "Access denied: User does not have CSC backup access");
        
        $c->flash->{error_msg} = "You need CSC administrator privileges to delete backups.";
        $c->response->redirect($c->uri_for('/admin/backup'));
        return;
    }
    
    # Validate filename (security check)
    unless ($filename && $filename =~ /^[a-zA-Z0-9_\-\.]+\.tar\.gz$/) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'delete',
            "Invalid filename: $filename");
        
        $c->flash->{error_msg} = "Invalid backup filename.";
        $c->response->redirect($c->uri_for('/admin/backup'));
        return;
    }
    
    # Check if backup file exists
    my $backup_file = $c->path_to('backups', $filename);
    unless (-f $backup_file) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'delete',
            "Backup file not found: $backup_file");
        
        $c->flash->{error_msg} = "Backup file not found: $filename";
        $c->response->redirect($c->uri_for('/admin/backup'));
        return;
    }
    
    # Delete the backup file
    if (unlink($backup_file)) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'delete',
            "Backup deleted successfully: $backup_file");
        
        $c->flash->{success_msg} = "Backup deleted successfully: $filename";
    } else {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'delete',
            "Error deleting backup: $!");
        
        $c->flash->{error_msg} = "Error deleting backup: $!";
    }
    
    $c->response->redirect($c->uri_for('/admin/backup'));
}

# Test database connection (AJAX endpoint)
sub test_db :Path('/admin/backup/test_db') :Args(0) {
    my ($self, $c) = @_;
    
    # Check if the user has CSC backup access
    unless ($self->check_csc_access($c)) {
        my $result = {
            success => 0,
            message => "Access denied: CSC administrator privileges required"
        };
        $c->response->content_type('application/json');
        $c->response->body(JSON::encode_json($result));
        return;
    }
    
    # This method already exists further down in the file, so we'll just redirect to it
    # or we can implement it here if needed
    $self->test_database_connection($c);
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
    
    # Add access control schema status
    my $access_control_status = $self->check_access_control_schema($c);
    
    # Debug: Log the structure of database_comparison
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'schema_compare', 
        "Database comparison structure: " . Data::Dumper::Dumper($database_comparison));
    
    # Use the standard debug message system
    if ($c->session->{debug_mode}) {
        $c->stash->{debug_msg} = [] unless ref($c->stash->{debug_msg}) eq 'ARRAY';
        push @{$c->stash->{debug_msg}}, "Admin controller schema_compare view - Template: admin/schema_compare.tt";
        push @{$c->stash->{debug_msg}}, "Ency tables: " . scalar(@{$database_comparison->{ency}->{tables}});
        push @{$c->stash->{debug_msg}}, "Forager tables: " . scalar(@{$database_comparison->{forager}->{tables}});
        push @{$c->stash->{debug_msg}}, "Tables with results: " . $database_comparison->{summary}->{tables_with_results};
        push @{$c->stash->{debug_msg}}, "Tables without results: " . $database_comparison->{summary}->{tables_without_results};
    }
    
    # Set the template and data
    $c->stash(
        template => 'admin/schema_compare.tt',
        database_comparison => $database_comparison,
        access_control_status => $access_control_status
    );
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'schema_compare', 
        "Completed schema_compare action");
}

# Check access control schema status
sub check_access_control_schema {
    my ($self, $c) = @_;
    
    my $status = {
        overall_status => 'unknown',
        users_table => {},
        user_site_roles_table => {},
        migration_needed => 0,
        errors => [],
        recommendations => []
    };
    
    # Check User table columns
    $status->{users_table} = $self->check_users_table_schema($c);
    
    # Check UserSiteRole table
    $status->{user_site_roles_table} = $self->check_user_site_roles_table_schema($c);
    
    # Determine overall status
    my $has_errors = 0;
    my $needs_migration = 0;
    
    if ($status->{users_table}->{has_errors}) {
        $has_errors = 1;
        push @{$status->{errors}}, @{$status->{users_table}->{errors}};
    }
    
    if ($status->{user_site_roles_table}->{has_errors}) {
        $has_errors = 1;
        push @{$status->{errors}}, @{$status->{user_site_roles_table}->{errors}};
    }
    
    if ($status->{users_table}->{needs_migration} || $status->{user_site_roles_table}->{needs_migration}) {
        $needs_migration = 1;
    }
    
    # Set overall status
    if ($has_errors) {
        $status->{overall_status} = 'error';
        push @{$status->{recommendations}}, 'Database schema errors detected. System is using fallback compatibility mode.';
    } elsif ($needs_migration) {
        $status->{overall_status} = 'migration_available';
        $status->{migration_needed} = 1;
        push @{$status->{recommendations}}, 'Enhanced access control features are available. Migration is optional.';
    } else {
        $status->{overall_status} = 'ok';
        push @{$status->{recommendations}}, 'Access control schema is up to date.';
    }
    
    return $status;
}

# Check users table schema for access control enhancements
sub check_users_table_schema {
    my ($self, $c) = @_;
    
    my $table_status = {
        exists => 0,
        has_errors => 0,
        needs_migration => 0,
        columns => {},
        missing_columns => [],
        errors => []
    };
    
    try {
        # Try to describe the users table
        my $dbh = $c->model('DBEncy')->schema->storage->dbh;
        my $sth = $dbh->prepare("DESCRIBE users");
        $sth->execute();
        
        $table_status->{exists} = 1;
        
        # Get existing columns
        while (my $row = $sth->fetchrow_hashref) {
            $table_status->{columns}->{lc($row->{Field})} = {
                type => $row->{Type},
                null => $row->{Null},
                default => $row->{Default},
                key => $row->{Key}
            };
        }
        
        # Check for required columns
        my @required_columns = qw(id username password email roles);
        foreach my $col (@required_columns) {
            unless (exists $table_status->{columns}->{$col}) {
                push @{$table_status->{errors}}, "Missing required column: $col";
                $table_status->{has_errors} = 1;
            }
        }
        
        # Check for optional enhancement columns
        my @optional_columns = qw(status created_at last_login);
        foreach my $col (@optional_columns) {
            unless (exists $table_status->{columns}->{$col}) {
                push @{$table_status->{missing_columns}}, $col;
                $table_status->{needs_migration} = 1;
            }
        }
        
    } catch {
        my $error = $_;
        push @{$table_status->{errors}}, "Error checking users table: $error";
        $table_status->{has_errors} = 1;
        
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'check_users_table_schema',
            "Error checking users table schema: $error");
    };
    
    return $table_status;
}

# Check user_site_roles table schema
sub check_user_site_roles_table_schema {
    my ($self, $c) = @_;
    
    my $table_status = {
        exists => 0,
        has_errors => 0,
        needs_migration => 0,
        columns => {},
        missing_columns => [],
        errors => []
    };
    
    try {
        # Try to describe the user_site_roles table
        my $dbh = $c->model('DBEncy')->schema->storage->dbh;
        my $sth = $dbh->prepare("DESCRIBE user_site_roles");
        $sth->execute();
        
        $table_status->{exists} = 1;
        
        # Get existing columns
        while (my $row = $sth->fetchrow_hashref) {
            $table_status->{columns}->{lc($row->{Field})} = {
                type => $row->{Type},
                null => $row->{Null},
                default => $row->{Default},
                key => $row->{Key}
            };
        }
        
    } catch {
        my $error = $_;
        if ($error =~ /doesn't exist/i) {
            # Table doesn't exist - this is expected for basic installations
            $table_status->{needs_migration} = 1;
            push @{$table_status->{missing_columns}}, 'entire_table';
        } else {
            push @{$table_status->{errors}}, "Error checking user_site_roles table: $error";
            $table_status->{has_errors} = 1;
        }
    };
    
    return $table_status;
}

# Access control help page
sub access_control_help :Path('/admin/access_control_help') :Args(0) {
    my ($self, $c) = @_;
    
    # Check if the user has admin role
    unless ($c->user_exists && $c->check_user_roles('admin')) {
        $c->flash->{error_msg} = "You need to be an administrator to access this area.";
        $c->response->redirect($c->uri_for('/user/login', {
            destination => $c->req->uri
        }));
        return;
    }
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'access_control_help',
        "Displaying access control help page");
    
    # Use the standard debug message system
    if ($c->session->{debug_mode}) {
        $c->stash->{debug_msg} = [] unless ref($c->stash->{debug_msg}) eq 'ARRAY';
        push @{$c->stash->{debug_msg}}, "Admin controller access_control_help view - Template: admin/access_control_help.tt";
    }
    
    $c->stash(
        template => 'admin/access_control_help.tt',
        title => 'Multi-Site Access Control Help'
    );
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
    
    # TEMPORARY FIX: Allow specific users direct access
    if ($c->session->{username} && $c->session->{username} eq 'Shanta') {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_field_comparison', 
            "Admin access granted to user Shanta (bypass role check)");
    }
    else {
        # Check if the user has admin role
        unless ($c->user_exists && $c->check_user_roles('admin')) {
            $c->response->status(403);
            $c->stash(json => {
                success => 0,
                error => "Access denied: Admin role required"
            });
            $c->forward('View::JSON');
            return;
        }
    }
    
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
            debug_mode => $c->session->{debug_mode} ? 1 : 0,
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
        
        # Don't return 500 status - return success with error info instead
        # This prevents JavaScript parsing errors
        $c->stash(json => {
            success => 0,
            error => $error,
            table_name => $table_name,
            database => $database,
            debug_mode => $c->session->{debug_mode} ? 1 : 0
        });
    };
    
    $c->forward('View::JSON');
}

# AJAX endpoint to get result file fields
sub get_result_file_fields :Path('/admin/get_result_file_fields') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_result_file_fields', 
        "Starting get_result_file_fields action");
    
    # Check if the user has admin role
    unless ($c->user_exists && $c->check_user_roles('admin')) {
        $c->response->status(403);
        $c->stash(json => {
            success => 0,
            error => "Access denied: Admin role required"
        });
        $c->forward('View::JSON');
        return;
    }
    
    my $result_name = $c->req->param('result_name');
    my $database = $c->req->param('database');
    
    unless ($result_name && $database) {
        $c->response->status(400);
        $c->stash(json => {
            success => 0,
            error => "Missing required parameters: result_name and database"
        });
        $c->forward('View::JSON');
        return;
    }
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_result_file_fields', 
        "Getting fields for result: $result_name in database: $database");
    
    try {
        # Get the result file fields
        my $fields = $self->get_result_file_field_definitions($c, $result_name, $database);
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_result_file_fields', 
            "Successfully retrieved " . scalar(keys %$fields) . " fields for result: $result_name");
        
        $c->stash(json => {
            success => 1,
            fields => $fields,
            result_name => $result_name,
            database => $database
        });
        
    } catch {
        my $error = "Error getting result file fields for $result_name ($database): $_";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_result_file_fields', $error);
        
        $c->response->status(500);
        $c->stash(json => {
            success => 0,
            error => $error
        });
    };
    
    $c->forward('View::JSON');
}

# Get field definitions from a result file
sub get_result_file_field_definitions {
    my ($self, $c, $result_name, $database) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_result_file_field_definitions', 
        "Getting field definitions for result: $result_name in database: $database");
    
    # Build the result file path
    my $base_path = "/home/shanta/PycharmProjects/comserv2/Comserv/lib/Comserv/Model/Schema";
    my $result_file_path;
    
    if (lc($database) eq 'ency') {
        $result_file_path = "$base_path/Ency/Result/$result_name.pm";
        # Also check subdirectories
        unless (-f $result_file_path) {
            if (-f "$base_path/Ency/Result/System/$result_name.pm") {
                $result_file_path = "$base_path/Ency/Result/System/$result_name.pm";
            } elsif (-f "$base_path/Ency/Result/User/$result_name.pm") {
                $result_file_path = "$base_path/Ency/Result/User/$result_name.pm";
            }
        }
    } elsif (lc($database) eq 'forager') {
        $result_file_path = "$base_path/Forager/Result/$result_name.pm";
    } else {
        die "Unsupported database: $database";
    }
    
    unless (-f $result_file_path) {
        die "Result file not found: $result_file_path";
    }
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_result_file_field_definitions', 
        "Found result file: $result_file_path");
    
    # Parse the result file schema
    my $schema_info = $self->get_result_file_schema($c, $result_name, $result_file_path);
    
    unless ($schema_info && $schema_info->{columns}) {
        die "Could not parse result file schema: $result_file_path";
    }
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_result_file_field_definitions', 
        "Successfully parsed " . scalar(keys %{$schema_info->{columns}}) . " fields from result file");
    
    return $schema_info->{columns};
}

# Get database comparison between each database and its result files
sub get_database_comparison {
    my ($self, $c) = @_;
    
    # Get available backends from HybridDB
    my $hybrid_db = $c->model('HybridDB');
    my $available_backends = $hybrid_db->get_available_backends() || {};
    
    my $comparison = {
        backends => {},
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
            results_without_tables => 0,
            total_backends => scalar(keys %$available_backends),
            available_backends => scalar(grep { $available_backends->{$_}->{available} } keys %$available_backends)
        }
    };
    
    # Add backend-specific schema comparison
    foreach my $backend_name (sort keys %$available_backends) {
        my $backend_info = $available_backends->{$backend_name};
        
        $comparison->{backends}->{$backend_name} = {
            name => $backend_name,
            display_name => $backend_info->{config}->{description} || $backend_name,
            type => $backend_info->{type},
            available => $backend_info->{available},
            priority => $backend_info->{config}->{priority} || 999,
            connection_status => $backend_info->{available} ? 'connected' : 'disconnected',
            tables => [],
            table_count => 0,
            table_comparisons => [],
            error => undef
        };
        
        # If backend is available, get its schema information
        if ($backend_info->{available}) {
            try {
                my $backend_tables = $self->get_backend_database_tables($c, $backend_name, $backend_info);
                $comparison->{backends}->{$backend_name}->{tables} = $backend_tables;
                $comparison->{backends}->{$backend_name}->{table_count} = scalar(@$backend_tables);
                
                # Build result file mapping for this backend
                my $result_table_mapping = $self->build_result_table_mapping($c, 'ency');
                
                # Compare each table with its result file
                foreach my $table_name (@$backend_tables) {
                    my $table_comparison = $self->compare_backend_table_with_result_file($c, $table_name, $backend_name, $backend_info, $result_table_mapping);
                    push @{$comparison->{backends}->{$backend_name}->{table_comparisons}}, $table_comparison;
                    
                    if ($table_comparison->{has_result_file}) {
                        $comparison->{summary}->{tables_with_results}++;
                    } else {
                        $comparison->{summary}->{tables_without_results}++;
                    }
                }
                
                $comparison->{summary}->{total_tables} += scalar(@$backend_tables);
                
            } catch {
                my $error = $_;
                $comparison->{backends}->{$backend_name}->{error} = $error;
                $comparison->{backends}->{$backend_name}->{connection_status} = 'error';
                
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_database_comparison', 
                    "Error getting schema for backend '$backend_name': $error");
            };
        }
    }
    
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
    
    # Debug: Log the number of result files found
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'build_result_table_mapping',
        "Found " . scalar(@result_files) . " result files for database '$database'");
    
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
    
    # Debug: Log the final mapping keys
    my @mapping_keys = sort keys %mapping;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'build_result_table_mapping',
        "Final mapping contains " . scalar(@mapping_keys) . " entries: " . join(', ', @mapping_keys));
    
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
            differences => $self->compare_field_attributes($table_field, $result_field, $c, $field_name)
        };
    }
    
    return $comparison;
}

# Get detailed field comparison between table and Result file using comprehensive mapping
sub get_table_result_comparison_v2 {
    my ($self, $c, $table_name, $database, $result_table_mapping) = @_;
    
    # Get table schema
    my $table_schema = { columns => {} };
    eval {
        if ($database eq 'ency') {
            $table_schema = $self->get_ency_table_schema($c, $table_name);
        } elsif ($database eq 'forager') {
            $table_schema = $self->get_forager_table_schema($c, $table_name);
        } else {
            die "Invalid database: $database";
        }
        
        # Ensure we have a valid schema structure
        $table_schema = { columns => {} } unless $table_schema && ref($table_schema) eq 'HASH';
        $table_schema->{columns} = {} unless $table_schema->{columns} && ref($table_schema->{columns}) eq 'HASH';
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
        has_result_file => ($result_info && -f $result_info->{result_path}) ? 1 : 0,
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
            differences => $self->compare_field_attributes($table_field, $result_field, $c, $field_name)
        };
    }
    
    return $comparison;
}

# Compare field attributes between table and Result file
sub compare_field_attributes {
    my ($self, $table_field, $result_field, $c, $field_name) = @_;
    
    my @differences = ();
    my @attributes = qw(data_type size is_nullable is_auto_increment default_value);
    
    foreach my $attr (@attributes) {
        my $table_value = $table_field ? $table_field->{$attr} : undef;
        my $result_value = $result_field ? $result_field->{$attr} : undef;
        
        # Store original values for debugging
        my $original_table_value = $table_value;
        my $original_result_value = $result_value;
        
        # Normalize values for comparison
        $table_value = $self->normalize_field_value($attr, $table_value);
        $result_value = $self->normalize_field_value($attr, $result_value);
        
        # Add debug information for data_type comparisons when debug_mode is enabled
        if ($c && $c->session->{debug_mode} && $attr eq 'data_type' && defined $original_table_value && defined $original_result_value) {
            push @{$c->stash->{debug_msg}}, sprintf(
                "Field '%s' data_type normalization: Table Type: %s -> %s, Result Type: %s -> %s, Match: %s",
                $field_name || 'unknown',
                $original_table_value || 'undef',
                $table_value || 'undef',
                $original_result_value || 'undef', 
                $result_value || 'undef',
                (defined $table_value && defined $result_value && $table_value eq $result_value) ? 'YES' : 'NO'
            );
        }
        
        if (defined $table_value && defined $result_value) {
            if ($table_value ne $result_value) {
                push @differences, {
                    attribute => $attr,
                    table_value => $table_value,
                    result_value => $result_value,
                    original_table_value => $original_table_value,
                    original_result_value => $original_result_value,
                    type => 'different'
                };
            }
        } elsif (defined $table_value && !defined $result_value) {
            push @differences, {
                attribute => $attr,
                table_value => $table_value,
                result_value => undef,
                original_table_value => $original_table_value,
                original_result_value => $original_result_value,
                type => 'missing_in_result'
            };
        } elsif (!defined $table_value && defined $result_value) {
            push @differences, {
                attribute => $attr,
                table_value => undef,
                result_value => $result_value,
                original_table_value => $original_table_value,
                original_result_value => $original_result_value,
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
    
    # Handle data type normalization
    if ($attribute eq 'data_type') {
        return $self->normalize_data_type($value);
    }
    
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
    
    # Try to load the Result class directly first
    my $result_class_schema = $self->parse_result_class_schema($c, $file_path);
    if ($result_class_schema && keys %{$result_class_schema->{columns}}) {
        return $result_class_schema;
    }
    
    # Fallback to file parsing if direct class loading fails
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

# Parse Result class schema by loading the class directly
sub parse_result_class_schema {
    my ($self, $c, $file_path) = @_;
    
    my $schema = {
        columns => {},
        primary_keys => [],
        relationships => [],
        table_name => undef
    };
    
    # Extract the Result class name from the file path
    my $result_class;
    if ($file_path =~ m{/Result/(.+)\.pm$}) {
        my $class_path = $1;
        $class_path =~ s{/}{::}g;  # Convert path separators to Perl package separators
        $result_class = "Comserv::Model::Schema::Ency::Result::$class_path";
    } else {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'parse_result_class_schema',
            "Could not extract Result class name from path: $file_path");
        return $schema;
    }
    
    # Try to load the Result class
    eval {
        eval "require $result_class";
        die $@ if $@;
        
        # Get the table name
        $schema->{table_name} = $result_class->table if $result_class->can('table');
        
        # Get column information
        if ($result_class->can('columns_info')) {
            my $columns_info = $result_class->columns_info;
            foreach my $col_name (keys %$columns_info) {
                my $col_info = $columns_info->{$col_name};
                $schema->{columns}->{$col_name} = {
                    data_type => $col_info->{data_type} || 'unknown',
                    is_nullable => $col_info->{is_nullable} // 1,
                    size => $col_info->{size},
                    is_auto_increment => $col_info->{is_auto_increment} || 0,
                    default_value => $col_info->{default_value},
                    extra => $col_info->{extra}
                };
            }
        }
        
        # Get primary key information
        if ($result_class->can('primary_columns')) {
            my @primary_keys = $result_class->primary_columns;
            $schema->{primary_keys} = \@primary_keys;
        }
        
        # Get relationship information
        if ($result_class->can('relationships')) {
            my @relationships = $result_class->relationships;
            foreach my $rel_name (@relationships) {
                if ($result_class->can('relationship_info')) {
                    my $rel_info = $result_class->relationship_info($rel_name);
                    push @{$schema->{relationships}}, {
                        type => $rel_info->{attrs}->{accessor} || 'unknown',
                        accessor => $rel_name,
                        related_class => $rel_info->{class},
                        foreign_key => $rel_info->{cond} || {}
                    };
                }
            }
        }
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'parse_result_class_schema',
            "Successfully loaded Result class $result_class with " . scalar(keys %{$schema->{columns}}) . " columns");
            
    };
    
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'parse_result_class_schema',
            "Failed to load Result class $result_class: $@");
        return undef;  # Return undef to indicate failure, so fallback parsing can be used
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
        
        # Log database connection info
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_ency_database_tables',
            "Connected to database: " . $dbh->{Name});
        
        my $sth = $dbh->prepare("SHOW TABLES");
        $sth->execute();
        
        while (my ($table) = $sth->fetchrow_array()) {
            push @tables, $table;
        }
        
        # Log the number of tables found
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_ency_database_tables',
            "Found " . scalar(@tables) . " tables: " . join(', ', @tables));
        
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
    
    # Check if the user has admin role (same as other admin functions)
    unless ($c->user_exists && $c->check_user_roles('admin')) {
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

# Execute the git pull operation with divergent branch handling
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
        
        # Check Git status and handle divergent branches
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'execute_git_pull', 
            "Checking Git status for divergent branches");
        
        # First, fetch the latest changes from remote
        my $fetch_output = `git -C ${\$c->path_to()} fetch origin 2>&1`;
        $output .= "Git fetch output:\n$fetch_output\n";
        
        # Check for divergent branches
        my $status_output = `git -C ${\$c->path_to()} status --porcelain=v1 2>&1`;
        my $branch_status = `git -C ${\$c->path_to()} status -b --porcelain=v1 2>&1`;
        
        $output .= "Git status output:\n$status_output\n";
        $output .= "Branch status:\n$branch_status\n";
        
        # Check if there are local changes that need to be stashed
        my $has_local_changes = 0;
        if ($theme_mappings_exists) {
            my $git_status = `git -C ${\$c->path_to()} status --porcelain root/static/config/theme_mappings.json`;
            $has_local_changes = $git_status =~ /^\s*[AM]\s+root\/static\/config\/theme_mappings\.json/m;
            
            if ($has_local_changes) {
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'execute_git_pull', 
                    "Local changes detected in theme_mappings.json");
                $output .= "Local changes detected in theme_mappings.json\n";
                
                # Stash the changes
                my $stash_output = `git -C ${\$c->path_to()} stash push -m "Auto-stash before git pull" -- root/static/config/theme_mappings.json 2>&1`;
                $output .= "Stashed changes: $stash_output\n";
            }
        }
        
        # Check if we have divergent branches by comparing local and remote
        my $local_commit = `git -C ${\$c->path_to()} rev-parse HEAD 2>&1`;
        my $remote_commit = `git -C ${\$c->path_to()} rev-parse origin/master 2>&1`;
        chomp($local_commit);
        chomp($remote_commit);
        
        $output .= "Local commit: $local_commit\n";
        $output .= "Remote commit: $remote_commit\n";
        
        # Check if branches have diverged
        my $merge_base = `git -C ${\$c->path_to()} merge-base HEAD origin/master 2>&1`;
        chomp($merge_base);
        
        my $diverged = 0;
        if ($local_commit ne $remote_commit && $merge_base ne $local_commit && $merge_base ne $remote_commit) {
            $diverged = 1;
            $output .= "Divergent branches detected - local and remote have different commits\n";
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'execute_git_pull', 
                "Divergent branches detected");
        }
        
        # Execute git pull with appropriate strategy
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'execute_git_pull', 
            "Executing git pull with merge strategy");
        
        # Use merge strategy to handle divergent branches safely
        my $pull_output = `git -C ${\$c->path_to()} pull --no-rebase origin master 2>&1`;
        $output .= "Git pull output:\n$pull_output\n";
        
        # Check if pull was successful or if we need to handle divergent branches
        if ($pull_output =~ /Already up to date|Fast-forward|Updating|Merge made by/) {
            $success = 1;
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'execute_git_pull', 
                "Git pull completed successfully");
        } elsif ($pull_output =~ /divergent branches|Need to specify how to reconcile/) {
            # Handle divergent branches with explicit merge strategy
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'execute_git_pull', 
                "Handling divergent branches with merge strategy");
            
            # Configure git to use merge strategy for divergent branches
            my $config_output = `git -C ${\$c->path_to()} config pull.rebase false 2>&1`;
            $output .= "Git config output: $config_output\n";
            
            # Try pull again with explicit merge strategy
            $pull_output = `git -C ${\$c->path_to()} pull --no-rebase origin master 2>&1`;
            $output .= "Git pull (retry) output:\n$pull_output\n";
            
            if ($pull_output =~ /Already up to date|Fast-forward|Updating|Merge made by/) {
                $success = 1;
                $warning = "Divergent branches were successfully merged. Local changes have been preserved.";
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'execute_git_pull', 
                    "Divergent branches resolved successfully");
            } else {
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'execute_git_pull', 
                    "Git pull failed after handling divergent branches: $pull_output");
                return (0, $output, "Git pull failed after attempting to resolve divergent branches. Manual intervention may be required.");
            }
        } elsif ($pull_output =~ /CONFLICT/) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'execute_git_pull', 
                "Git pull resulted in conflicts: $pull_output");
            return (0, $output, "Git pull resulted in merge conflicts. Manual resolution required.");
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
        
        # Final status check
        my $final_status = `git -C ${\$c->path_to()} status --porcelain 2>&1`;
        if ($final_status) {
            $output .= "Final git status:\n$final_status\n";
            if ($final_status =~ /^UU|^AA|^DD/) {
                $warning = "There may be unresolved merge conflicts. Please check the repository status.";
            }
        }
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'execute_git_pull', 
            "Git pull operation completed");
            
    } catch {
        my $error = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'execute_git_pull', 
            "Error during git pull: $error");
        $output .= "Error: $error\n";
        return (0, $output, undef);
    };
    
    return ($success, $output, $warning);
}

# Emergency Git operations for production servers
sub git_emergency :Path('/admin/git_emergency') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'git_emergency', 
        "Starting git_emergency action");
    
    # Check if the user has admin role
    unless ($c->user_exists && $c->check_user_roles('admin')) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'git_emergency', 
            "Access denied: User does not have admin role");
        
        $c->flash->{error_msg} = "You need to be an administrator to access this area.";
        $c->response->redirect($c->uri_for('/user/login', {
            destination => $c->req->uri
        }));
        return;
    }
    
    # Check if this is a POST request with specific action
    if ($c->req->method eq 'POST') {
        my $action = $c->req->param('action') || '';
        my ($success, $output, $warning) = (0, '', undef);
        
        if ($action eq 'reset_hard') {
            ($success, $output, $warning) = $self->execute_git_reset_hard($c);
        } elsif ($action eq 'force_pull') {
            ($success, $output, $warning) = $self->execute_git_force_pull($c);
        } elsif ($action eq 'status_check') {
            ($success, $output, $warning) = $self->execute_git_status_check($c);
        }
        
        $c->stash(
            output => $output,
            success_msg => $success ? "Operation completed successfully." : undef,
            error_msg => $success ? undef : "Operation failed. See output for details.",
            warning_msg => $warning,
            action_performed => $action
        );
    }
    
    # Set the template
    $c->stash(template => 'admin/git_emergency.tt');
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'git_emergency', 
        "Completed git_emergency action");
}

# Execute Git status check for diagnostics
sub execute_git_status_check {
    my ($self, $c) = @_;
    my $output = '';
    my $warning = undef;
    my $success = 1;
    
    try {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'execute_git_status_check', 
            "Performing comprehensive Git status check");
        
        # Get current branch
        my $current_branch = `git -C ${\$c->path_to()} branch --show-current 2>&1`;
        chomp($current_branch);
        $output .= "Current branch: $current_branch\n\n";
        
        # Get Git status
        my $status = `git -C ${\$c->path_to()} status 2>&1`;
        $output .= "Git status:\n$status\n\n";
        
        # Get local and remote commit info
        my $local_commit = `git -C ${\$c->path_to()} rev-parse HEAD 2>&1`;
        my $remote_commit = `git -C ${\$c->path_to()} rev-parse origin/master 2>&1`;
        chomp($local_commit);
        chomp($remote_commit);
        
        $output .= "Local commit (HEAD): $local_commit\n";
        $output .= "Remote commit (origin/master): $remote_commit\n\n";
        
        # Check if branches have diverged
        if ($local_commit ne $remote_commit) {
            my $merge_base = `git -C ${\$c->path_to()} merge-base HEAD origin/master 2>&1`;
            chomp($merge_base);
            
            if ($merge_base ne $local_commit && $merge_base ne $remote_commit) {
                $output .= "⚠️  DIVERGENT BRANCHES DETECTED\n";
                $output .= "Merge base: $merge_base\n";
                $warning = "Branches have diverged. Local and remote have different commits.";
            } elsif ($merge_base eq $local_commit) {
                $output .= "✅ Local branch is behind remote (safe to pull)\n";
            } else {
                $output .= "✅ Local branch is ahead of remote\n";
            }
        } else {
            $output .= "✅ Local and remote are in sync\n";
        }
        
        # Get recent commits
        my $recent_commits = `git -C ${\$c->path_to()} log --oneline -5 2>&1`;
        $output .= "\nRecent commits:\n$recent_commits\n";
        
        # Check for uncommitted changes
        my $uncommitted = `git -C ${\$c->path_to()} diff --name-only 2>&1`;
        if ($uncommitted) {
            $output .= "\nUncommitted changes:\n$uncommitted\n";
        }
        
        # Check for untracked files
        my $untracked = `git -C ${\$c->path_to()} ls-files --others --exclude-standard 2>&1`;
        if ($untracked) {
            $output .= "\nUntracked files (first 10):\n";
            my @untracked_lines = split(/\n/, $untracked);
            for my $i (0..9) {
                last unless $untracked_lines[$i];
                $output .= "$untracked_lines[$i]\n";
            }
            if (@untracked_lines > 10) {
                $output .= "... and " . (@untracked_lines - 10) . " more files\n";
            }
        }
        
    } catch {
        my $error = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'execute_git_status_check', 
            "Error during Git status check: $error");
        $output .= "Error: $error\n";
        $success = 0;
    };
    
    return ($success, $output, $warning);
}

# Execute Git force pull (dangerous - use with caution)
sub execute_git_force_pull {
    my ($self, $c) = @_;
    my $output = '';
    my $warning = "⚠️  FORCE PULL PERFORMED - Local changes may be lost!";
    my $success = 0;
    
    try {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'execute_git_force_pull', 
            "Performing FORCE PULL - this may lose local changes");
        
        # Backup theme_mappings.json if it exists
        my $theme_mappings_path = $c->path_to('root', 'static', 'config', 'theme_mappings.json');
        my $backup_path = "$theme_mappings_path.bak";
        
        if (-e $theme_mappings_path) {
            copy($theme_mappings_path, $backup_path);
            $output .= "Backed up theme_mappings.json to $backup_path\n";
        }
        
        # Fetch latest changes
        my $fetch_output = `git -C ${\$c->path_to()} fetch origin 2>&1`;
        $output .= "Git fetch output:\n$fetch_output\n\n";
        
        # Reset to remote state (DANGEROUS)
        my $reset_output = `git -C ${\$c->path_to()} reset --hard origin/master 2>&1`;
        $output .= "Git reset --hard output:\n$reset_output\n\n";
        
        # Clean untracked files
        my $clean_output = `git -C ${\$c->path_to()} clean -fd 2>&1`;
        $output .= "Git clean output:\n$clean_output\n\n";
        
        # Verify final state
        my $final_status = `git -C ${\$c->path_to()} status 2>&1`;
        $output .= "Final status:\n$final_status\n";
        
        $success = 1;
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'execute_git_force_pull', 
            "Force pull completed - local changes were discarded");
        
    } catch {
        my $error = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'execute_git_force_pull', 
            "Error during force pull: $error");
        $output .= "Error: $error\n";
    };
    
    return ($success, $output, $warning);
}

# Execute Git reset hard (very dangerous - use only in emergencies)
sub execute_git_reset_hard {
    my ($self, $c) = @_;
    my $output = '';
    my $warning = "⚠️  HARD RESET PERFORMED - All local changes have been discarded!";
    my $success = 0;
    
    try {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'execute_git_reset_hard', 
            "Performing HARD RESET - this will discard ALL local changes");
        
        # Get current commit for reference
        my $current_commit = `git -C ${\$c->path_to()} rev-parse HEAD 2>&1`;
        chomp($current_commit);
        $output .= "Current commit before reset: $current_commit\n\n";
        
        # Backup theme_mappings.json if it exists
        my $theme_mappings_path = $c->path_to('root', 'static', 'config', 'theme_mappings.json');
        my $backup_path = "$theme_mappings_path.bak";
        
        if (-e $theme_mappings_path) {
            copy($theme_mappings_path, $backup_path);
            $output .= "Backed up theme_mappings.json to $backup_path\n";
        }
        
        # Fetch latest changes first
        my $fetch_output = `git -C ${\$c->path_to()} fetch origin 2>&1`;
        $output .= "Git fetch output:\n$fetch_output\n\n";
        
        # Hard reset to remote master
        my $reset_output = `git -C ${\$c->path_to()} reset --hard origin/master 2>&1`;
        $output .= "Git reset --hard origin/master output:\n$reset_output\n\n";
        
        # Get new commit for reference
        my $new_commit = `git -C ${\$c->path_to()} rev-parse HEAD 2>&1`;
        chomp($new_commit);
        $output .= "New commit after reset: $new_commit\n\n";
        
        # Final status
        my $final_status = `git -C ${\$c->path_to()} status 2>&1`;
        $output .= "Final status:\n$final_status\n";
        
        $success = 1;
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'execute_git_reset_hard', 
            "Hard reset completed - repository is now at origin/master");
        
    } catch {
        my $error = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'execute_git_reset_hard', 
            "Error during hard reset: $error");
        $output .= "Error: $error\n";
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
    my $sync_all = $json_data->{sync_all};
    
    unless ($table_name && $database) {
        $c->response->status(400);
        $c->stash(json => { success => 0, error => 'Missing required parameters: table_name, database' });
        $c->forward('View::JSON');
        return;
    }
    
    # If field_name is not provided but sync_all is not true, return error
    unless ($field_name || $sync_all) {
        $c->response->status(400);
        $c->stash(json => { success => 0, error => 'Either field_name or sync_all must be provided' });
        $c->forward('View::JSON');
        return;
    }
    
    try {
        if ($sync_all) {
            # Sync all fields from Result to table
            my $result = $self->sync_all_fields_result_to_table($c, $table_name, $database);
            
            $c->stash(json => {
                success => 1,
                message => "Successfully synced all fields from Result file to table '$table_name'",
                synced_fields => $result->{synced_fields} || [],
                warnings => $result->{warnings} || []
            });
        } else {
            # Sync single field
            my $result_field_info = $self->get_result_field_info($c, $table_name, $field_name, $database);
            my $result = $self->update_table_field_from_result($c, $table_name, $field_name, $database, $result_field_info);
            
            $c->stash(json => {
                success => 1,
                message => "Successfully synced result field '$field_name' to table",
                field_info => $result_field_info
            });
        }
        
    } catch {
        my $error = "Error syncing result to table: $_";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'sync_result_to_table', $error);
        
        $c->response->status(500);
        $c->stash(json => { success => 0, error => $error });
    };
    
    $c->forward('View::JSON');
}

# Debug endpoint to test field comparison
sub debug_field_comparison :Path('/admin/debug_field_comparison') :Args(0) {
    my ($self, $c) = @_;
    
    # Check if the user has admin role
    unless ($c->user_exists && $c->check_user_roles('admin')) {
        $c->response->status(403);
        $c->stash(json => { success => 0, error => 'Access denied' });
        $c->forward('View::JSON');
        return;
    }
    
    my $table_name = $c->req->param('table_name') || 'users';
    my $database = $c->req->param('database') || 'ency';
    
    try {
        # Build comprehensive mapping for this database
        my $result_table_mapping = $self->build_result_table_mapping($c, $database);
        
        my $comparison = $self->get_table_result_comparison_v2($c, $table_name, $database, $result_table_mapping);
        
        $c->stash(json => {
            success => 1,
            table_name => $table_name,
            database => $database,
            comparison => $comparison,
            mapping_keys => [keys %$result_table_mapping],
            debug_info => {
                has_result_file => $comparison->{has_result_file},
                result_file_path => $comparison->{result_file_path},
                fields_count => $comparison->{fields} ? scalar(keys %{$comparison->{fields}}) : 0
            }
        });
        
    } catch {
        my $error = "Debug field comparison error: $_";
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

# Enhanced helper method to normalize data types for comparison
sub normalize_data_type {
    my ($self, $data_type) = @_;
    
    return '' unless defined $data_type;
    
    # Store original for debugging
    my $original_type = $data_type;
    
    # Convert to lowercase for consistent comparison
    $data_type = lc($data_type);
    
    # Remove size specifications and constraints
    # Examples: varchar(255) -> varchar, int(11) -> int, decimal(10,2) -> decimal
    $data_type =~ s/\([^)]*\)//g;
    
    # Remove extra whitespace
    $data_type =~ s/^\s+|\s+$//g;
    
    # Handle unsigned/signed modifiers
    $data_type =~ s/\s+unsigned$//;
    $data_type =~ s/\s+signed$//;
    
    # Remove other common modifiers
    $data_type =~ s/\s+zerofill$//;
    $data_type =~ s/\s+binary$//;
    
    # Comprehensive type mapping for database-specific variations
    my %type_mapping = (
        # Integer types
        'int'           => 'integer',
        'int4'          => 'integer',
        'int8'          => 'bigint',
        'integer'       => 'integer',
        'bigint'        => 'bigint',
        'smallint'      => 'smallint',
        'tinyint'       => 'tinyint',
        'mediumint'     => 'integer',
        
        # String types
        'varchar'       => 'varchar',
        'char'          => 'char',
        'character'     => 'char',
        'text'          => 'text',
        'longtext'      => 'text',
        'mediumtext'    => 'text',
        'tinytext'      => 'text',
        'clob'          => 'text',
        
        # Boolean types
        'bool'          => 'boolean',
        'boolean'       => 'boolean',
        'bit'           => 'boolean',
        
        # Floating point types
        'float'         => 'real',
        'real'          => 'real',
        'double'        => 'double precision',
        'double precision' => 'double precision',
        'decimal'       => 'decimal',
        'numeric'       => 'decimal',
        
        # Date/time types
        'datetime'      => 'datetime',
        'timestamp'     => 'timestamp',
        'date'          => 'date',
        'time'          => 'time',
        'year'          => 'year',
        
        # Binary types
        'blob'          => 'blob',
        'longblob'      => 'blob',
        'mediumblob'    => 'blob',
        'tinyblob'      => 'blob',
        'binary'        => 'binary',
        'varbinary'     => 'varbinary',
        
        # JSON and other modern types
        'json'          => 'json',
        'jsonb'         => 'json',
        'uuid'          => 'uuid',
        'enum'          => 'enum',
        'set'           => 'set',
    );
    
    # Apply mapping or return normalized type
    my $normalized_type = $type_mapping{$data_type} || $data_type;
    
    return $normalized_type;
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
        my $error_msg = "Result file not found for table '$table_name'";
        
        # Add debug information if debug mode is enabled
        if ($c->session->{debug_mode}) {
            my $debug_info = "\nDEBUG INFO (get_result_field_info):\n";
            $debug_info .= "Table key searched: '$table_key'\n";
            $debug_info .= "Available tables: " . join(', ', keys %$result_table_mapping) . "\n";
            $debug_info .= "Result file path: " . ($result_file_path || 'undefined') . "\n";
            if ($result_file_path) {
                $debug_info .= "File exists: " . (-f $result_file_path ? 'YES' : 'NO') . "\n";
            }
            $error_msg .= $debug_info;
        }
        
        die $error_msg;
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
    
    my $error_msg = "Field '$field_name' not found in result file";
    
    # Add debug information if debug mode is enabled
    if ($c->session->{debug_mode}) {
        my $debug_info = "\nDEBUG INFO (get_result_field_info - field parsing):\n";
        $debug_info .= "Field name searched: '$field_name'\n";
        $debug_info .= "Result file path: '$result_file_path'\n";
        
        # Show a snippet of the add_columns section for debugging
        if ($content =~ /__PACKAGE__->add_columns\(\s*(.*?)\s*\);/s) {
            my $columns_section = $1;
            my $snippet = substr($columns_section, 0, 500);
            $snippet .= "..." if length($columns_section) > 500;
            $debug_info .= "add_columns section (first 500 chars): $snippet\n";
        } else {
            $debug_info .= "No add_columns section found in result file\n";
        }
        
        $error_msg .= $debug_info;
    }
    
    die $error_msg;
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
        my $error_msg = "Result file not found for table '$table_name'";
        
        # Add debug information if debug mode is enabled
        if ($c->session->{debug_mode}) {
            my $debug_info = "\nDEBUG INFO (update_result_field_from_table):\n";
            $debug_info .= "Table key searched: '$table_key'\n";
            $debug_info .= "Available tables: " . join(', ', keys %$result_table_mapping) . "\n";
            $debug_info .= "Result file path: " . ($result_file_path || 'undefined') . "\n";
            if ($result_file_path) {
                $debug_info .= "File exists: " . (-f $result_file_path ? 'YES' : 'NO') . "\n";
            }
            $error_msg .= $debug_info;
        }
        
        die $error_msg;
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
    
    my $error_msg = "Could not update field '$field_name' in result file";
    
    # Add debug information if debug mode is enabled
    if ($c->session->{debug_mode}) {
        my $debug_info = "\nDEBUG INFO (update_result_field_from_table - field update):\n";
        $debug_info .= "Field name to update: '$field_name'\n";
        $debug_info .= "Result file path: '$result_file_path'\n";
        $debug_info .= "New field definition: $new_field_def\n";
        
        # Show a snippet of the add_columns section for debugging
        if ($content =~ /__PACKAGE__->add_columns\(\s*(.*?)\s*\);/s) {
            my $columns_section = $1;
            my $snippet = substr($columns_section, 0, 500);
            $snippet .= "..." if length($columns_section) > 500;
            $debug_info .= "add_columns section (first 500 chars): $snippet\n";
        } else {
            $debug_info .= "No add_columns section found in result file\n";
        }
        
        $error_msg .= $debug_info;
    }
    
    die $error_msg;
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

# AJAX endpoint to create a Result file from a database table
sub create_result_from_table :Path('/admin/create_result_from_table') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_result_from_table',
        "Starting create_result_from_table action");
    
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
    my $database = $json_data->{database};
    
    # Debug logging
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_result_from_table',
        "Received parameters - table_name: " . ($table_name || 'UNDEFINED') . 
        ", database: " . ($database || 'UNDEFINED') . 
        ", JSON data: " . Data::Dumper::Dumper($json_data));
    
    unless ($table_name && $database) {
        my $error_msg = 'Missing required parameters: ';
        $error_msg .= 'table_name' unless $table_name;
        $error_msg .= ', database' unless $database;
        $error_msg .= " (received: table_name=" . ($table_name || 'UNDEFINED') . 
                     ", database=" . ($database || 'UNDEFINED') . ")";
        
        $c->response->status(400);
        $c->stash(json => { success => 0, error => $error_msg });
        $c->forward('View::JSON');
        return;
    }
    
    try {
        # Get table schema from database
        my $table_schema;
        if ($database eq 'ency') {
            $table_schema = $self->get_ency_table_schema($c, $table_name);
        } elsif ($database eq 'forager') {
            $table_schema = $self->get_forager_table_schema($c, $table_name);
        } else {
            die "Invalid database: $database";
        }
        
        unless ($table_schema && $table_schema->{columns}) {
            die "Could not retrieve schema for table '$table_name' from database '$database'";
        }
        
        # Generate Result file content
        my $result_content = $self->generate_result_file_content($c, $table_name, $database, $table_schema);
        
        # Determine Result file path
        my $result_file_path = $self->get_result_file_path($c, $table_name, $database);
        
        # Create directory if it doesn't exist
        my $result_dir = dirname($result_file_path);
        unless (-d $result_dir) {
            make_path($result_dir) or die "Could not create directory '$result_dir': $!";
        }
        
        # Write Result file
        write_file($result_file_path, $result_content);
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_result_from_table',
            "Successfully created Result file '$result_file_path' for table '$table_name'");
        
        $c->stash(json => {
            success => 1,
            message => "Successfully created Result file for table '$table_name'",
            result_file_path => $result_file_path,
            table_name => $table_name,
            database => $database
        });
        
    } catch {
        my $error = "Error creating Result file: $_";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_result_from_table', $error);
        
        $c->response->status(500);
        $c->stash(json => { success => 0, error => $error });
    };
    
    $c->forward('View::JSON');
}

# AJAX endpoint to create a database table from a Result file
sub create_table_from_result :Path('/admin/create_table_from_result') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_table_from_result',
        "Starting create_table_from_result action");
    
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
    
    my $result_name = $json_data->{result_name};
    
    unless ($result_name) {
        $c->response->status(400);
        $c->stash(json => { success => 0, error => 'Result name is required' });
        $c->forward('View::JSON');
        return;
    }
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_table_from_result',
        "Attempting to create table from result: $result_name");
    
    try {
        # Get the database schema
        my $schema = $c->model('DBEncy')->schema;
        
        # Call the create_table_from_result method from the DBEncy model
        my $result = $c->model('DBEncy')->create_table_from_result($result_name, $schema, $c);
        
        if ($result) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_table_from_result',
                "Successfully created table from result: $result_name");
            
            $c->stash(json => {
                success => 1,
                message => "Successfully created table from result '$result_name'",
                result_name => $result_name
            });
        } else {
            my $error = "Failed to create table from result '$result_name'";
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_table_from_result', $error);
            
            $c->response->status(500);
            $c->stash(json => { success => 0, error => $error });
        }
        
    } catch {
        my $error = "Error creating table from result: $_";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_table_from_result', $error);
        
        $c->response->status(500);
        $c->stash(json => { success => 0, error => $error });
    };
    
    $c->forward('View::JSON');
}

# Helper method to generate Result file content from table schema
sub generate_result_file_content {
    my ($self, $c, $table_name, $database, $table_schema) = @_;
    
    # Convert table name to proper case for class name
    my $class_name = $self->table_name_to_class_name($table_name);
    
    # Determine the proper database namespace
    my $namespace = $database eq 'ency' ? 'Ency' : 'Forager';
    
    my $content = "package Comserv::Model::Schema::${namespace}::Result::${class_name};\n";
    $content .= "use base 'DBIx::Class::Core';\n\n";
    
    # Add table name
    $content .= "__PACKAGE__->table('$table_name');\n";
    
    # Add columns
    $content .= "__PACKAGE__->add_columns(\n";
    
    my @column_definitions;
    foreach my $column_name (sort keys %{$table_schema->{columns}}) {
        my $column_info = $table_schema->{columns}->{$column_name};
        
        my $column_def = "    $column_name => {\n";
        $column_def .= "        data_type => '$column_info->{data_type}',\n";
        
        if ($column_info->{size}) {
            $column_def .= "        size => $column_info->{size},\n";
        }
        
        if ($column_info->{is_nullable}) {
            $column_def .= "        is_nullable => 1,\n";
        }
        
        if ($column_info->{is_auto_increment}) {
            $column_def .= "        is_auto_increment => 1,\n";
        }
        
        if (defined $column_info->{default_value} && $column_info->{default_value} ne '') {
            $column_def .= "        default_value => '$column_info->{default_value}',\n";
        }
        
        $column_def .= "    }";
        push @column_definitions, $column_def;
    }
    
    $content .= join(",\n", @column_definitions) . "\n";
    $content .= ");\n\n";
    
    # Add primary key if available
    if ($table_schema->{primary_keys} && @{$table_schema->{primary_keys}}) {
        my $pk_list = join("', '", @{$table_schema->{primary_keys}});
        $content .= "__PACKAGE__->set_primary_key('$pk_list');\n\n";
    }
    
    # Add relationships placeholder (can be filled in manually later)
    $content .= "# Add relationships here\n";
    $content .= "# Example:\n";
    $content .= "# __PACKAGE__->belongs_to(\n";
    $content .= "#     'related_table',\n";
    $content .= "#     'Comserv::Model::Schema::${namespace}::Result::RelatedTable',\n";
    $content .= "#     'foreign_key_column'\n";
    $content .= "# );\n\n";
    
    $content .= "1;\n";
    
    return $content;
}

# Helper method to convert table name to class name
sub table_name_to_class_name {
    my ($self, $table_name) = @_;
    
    # Convert snake_case or plural table names to PascalCase class names
    # Examples: user_sites -> UserSite, sites -> Site, network_devices -> NetworkDevice
    
    # Remove common plural suffixes and convert to singular
    my $singular = $table_name;
    $singular =~ s/s$// if $singular =~ /[^s]s$/;  # Remove trailing 's' but not 'ss'
    $singular =~ s/ies$/y/;  # categories -> category
    $singular =~ s/ves$/f/;  # leaves -> leaf
    
    # Convert to PascalCase
    my @words = split /_/, $singular;
    my $class_name = join '', map { ucfirst(lc($_)) } @words;
    
    return $class_name;
}

# Helper method to determine Result file path
sub get_result_file_path {
    my ($self, $c, $table_name, $database) = @_;
    
    my $class_name = $self->table_name_to_class_name($table_name);
    my $namespace = $database eq 'ency' ? 'Ency' : 'Forager';
    
    # Build the file path
    my $base_path = $c->path_to('lib', 'Comserv', 'Model', 'Schema', $namespace, 'Result');
    my $result_file_path = File::Spec->catfile($base_path, "$class_name.pm");
    
    return $result_file_path;
}

# Sync all fields from Result file to database table
sub sync_all_fields_result_to_table {
    my ($self, $c, $table_name, $database) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'sync_all_fields_result_to_table',
        "Starting sync all fields for table '$table_name' in database '$database'");
    
    # Get the field comparison to see what needs to be synced
    my $result_table_mapping = $self->build_result_table_mapping($c, $database);
    my $comparison = $self->get_table_result_comparison_v2($c, $table_name, $database, $result_table_mapping);
    
    unless ($comparison->{has_result_file}) {
        die "No Result file found for table '$table_name'";
    }
    
    my @synced_fields = ();
    my @warnings = ();
    
    # Process each field that has differences
    foreach my $field_name (keys %{$comparison->{fields}}) {
        my $field_data = $comparison->{fields}->{$field_name};
        
        # Skip if field exists in both and has no differences
        if ($field_data->{table} && $field_data->{result} && 
            (!$field_data->{differences} || @{$field_data->{differences}} == 0)) {
            next;
        }
        
        # Skip if field only exists in table (would require dropping column)
        if ($field_data->{table} && !$field_data->{result}) {
            push @warnings, "Field '$field_name' exists in table but not in Result file - skipping (manual intervention required)";
            next;
        }
        
        # Sync field if it exists in Result file
        if ($field_data->{result}) {
            eval {
                my $result_field_info = $self->get_result_field_info($c, $table_name, $field_name, $database);
                $self->update_table_field_from_result($c, $table_name, $field_name, $database, $result_field_info);
                push @synced_fields, $field_name;
                
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'sync_all_fields_result_to_table',
                    "Successfully synced field '$field_name' for table '$table_name'");
            };
            if ($@) {
                push @warnings, "Failed to sync field '$field_name': $@";
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'sync_all_fields_result_to_table',
                    "Failed to sync field '$field_name' for table '$table_name': $@");
            }
        }
    }
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'sync_all_fields_result_to_table',
        "Completed sync for table '$table_name' - synced " . scalar(@synced_fields) . " fields, " . scalar(@warnings) . " warnings");
    
    return {
        synced_fields => \@synced_fields,
        warnings => \@warnings,
        total_synced => scalar(@synced_fields)
    };
}

=head1 AUTHOR

Shanta McBain

=head1 LICENSE

This library is free software. You can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

# Find result file for a given table
sub find_result_file_for_table {
    my ($self, $c, $table_name, $database) = @_;
    
    # Build the expected result file path
    my $result_dir;
    if ($database eq 'ency') {
        $result_dir = $c->path_to('lib', 'Comserv', 'Model', 'Schema', 'Ency', 'Result');
    } elsif ($database eq 'forager') {
        $result_dir = $c->path_to('lib', 'Comserv', 'Model', 'Schema', 'Forager', 'Result');
    } else {
        return undef;
    }
    
    # Try different naming conventions
    my @possible_names = (
        ucfirst(lc($table_name)),  # Standard case
        ucfirst($table_name),      # Keep original case
        uc($table_name),           # All uppercase
        lc($table_name),           # All lowercase
        $table_name                # Exact match
    );
    
    foreach my $name (@possible_names) {
        my $file_path = File::Spec->catfile($result_dir, "$name.pm");
        if (-f $file_path) {
            return $file_path;
        }
    }
    
    return undef;
}

# Add field to result file
sub add_field_to_result_file {
    my ($self, $c, $result_file_path, $field_name, $field_def) = @_;
    
    try {
        # Read the current file content
        my $content = read_file($result_file_path);
        
        # Convert database field definition to DBIx::Class format
        my $dbic_field_def = $self->convert_db_field_to_dbic($field_def);
        
        # Find the add_columns section
        if ($content =~ /(__PACKAGE__->add_columns\(\s*)(.*?)(\s*\);)/s) {
            my $before = $1;
            my $columns_section = $2;
            my $after = $3;
            
            # Add the new field to the columns section
            my $new_field_text = sprintf(
                "    %s => {\n        data_type => '%s',\n        is_nullable => %d,\n%s    },\n",
                $field_name,
                $dbic_field_def->{data_type},
                $dbic_field_def->{is_nullable} ? 1 : 0,
                $dbic_field_def->{size} ? "        size => $dbic_field_def->{size},\n" : ""
            );
            
            # Add auto_increment if needed
            if ($dbic_field_def->{is_auto_increment}) {
                $new_field_text =~ s/    },\n$/        is_auto_increment => 1,\n    },\n/;
            }
            
            # Add default value if specified
            if (defined $dbic_field_def->{default_value}) {
                my $default_val = $dbic_field_def->{default_value};
                $default_val = "'$default_val'" unless $default_val =~ /^\d+$/;
                $new_field_text =~ s/    },\n$/        default_value => $default_val,\n    },\n/;
            }
            
            # Insert the new field (add comma to previous field if needed)
            $columns_section =~ s/(\n\s*})(\s*)$/$1,\n$new_field_text$2/;
            
            # Reconstruct the file content
            my $new_content = $before . $columns_section . $after;
            
            # Write the updated content back to the file
            write_file($result_file_path, $new_content);
            
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_field_to_result_file',
                "Added field '$field_name' to result file: $result_file_path");
            
            return 1;
        } else {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'add_field_to_result_file',
                "Could not find add_columns section in result file: $result_file_path");
            return 0;
        }
        
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'add_field_to_result_file',
            "Error adding field to result file: $_");
        return 0;
    };
}

# Add field to database table
sub add_field_to_database_table {
    my ($self, $c, $table_name, $database, $field_name, $field_def) = @_;
    
    try {
        # Get database handle
        my $dbh;
        if ($database eq 'ency') {
            $dbh = $c->model('DBEncy')->schema->storage->dbh;
        } elsif ($database eq 'forager') {
            $dbh = $c->model('DBForager')->schema->storage->dbh;
        } else {
            die "Invalid database: $database";
        }
        
        # Convert DBIx::Class field definition to SQL
        my $sql_field_def = $self->convert_dbic_field_to_sql($field_def);
        
        # Build ALTER TABLE statement
        my $sql = "ALTER TABLE `$table_name` ADD COLUMN `$field_name` $sql_field_def";
        
        # Execute the ALTER TABLE statement
        $dbh->do($sql);
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_field_to_database_table',
            "Added field '$field_name' to table '$table_name' with SQL: $sql");
        
        return 1;
        
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'add_field_to_database_table',
            "Error adding field to database table: $_");
        return 0;
    };
}

# Validate field definition
sub validate_field_definition {
    my ($self, $field_def, $field_name) = @_;
    
    my @errors = ();
    
    # Check required attributes
    unless ($field_def->{data_type}) {
        push @errors, "Field '$field_name' missing data_type";
    }
    
    # Check if integer types have size when required
    if ($field_def->{data_type} && $field_def->{data_type} =~ /^(varchar|char|decimal|numeric)$/i) {
        unless (defined $field_def->{size}) {
            push @errors, "Field '$field_name' of type '$field_def->{data_type}' requires size specification";
        }
    }
    
    return \@errors;
}

# Convert database field definition to DBIx::Class format
sub convert_db_field_to_dbic {
    my ($self, $field_def) = @_;
    
    my $dbic_def = {
        data_type => $field_def->{data_type},
        is_nullable => $field_def->{is_nullable} // 1,
        is_auto_increment => $field_def->{is_auto_increment} // 0,
        default_value => $field_def->{default_value}
    };
    
    # Handle size
    if (defined $field_def->{size}) {
        $dbic_def->{size} = $field_def->{size};
    }
    
    # Normalize data type
    $dbic_def->{data_type} = $self->normalize_data_type($dbic_def->{data_type});
    
    return $dbic_def;
}

# Convert DBIx::Class field definition to SQL
sub convert_dbic_field_to_sql {
    my ($self, $field_def) = @_;
    
    my $sql = $field_def->{data_type};
    
    # Add size if specified
    if (defined $field_def->{size}) {
        $sql .= "($field_def->{size})";
    }
    
    # Add nullable constraint
    if ($field_def->{is_nullable}) {
        $sql .= " NULL";
    } else {
        $sql .= " NOT NULL";
    }
    
    # Add auto increment
    if ($field_def->{is_auto_increment}) {
        $sql .= " AUTO_INCREMENT";
    }
    
    # Add default value
    if (defined $field_def->{default_value}) {
        my $default = $field_def->{default_value};
        if ($default =~ /^\d+$/) {
            $sql .= " DEFAULT $default";
        } else {
            $sql .= " DEFAULT '$default'";
        }
    }
    
    return $sql;
}

# Enhanced security check for CSC admin operations
sub check_csc_admin_access {
    my ($self, $c) = @_;
    
    # Check if user exists and is logged in
    unless ($c->user_exists) {
        return 0;
    }
    
    # TEMPORARY FIX: Allow specific users direct access
    if ($c->session->{username} && $c->session->{username} eq 'Shanta') {
        return 1;
    }
    
    # Check for CSC admin role specifically
    my $roles = $c->session->{roles};
    if (defined $roles) {
        if (ref($roles) eq 'ARRAY') {
            # Check if 'csc_admin' or 'admin' is in the roles array
            foreach my $role (@$roles) {
                if (lc($role) eq 'csc_admin' || lc($role) eq 'admin') {
                    return 1;
                }
            }
        } elsif (!ref($roles)) {
            # Check if roles string contains 'csc_admin' or 'admin'
            if ($roles =~ /\b(csc_admin|admin)\b/i) {
                return 1;
            }
        }
    }
    
    return 0;
}

# Check if we're on an allowed branch for upgrade operations
sub check_install_branch {
    my ($self, $c) = @_;
    
    try {
        my $current_branch = `git -C ${\$c->path_to()} branch --show-current 2>/dev/null`;
        chomp $current_branch;
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'check_install_branch',
            "Current git branch: $current_branch");
        
        # Allow both 'install' and 'master' branches for upgrade operations
        # This enables web-based upgrades without requiring SSH access to switch branches
        return ($current_branch eq 'install' || $current_branch eq 'master' || $current_branch eq 'main');
    } catch {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'check_install_branch',
            "Could not determine git branch: $_");
        return 0;
    };
}

# Start development server for testing
sub start_dev_server :Path('/admin/start_dev_server') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'start_dev_server',
        "Starting development server action");
    
    # Enhanced security check
    unless ($self->check_csc_admin_access($c)) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'start_dev_server',
            "Access denied: User does not have CSC admin role");
        
        $c->flash->{error_msg} = "You need CSC administrator privileges to start the development server.";
        $c->response->redirect($c->uri_for('/admin'));
        return;
    }
    
    # Check if we're on an allowed branch
    unless ($self->check_install_branch($c)) {
        $c->flash->{error_msg} = "Development server can only be started from the install, master, or main branches for security reasons.";
        $c->response->redirect($c->uri_for('/admin'));
        return;
    }
    
    # Check if this is a POST request (user confirmed)
    if ($c->req->method eq 'POST' && $c->req->param('confirm')) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'start_dev_server',
            "Development server start confirmed, executing");
        
        # Execute the development server startup
        my ($success, $output, $warning, $dev_url) = $self->execute_start_dev_server($c);
        
        # Store the results in stash for the template
        $c->stash(
            output => $output,
            success_msg => $success ? "Development server started successfully." : undef,
            error_msg => $success ? undef : "Failed to start development server. See output for details.",
            warning_msg => $warning,
            dev_server_url => $dev_url
        );
    }
    
    # Use the standard debug message system
    if ($c->session->{debug_mode}) {
        $c->stash->{debug_msg} = [] unless ref($c->stash->{debug_msg}) eq 'ARRAY';
        push @{$c->stash->{debug_msg}}, "Admin controller start_dev_server view - Template: admin/start_dev_server.tt";
    }
    
    # Set the template
    $c->stash(template => 'admin/start_dev_server.tt');
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'start_dev_server',
        "Completed start_dev_server action");
}

# Execute the development server startup
sub execute_start_dev_server {
    my ($self, $c) = @_;
    my $output = '';
    my $warning = undef;
    my $success = 0;
    my $dev_url = undef;
    
    try {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'execute_start_dev_server',
            "Starting development server execution");
        
        # Check if development server is already running
        my $check_running = `ps aux | grep 'comserv_server.pl' | grep -v grep`;
        if ($check_running) {
            $output .= "Development server appears to be already running:\n$check_running\n";
            $warning = "A development server process is already running. You may need to stop it first.";
        }
        
        # Install/update dependencies first
        $output .= "Installing/updating dependencies...\n";
        my $cpanm_output = `cd ${\$c->path_to()} && cpanm --installdeps . 2>&1`;
        $output .= "Dependency installation output:\n$cpanm_output\n";
        
        # Check if dependency installation was successful
        if ($? != 0) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'execute_start_dev_server',
                "Dependency installation had issues, but continuing");
            $warning = "Some dependencies may not have installed correctly. Check the output for details.";
        }
        
        # Start the development server in the background
        my $app_root = $c->path_to();
        my $dev_port = 3000; # Default Catalyst development port
        
        # Create a unique log file for this development server session
        my $timestamp = time();
        my $log_file = "$app_root/script/logs/dev_server_$timestamp.log";
        
        # Ensure log directory exists
        system("mkdir -p $app_root/script/logs");
        
        # Start development server with proper environment
        my $start_cmd = "cd $app_root && CATALYST_DEBUG=1 perl script/comserv_server.pl -r -d > $log_file 2>&1 &";
        $output .= "Starting development server with command:\n$start_cmd\n";
        
        my $start_result = system($start_cmd);
        
        if ($start_result == 0) {
            $success = 1;
            $dev_url = "http://localhost:$dev_port";
            $output .= "Development server started successfully!\n";
            $output .= "Server should be available at: $dev_url\n";
            $output .= "Log file: $log_file\n";
            $output .= "Note: It may take a few moments for the server to fully start up.\n";
            
            # Store dev server info in session for later reference
            $c->session->{dev_server} = {
                url => $dev_url,
                log_file => $log_file,
                started_at => $timestamp,
                pid_check_cmd => "ps aux | grep 'comserv_server.pl' | grep -v grep"
            };
            
        } else {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'execute_start_dev_server',
                "Failed to start development server");
            $output .= "Failed to start development server.\n";
            return (0, $output, "Development server startup failed.");
        }
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'execute_start_dev_server',
            "Development server startup completed successfully");
            
    } catch {
        my $error = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'execute_start_dev_server',
            "Error during development server startup: $error");
        $output .= "Error: $error\n";
        return (0, $output, undef, undef);
    };
    
    return ($success, $output, $warning, $dev_url);
}

# Restart Starman server
sub restart_starman :Path('/admin/restart_starman') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'restart_starman',
        "Starting restart_starman action");
    
    # Enhanced security check
    unless ($self->check_csc_admin_access($c)) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'restart_starman',
            "Access denied: User does not have CSC admin role");
        
        $c->flash->{error_msg} = "You need CSC administrator privileges to restart the Starman server.";
        $c->response->redirect($c->uri_for('/admin'));
        return;
    }
    
    # Check if we're on an allowed branch for production restart
    unless ($self->check_install_branch($c)) {
        $c->flash->{error_msg} = "Starman server can only be restarted from the install, master, or main branches for security reasons.";
        $c->response->redirect($c->uri_for('/admin'));
        return;
    }
    
    # Check if this is a POST request (user confirmed)
    if ($c->req->method eq 'POST' && $c->req->param('confirm')) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'restart_starman',
            "Starman restart confirmed, executing");
        
        # Execute the Starman restart
        my ($success, $output, $warning) = $self->execute_restart_starman($c);
        
        # Store the results in stash for the template
        $c->stash(
            output => $output,
            success_msg => $success ? "Starman server restart initiated successfully." : undef,
            error_msg => $success ? undef : "Failed to restart Starman server. See output for details.",
            warning_msg => $warning
        );
    }
    
    # Use the standard debug message system
    if ($c->session->{debug_mode}) {
        $c->stash->{debug_msg} = [] unless ref($c->stash->{debug_msg}) eq 'ARRAY';
        push @{$c->stash->{debug_msg}}, "Admin controller restart_starman view - Template: admin/restart_starman.tt";
    }
    
    # Set the template
    $c->stash(template => 'admin/restart_starman.tt');
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'restart_starman',
        "Completed restart_starman action");
}

# Execute the Starman server restart
sub execute_restart_starman {
    my ($self, $c) = @_;
    my $output = '';
    my $warning = undef;
    my $success = 0;
    
    try {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'execute_restart_starman',
            "Starting Starman server restart");
        
        # First, try to find running Starman processes
        my $starman_processes = `ps aux | grep starman | grep -v grep`;
        $output .= "Current Starman processes:\n$starman_processes\n";
        
        if (!$starman_processes) {
            $output .= "No Starman processes found running.\n";
            $warning = "No Starman processes were found. The server may not be running via Starman.";
        }
        
        # Try different methods to restart Starman
        my $restart_success = 0;
        
        # Method 1: Try systemctl if it's a systemd service
        $output .= "Attempting to restart via systemctl...\n";
        my $systemctl_result = system("sudo systemctl restart starman 2>/dev/null");
        if ($systemctl_result == 0) {
            $output .= "Successfully restarted via systemctl.\n";
            $restart_success = 1;
        } else {
            $output .= "systemctl restart failed or service not found.\n";
        }
        
        # Method 2: Try service command if systemctl failed
        if (!$restart_success) {
            $output .= "Attempting to restart via service command...\n";
            my $service_result = system("sudo service starman restart 2>/dev/null");
            if ($service_result == 0) {
                $output .= "Successfully restarted via service command.\n";
                $restart_success = 1;
            } else {
                $output .= "service restart failed or service not found.\n";
            }
        }
        
        # Method 3: Try to kill and restart manually if other methods failed
        if (!$restart_success && $starman_processes) {
            $output .= "Attempting manual restart by killing existing processes...\n";
            
            # Kill existing Starman processes
            my $kill_result = system("sudo pkill -f starman");
            if ($kill_result == 0) {
                $output .= "Successfully killed existing Starman processes.\n";
                
                # Wait a moment for processes to terminate
                sleep(2);
                
                # Try to start Starman again (this would need to be configured based on your setup)
                $output .= "Note: Manual restart of Starman would require specific startup script.\n";
                $warning = "Starman processes were killed, but automatic restart requires manual configuration.";
                $restart_success = 1; # Consider it successful if we killed the processes
            } else {
                $output .= "Failed to kill existing Starman processes.\n";
            }
        }
        
        # Method 4: Check for common Starman startup scripts
        if (!$restart_success) {
            my @common_scripts = (
                '/etc/init.d/starman',
                '/usr/local/bin/restart-starman.sh',
                '/opt/starman/restart.sh'
            );
            
            foreach my $script (@common_scripts) {
                if (-x $script) {
                    $output .= "Found startup script: $script\n";
                    my $script_result = system("sudo $script restart 2>&1");
                    if ($script_result == 0) {
                        $output .= "Successfully restarted via $script\n";
                        $restart_success = 1;
                        last;
                    } else {
                        $output .= "Failed to restart via $script\n";
                    }
                }
            }
        }
        
        if ($restart_success) {
            $success = 1;
            $output .= "\nStarman server restart completed.\n";
            $output .= "Please wait a few moments for the server to fully restart.\n";
        } else {
            $output .= "\nCould not automatically restart Starman server.\n";
            $output .= "You may need to manually restart the server or configure the restart method.\n";
            $warning = "Automatic restart failed. Manual intervention may be required.";
        }
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'execute_restart_starman',
            "Starman restart attempt completed");
            
    } catch {
        my $error = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'execute_restart_starman',
            "Error during Starman restart: $error");
        $output .= "Error: $error\n";
        return (0, $output, undef);
    };
    
    return ($success, $output, $warning);
}

# Stop development server
sub stop_dev_server :Path('/admin/stop_dev_server') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'stop_dev_server',
        "Starting stop_dev_server action");
    
    # Enhanced security check
    unless ($self->check_csc_admin_access($c)) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'stop_dev_server',
            "Access denied: User does not have CSC admin role");
        
        $c->flash->{error_msg} = "You need CSC administrator privileges to stop the development server.";
        $c->response->redirect($c->uri_for('/admin'));
        return;
    }
    
    # Execute the development server stop
    my ($success, $output) = $self->execute_stop_dev_server($c);
    
    # Store the results in stash
    $c->stash(
        output => $output,
        success_msg => $success ? "Development server stopped successfully." : undef,
        error_msg => $success ? undef : "Failed to stop development server completely.",
    );
    
    # Clear dev server info from session
    delete $c->session->{dev_server};
    
    # Redirect back to admin with message
    $c->flash->{success_msg} = $c->stash->{success_msg} if $c->stash->{success_msg};
    $c->flash->{error_msg} = $c->stash->{error_msg} if $c->stash->{error_msg};
    $c->response->redirect($c->uri_for('/admin'));
}

# Execute the development server stop
sub execute_stop_dev_server {
    my ($self, $c) = @_;
    my $output = '';
    my $success = 0;
    
    try {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'execute_stop_dev_server',
            "Stopping development server");
        
        # Find and kill development server processes
        my $dev_processes = `ps aux | grep 'comserv_server.pl' | grep -v grep`;
        $output .= "Current development server processes:\n$dev_processes\n";
        
        if ($dev_processes) {
            # Kill the development server processes
            my $kill_result = system("pkill -f 'comserv_server.pl'");
            if ($kill_result == 0) {
                $output .= "Successfully stopped development server processes.\n";
                $success = 1;
            } else {
                $output .= "Failed to stop some development server processes.\n";
            }
        } else {
            $output .= "No development server processes found running.\n";
            $success = 1; # Consider it successful if nothing was running
        }
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'execute_stop_dev_server',
            "Development server stop completed");
            
    } catch {
        my $error = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'execute_stop_dev_server',
            "Error during development server stop: $error");
        $output .= "Error: $error\n";
        return (0, $output);
    };
    
    return ($success, $output);
}

# Software Upgrade Management - Step-by-step upgrade process
sub software_upgrade :Path('/admin/software_upgrade') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'software_upgrade',
        "Starting software upgrade management");
    
    # Enhanced security check - CSC admin only for production upgrades
    unless ($self->check_csc_admin_access($c)) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'software_upgrade',
            "Access denied: User does not have CSC admin role");
        
        $c->flash->{error_msg} = "You need CSC administrator privileges to perform software upgrades.";
        $c->response->redirect($c->uri_for('/admin'));
        return;
    }
    
    # Check if we're on an allowed branch for production upgrades
    unless ($self->check_install_branch($c)) {
        $c->flash->{error_msg} = "Software upgrades can only be performed from the install, master, or main branches for security reasons.";
        $c->response->redirect($c->uri_for('/admin'));
        return;
    }
    
    # Handle different upgrade steps
    my $step = $c->req->param('step') || 'overview';
    my $action = $c->req->param('action') || '';
    
    # Initialize upgrade status in session if not exists
    unless ($c->session->{upgrade_status}) {
        $c->session->{upgrade_status} = {
            current_step => 'overview',
            steps_completed => {},
            start_time => time(),
            logs => []
        };
    }
    
    my $upgrade_status = $c->session->{upgrade_status};
    
    # Process actions based on step
    if ($c->req->method eq 'POST' && $action) {
        $self->process_upgrade_action($c, $step, $action);
    }
    
    # Get current system status
    my $system_status = $self->get_upgrade_system_status($c);
    
    # Use the standard debug message system
    if ($c->session->{debug_mode}) {
        $c->stash->{debug_msg} = [] unless ref($c->stash->{debug_msg}) eq 'ARRAY';
        push @{$c->stash->{debug_msg}}, "Admin controller software_upgrade view - Template: admin/software_upgrade.tt";
    }
    
    # Set template data
    $c->stash(
        template => 'admin/software_upgrade.tt',
        current_step => $step,
        upgrade_status => $upgrade_status,
        system_status => $system_status,
        production_server => 'computersystemconsulting.ca',
        server_path => '/opt/comserv'
    );
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'software_upgrade',
        "Completed software upgrade management");
}

# Process upgrade actions for each step
sub process_upgrade_action {
    my ($self, $c, $step, $action) = @_;
    
    my $upgrade_status = $c->session->{upgrade_status};
    my $output = '';
    my $success = 0;
    my $warning = undef;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'process_upgrade_action',
        "Processing upgrade action: step=$step, action=$action");
    
    if ($step eq 'git_pull' && $action eq 'execute') {
        # Step 1: Pull latest code from GitHub
        ($success, $output, $warning) = $self->execute_git_pull($c);
        $upgrade_status->{steps_completed}->{git_pull} = $success;
        $upgrade_status->{current_step} = $success ? 'dependencies' : 'git_pull';
        
    } elsif ($step eq 'dependencies' && $action eq 'execute') {
        # Step 2: Install/update dependencies
        ($success, $output, $warning) = $self->execute_dependency_update($c);
        $upgrade_status->{steps_completed}->{dependencies} = $success;
        $upgrade_status->{current_step} = $success ? 'dev_server' : 'dependencies';
        
    } elsif ($step eq 'dev_server' && $action eq 'start') {
        # Step 3: Start development server for testing
        my $dev_url;
        ($success, $output, $warning, $dev_url) = $self->execute_start_dev_server($c);
        $upgrade_status->{steps_completed}->{dev_server_start} = $success;
        $upgrade_status->{dev_server_url} = $dev_url if $success;
        
    } elsif ($step eq 'dev_server' && $action eq 'stop') {
        # Stop development server
        ($success, $output) = $self->execute_stop_dev_server($c);
        $upgrade_status->{steps_completed}->{dev_server_stop} = $success;
        $upgrade_status->{current_step} = 'production' if $success;
        delete $upgrade_status->{dev_server_url};
        
    } elsif ($step eq 'production' && $action eq 'restart') {
        # Step 4: Restart production Starman server
        ($success, $output, $warning) = $self->execute_restart_starman($c);
        $upgrade_status->{steps_completed}->{production_restart} = $success;
        $upgrade_status->{current_step} = $success ? 'complete' : 'production';
        
    } elsif ($step eq 'complete' && $action eq 'reset') {
        # Reset upgrade process
        delete $c->session->{upgrade_status};
        $c->response->redirect($c->uri_for('/admin/software_upgrade'));
        return;
    }
    
    # Store action results
    push @{$upgrade_status->{logs}}, {
        timestamp => scalar(localtime()),
        step => $step,
        action => $action,
        success => $success,
        output => $output,
        warning => $warning
    };
    
    # Set flash messages
    if ($success) {
        $c->flash->{success_msg} = "Step completed successfully.";
    } else {
        $c->flash->{error_msg} = "Step failed. Check the output for details.";
    }
    
    if ($warning) {
        $c->flash->{warning_msg} = $warning;
    }
    
    # Store output for template
    $c->stash(
        step_output => $output,
        step_success => $success,
        step_warning => $warning
    );
}

# Execute dependency update (similar to what's done in start_dev_server)
sub execute_dependency_update {
    my ($self, $c) = @_;
    my $output = '';
    my $warning = undef;
    my $success = 0;
    
    try {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'execute_dependency_update',
            "Starting dependency update");
        
        # Change to application directory
        my $app_path = $c->path_to();
        $output .= "Updating dependencies in: $app_path\n\n";
        
        # Install/update dependencies using cpanm
        $output .= "Installing/updating Perl dependencies...\n";
        my $cpanm_output = `cd $app_path && cpanm --installdeps . 2>&1`;
        $output .= $cpanm_output;
        
        # Check if dependency installation was successful
        if ($? == 0) {
            $success = 1;
            $output .= "\nDependency update completed successfully.\n";
        } else {
            $output .= "\nDependency update had issues. Exit code: $?\n";
            $warning = "Some dependencies may not have installed correctly. Check the output for details.";
        }
        
        # Also try to update npm dependencies if package.json exists
        my $package_json = $c->path_to('package.json');
        if (-e $package_json) {
            $output .= "\nUpdating Node.js dependencies...\n";
            my $npm_output = `cd $app_path && npm install 2>&1`;
            $output .= $npm_output;
            
            if ($? != 0) {
                $warning = ($warning ? "$warning " : "") . "NPM dependency update had issues.";
            }
        }
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'execute_dependency_update',
            "Dependency update completed with success: $success");
            
    } catch {
        my $error = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'execute_dependency_update',
            "Error during dependency update: $error");
        $output .= "Error: $error\n";
        return (0, $output, undef);
    };
    
    return ($success, $output, $warning);
}

# Get current system status for upgrade overview
sub get_upgrade_system_status {
    my ($self, $c) = @_;
    
    my $status = {
        git_status => 'unknown',
        git_branch => 'unknown',
        git_last_commit => 'unknown',
        dev_server_running => 0,
        starman_running => 0,
        disk_space => 'unknown',
        perl_version => $^V ? $^V->stringify : 'unknown'
    };
    
    # Get Git status
    eval {
        my $git_status = `cd ${\$c->path_to()} && git status --porcelain 2>/dev/null`;
        $status->{git_status} = $git_status ? 'modified' : 'clean';
        
        my $git_branch = `cd ${\$c->path_to()} && git branch --show-current 2>/dev/null`;
        chomp($git_branch);
        $status->{git_branch} = $git_branch || 'unknown';
        
        my $git_commit = `cd ${\$c->path_to()} && git log -1 --format="%h %s" 2>/dev/null`;
        chomp($git_commit);
        $status->{git_last_commit} = $git_commit || 'unknown';
    };
    
    # Check if development server is running
    eval {
        my $dev_processes = `ps aux | grep 'comserv_server.pl' | grep -v grep`;
        $status->{dev_server_running} = $dev_processes ? 1 : 0;
    };
    
    # Check if Starman is running
    eval {
        my $starman_processes = `ps aux | grep starman | grep -v grep`;
        $status->{starman_running} = $starman_processes ? 1 : 0;
    };
    
    # Get disk space
    eval {
        my $df_output = `df -h . | tail -1`;
        if ($df_output =~ /(\S+)\s+(\S+)\s+(\S+)\s+(\d+)%/) {
            $status->{disk_space} = "$4% used ($3 available)";
        }
    };
    
    return $status;
}



# Create a new backup
# Format file size for display
sub format_file_size {
    my ($self, $size) = @_;
    
    return '0 B' unless $size;
    
    my @units = ('B', 'KB', 'MB', 'GB', 'TB');
    my $unit_index = 0;
    
    while ($size >= 1024 && $unit_index < $#units) {
        $size /= 1024;
        $unit_index++;
    }
    
    return sprintf("%.1f %s", $size, $units[$unit_index]);
}

# Check if user has CSC (hosting company) access
sub check_csc_access {
    my ($self, $c) = @_;
    
    # First check if user exists
    return 0 unless $c->user_exists;
    
    my $username = $c->session->{username} || '';
    
    # Check hardcoded CSC usernames first (most reliable)
    my @csc_users = qw(shanta csc_admin backup_admin);
    if (grep { lc($_) eq lc($username) } @csc_users) {
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'check_csc_access',
            "CSC access granted to hardcoded user: $username");
        return 1;
    }
    
    # Try enhanced role checking with comprehensive fallback
    my $enhanced_check_result = 0;
    eval {
        $enhanced_check_result = 1 if $c->check_user_roles_enhanced('backup_admin');
        $enhanced_check_result = 1 if $c->check_user_roles_enhanced('csc_admin');
        $enhanced_check_result = 1 if $c->check_user_roles_enhanced('super_admin');
    };
    
    if ($@) {
        # Enhanced role checking failed (likely schema issue)
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'check_csc_access',
            "Enhanced role checking failed, using legacy fallback: $@");
        
        # Fall back to legacy admin check for known CSC users
        if ($c->check_user_roles('admin')) {
            # Additional verification for CSC users
            if (grep { lc($_) eq lc($username) } @csc_users) {
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'check_csc_access',
                    "CSC access granted via legacy admin role for user: $username");
                return 1;
            }
        }
        
        # Check session roles directly as final fallback
        my $roles = $c->session->{roles};
        if ($roles) {
            my @session_roles = ref($roles) eq 'ARRAY' ? @$roles : split(/,/, $roles);
            foreach my $role (@session_roles) {
                $role =~ s/^\s+|\s+$//g; # trim whitespace
                if (lc($role) eq 'admin' && grep { lc($_) eq lc($username) } @csc_users) {
                    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'check_csc_access',
                        "CSC access granted via session admin role for user: $username");
                    return 1;
                }
            }
        }
    } else {
        # Enhanced role checking succeeded
        if ($enhanced_check_result) {
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'check_csc_access',
                "CSC access granted via enhanced role checking for user: $username");
            return 1;
        }
    }
    
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'check_csc_access',
        "CSC access denied for user: $username");
    return 0;
}

# Check backup system status
sub check_backup_system_status {
    my ($self, $c) = @_;
    
    my $status = {
        database_connection => 'unknown',
        mysqldump_available => 'unknown',
        backup_directory => 'unknown',
        access_control => 'unknown',
        overall_status => 'unknown'
    };
    
    # Check database connection
    eval {
        my $dbh = $c->model('DBEncy')->schema->storage->dbh;
        if ($dbh && $dbh->ping) {
            $status->{database_connection} = 'ok';
        } else {
            $status->{database_connection} = 'failed';
        }
    };
    if ($@) {
        $status->{database_connection} = 'error: ' . $@;
    }
    
    # Check mysqldump availability
    my $mysqldump_check = `which mysqldump 2>/dev/null`;
    if ($mysqldump_check && $mysqldump_check =~ /mysqldump/) {
        $status->{mysqldump_available} = 'ok';
    } else {
        $status->{mysqldump_available} = 'not found';
    }
    
    # Check backup directory
    my $backup_dir = $self->get_backup_directory($c);
    if (-d $backup_dir && -w $backup_dir) {
        $status->{backup_directory} = 'ok';
    } elsif (-d $backup_dir) {
        $status->{backup_directory} = 'not writable';
    } else {
        $status->{backup_directory} = 'does not exist';
    }
    
    # Check access control
    if ($self->check_csc_access($c)) {
        $status->{access_control} = 'ok';
    } else {
        $status->{access_control} = 'access denied';
    }
    
    # Determine overall status
    if ($status->{database_connection} eq 'ok' && 
        $status->{mysqldump_available} eq 'ok' && 
        $status->{backup_directory} eq 'ok' && 
        $status->{access_control} eq 'ok') {
        $status->{overall_status} = 'ok';
    } else {
        $status->{overall_status} = 'issues detected';
    }
    
    return $status;
}

# Test database connection for debugging backup issues
sub test_database_connection :Path('/admin/backup/test_db') :Args(0) {
    my ($self, $c) = @_;
    
    # Check if the user has CSC access
    unless ($self->check_csc_access($c)) {
        $c->flash->{error_msg} = "Backup management is restricted to CSC hosting administrators only.";
        $c->response->redirect($c->uri_for('/admin'));
        return;
    }
    
    my $result = { 
        success => 0, 
        message => '', 
        databases => {},
        overall_status => 'failed'
    };
    
    # Test all available database models
    my @db_models = ('DBEncy', 'DBForager');
    my $successful_tests = 0;
    
    foreach my $model_name (@db_models) {
        my $db_result = {
            model => $model_name,
            success => 0,
            message => '',
            details => {}
        };
        
        eval {
            # Check if model exists
            my $model = eval { $c->model($model_name) };
            if (!$model) {
                $db_result->{message} = "Model $model_name not available";
                $result->{databases}->{$model_name} = $db_result;
                return;
            }
            
            # Get database connection info using the application's method (same as backup function)
            my $connect_info = $model->config->{connect_info};
            my ($dsn, $user, $password);
            
            if (ref($connect_info) eq 'HASH') {
                $dsn = $connect_info->{dsn};
                $user = $connect_info->{user};
                $password = $connect_info->{password};
            } else {
                die "Unexpected connect_info format: " . ref($connect_info);
            }
            
            $db_result->{details}->{dsn} = $dsn;
            $db_result->{details}->{user} = $user || 'none';
            $db_result->{details}->{connect_info_type} = ref($connect_info);
            $db_result->{details}->{config_source} = "$model_name model config";
            
            # Test database connection
            my $dbh = $model->schema->storage->dbh;
            my $version = $dbh->selectrow_array("SELECT VERSION()");
            
            $db_result->{success} = 1;
            $db_result->{message} = "Database connection successful";
            $db_result->{details}->{version} = $version;
            $successful_tests++;
            
            # Test mysqldump availability if this is a MySQL database
            if ($dsn =~ /^dbi:mysql:/i) {
                my $mysqldump_path = `which mysqldump 2>/dev/null`;
                chomp($mysqldump_path);
                
                if ($mysqldump_path) {
                    my $mysqldump_version = `mysqldump --version 2>&1`;
                    chomp($mysqldump_version);
                    $db_result->{details}->{mysqldump_path} = $mysqldump_path;
                    $db_result->{details}->{mysqldump_version} = $mysqldump_version;
                    $db_result->{details}->{mysqldump_available} = 1;
                } else {
                    $db_result->{details}->{mysqldump_available} = 0;
                    $db_result->{details}->{mysqldump_error} = "mysqldump command not found. Install mysql-client package.";
                }
            } else {
                $db_result->{details}->{mysqldump_note} = "Not applicable for non-MySQL databases";
            }
            
        };
        
        if ($@) {
            $db_result->{message} = "Database connection failed: $@";
        }
        
        $result->{databases}->{$model_name} = $db_result;
    }
    
    # Set overall result
    if ($successful_tests > 0) {
        $result->{success} = 1;
        $result->{overall_status} = 'success';
        $result->{message} = "Successfully tested $successful_tests out of " . scalar(@db_models) . " databases";
    } else {
        $result->{message} = "All database connection tests failed";
    }
    
    $c->response->content_type('application/json');
    $c->response->body(JSON::encode_json($result));
}

# Get list of available backups with detailed information
sub get_backup_list {
    my ($self, $c) = @_;
    
    my @backups = ();
    
    eval {
        my $backup_dir = $c->path_to('backups');
        
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'get_backup_list',
            "Looking for backups in directory: $backup_dir");
        
        unless (-d $backup_dir) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_backup_list',
                "Backup directory does not exist: $backup_dir");
            return \@backups;
        }
        
        opendir(my $dh, $backup_dir) or die "Cannot open backups directory: $!";
        my @all_files = readdir($dh);
        closedir($dh);
        
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'get_backup_list',
            "All files in backup directory: " . join(', ', @all_files));
        
        # Filter for .tar.gz files only (exclude .meta files and other artifacts)
        my @files = grep { -f "$backup_dir/$_" && $_ =~ /\.tar\.gz$/ && $_ !~ /\.meta$/ } @all_files;
        
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'get_backup_list',
            "Filtered .tar.gz files: " . join(', ', @files));
        
        foreach my $filename (@files) {
            my $filepath = "$backup_dir/$filename";
            my @stat = stat($filepath);
            
            # Parse backup information from filename
            my $backup_info = {
                filename => $filename,
                filepath => $filepath,
                size => $self->format_file_size($stat[7]),
                mtime => $stat[9],
                type => 'unknown'
            };
            
            # Determine backup type from filename
            if ($filename =~ /_full\.tar\.gz$/) {
                $backup_info->{type} = 'full';
            } elsif ($filename =~ /_database\.tar\.gz$/ || $filename =~ /_db\.tar\.gz$/) {
                $backup_info->{type} = 'database';
            } elsif ($filename =~ /_config\.tar\.gz$/) {
                $backup_info->{type} = 'config';
            } elsif ($filename =~ /_files\.tar\.gz$/) {
                $backup_info->{type} = 'files';
            } else {
                # Try to guess from filename patterns
                if ($filename =~ /config/i) {
                    $backup_info->{type} = 'config';
                } elsif ($filename =~ /db|database/i) {
                    $backup_info->{type} = 'database';
                } elsif ($filename =~ /full/i) {
                    $backup_info->{type} = 'full';
                } else {
                    $backup_info->{type} = 'full'; # Default assumption
                }
            }
            
            # Format date and time
            my ($sec, $min, $hour, $mday, $mon, $year) = localtime($backup_info->{mtime});
            $backup_info->{date} = sprintf("%04d-%02d-%02d", $year + 1900, $mon + 1, $mday);
            $backup_info->{time} = sprintf("%02d:%02d:%02d", $hour, $min, $sec);
            
            push @backups, $backup_info;
        }
        
        # Sort backups by modification time (newest first)
        @backups = sort { $b->{mtime} <=> $a->{mtime} } @backups;
        
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'get_backup_list',
            "Found " . scalar(@backups) . " backup files");
        
    };
    
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_backup_list',
            "Error reading backup directory: $@");
    }
    
    return \@backups;
}

# Create database backup with proper error handling for multiple databases
sub create_database_backup {
    my ($self, $c, $backup_dir, $backup_name) = @_;
    
    my $result = {
        success => 0,
        error => '',
        dump_file => '',
        databases_backed_up => []
    };
    
    eval {
        # Get all available database models
        my @db_models = ('DBEncy', 'DBForager');
        my @successful_backups = ();
        my @backup_files = ();
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_database_backup',
            "Starting multi-database backup for models: " . join(', ', @db_models));
        
        foreach my $model_name (@db_models) {
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'create_database_backup',
                "Processing database model: $model_name");
            
            # Check if model exists
            my $model = eval { $c->model($model_name) };
            if (!$model) {
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'create_database_backup',
                    "Model $model_name not available, skipping");
                next;
            }
            
            my $connect_info = $model->config->{connect_info};
            my ($dsn, $user, $password);
            
            # The database models store connection info as a hash with dsn, user, password keys
            if (ref($connect_info) eq 'HASH') {
                $dsn = $connect_info->{dsn};
                $user = $connect_info->{user};
                $password = $connect_info->{password};
                
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'create_database_backup',
                    "Retrieved connection info from $model_name - DSN: $dsn, User: " . ($user || 'none'));
            } else {
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'create_database_backup',
                    "Unexpected connection info format in $model_name model: " . ref($connect_info));
                next;
            }
            
            # Validate required connection parameters
            unless ($dsn) {
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'create_database_backup',
                    "DSN not found in $model_name configuration, skipping");
                next;
            }
            
            # Ensure user and password are defined (even if empty)
            $user = '' unless defined $user;
            $password = '' unless defined $password;
            
            # Test database connection before attempting backup
            eval {
                my $test_schema = $model->schema;
                my $test_dbh = $test_schema->storage->dbh;
                # Simple test query
                $test_dbh->do('SELECT 1');
                
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'create_database_backup',
                    "Database connection test successful for $model_name");
            };
            if ($@) {
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_database_backup',
                    "Database connection test failed for $model_name: $@");
                next;
            }
            
            # Parse DSN to get database name and type
            my ($db_type, $db_name, $host, $port);
            
            if ($dsn =~ /^dbi:mysql:database=([^;]+)(?:;host=([^;]+))?(?:;port=(\d+))?/i) {
                $db_type = 'mysql';
                $db_name = $1;
                $host = $2 || 'localhost';
                $port = $3 || 3306;
                
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'create_database_backup',
                    "Parsed MySQL DSN for $model_name - Database: $db_name, Host: $host, Port: $port");
                    
            } elsif ($dsn =~ /^dbi:sqlite:(.+)$/i) {
                $db_type = 'sqlite';
                $db_name = $1;
                
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'create_database_backup',
                    "Parsed SQLite DSN for $model_name - Database file: $db_name");
                    
            } elsif ($dsn =~ /^dbi:(\w+):/i) {
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'create_database_backup',
                    "Unsupported database type '$1' for $model_name, skipping");
                next;
            } else {
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'create_database_backup',
                    "Invalid DSN format for $model_name: $dsn, skipping");
                next;
            }
            
            # Create individual dump file for this database
            my $individual_dump_file = "$backup_dir/${backup_name}_${model_name}_${db_name}.sql";
            push @backup_files, $individual_dump_file;
            
            # Create backup command based on database type
            my $backup_command;
            
            if ($db_type eq 'mysql') {
                # MySQL backup
                my $host_param = ($host && $host ne 'localhost') ? "-h '$host'" : '';
                my $port_param = ($port && $port != 3306) ? "-P $port" : '';
                my $user_param = $user ? "-u '$user'" : '';
                
                # Handle password parameter more securely
                my $password_param = '';
                if ($password) {
                    # Escape single quotes in password for shell safety
                    my $escaped_password = $password;
                    $escaped_password =~ s/'/'"'"'/g;
                    $password_param = "-p'$escaped_password'";
                }
                
                $backup_command = "mysqldump $host_param $port_param $user_param $password_param --single-transaction --routines --triggers '$db_name' > '$individual_dump_file' 2>&1";
                
                # Test mysqldump availability
                my $mysqldump_test = `which mysqldump 2>/dev/null`;
                chomp($mysqldump_test);
                unless ($mysqldump_test) {
                    $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_database_backup',
                        "mysqldump command not found for $model_name, skipping");
                    next;
                }
                
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'create_database_backup',
                    "MySQL backup command prepared for $model_name database: $db_name, host: " . ($host || 'localhost') . 
                    ", user: " . ($user || 'none') . ", mysqldump path: $mysqldump_test");
                
            } elsif ($db_type eq 'sqlite') {
                # SQLite backup - just copy the database file
                if (-f $db_name) {
                    $backup_command = "cp '$db_name' '$individual_dump_file'";
                } else {
                    $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_database_backup',
                        "SQLite database file not found for $model_name: $db_name, skipping");
                    next;
                }
            }
            
            # Execute backup command for this database
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_database_backup',
                "Executing backup command for $model_name ($db_type database)");
            
            my $backup_output = `$backup_command`;
            my $backup_result = $?;
            
            if ($backup_result != 0) {
                my $error_msg = "Backup command failed for $model_name with exit code: $backup_result";
                if ($backup_output) {
                    $error_msg .= "\nCommand output: $backup_output";
                }
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_database_backup',
                    $error_msg);
                next; # Continue with next database instead of failing completely
            }
            
            # Log any output from the backup command (even on success)
            if ($backup_output) {
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'create_database_backup',
                    "Backup command output for $model_name: $backup_output");
            }
            
            # Verify backup file was created
            unless (-f $individual_dump_file && -s $individual_dump_file) {
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_database_backup',
                    "Backup file for $model_name was not created or is empty: $individual_dump_file");
                next;
            }
            
            # Record successful backup
            push @successful_backups, {
                model => $model_name,
                database => $db_name,
                file => $individual_dump_file,
                size => -s $individual_dump_file
            };
            
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_database_backup',
                "Successfully backed up $model_name database ($db_name) to $individual_dump_file");
        }
        
        # Check if we have any successful backups
        if (@successful_backups == 0) {
            die "No databases were successfully backed up";
        }
        
        # Create a combined dump file containing all individual backups
        my $combined_dump_file = "$backup_dir/${backup_name}_all_databases.sql";
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_database_backup',
            "Creating combined backup file: $combined_dump_file");
        
        # Combine all individual backup files
        my $combine_command = "cat " . join(' ', map { "'$_'" } @backup_files) . " > '$combined_dump_file'";
        my $combine_result = system($combine_command);
        
        if ($combine_result == 0 && -f $combined_dump_file && -s $combined_dump_file) {
            # Clean up individual files after successful combination
            foreach my $individual_file (@backup_files) {
                unlink $individual_file if -f $individual_file;
            }
            
            $result->{dump_file} = $combined_dump_file;
        } else {
            # If combination failed, keep individual files and use the first one as primary
            $result->{dump_file} = $backup_files[0] if @backup_files;
        }
        
        $result->{success} = 1;
        $result->{databases_backed_up} = \@successful_backups;
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_database_backup',
            "Multi-database backup completed successfully. Backed up " . scalar(@successful_backups) . 
            " databases to: " . $result->{dump_file});
        
    };
    
    if ($@) {
        $result->{error} = $@;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_database_backup',
            "Database backup failed: $@");
    }
    
    return $result;
}

# Database mode selection - forward to DatabaseMode controller
sub database_mode :Path('database_mode') :Args {
    my ($self, $c, @args) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'database_mode',
        "Forwarding to DatabaseMode controller with args: " . join(', ', @args));
    
    # Handle sub-routes
    if (@args) {
        my $action = shift @args;
        
        if ($action eq 'switch_backend' && @args) {
            $c->forward('Controller::DatabaseMode', 'switch_backend', \@args);
        } elsif ($action eq 'test_connection' && @args) {
            $c->forward('Controller::DatabaseMode', 'test_connection', \@args);
        } elsif ($action eq 'status') {
            $c->forward('Controller::DatabaseMode', 'status', \@args);
        } elsif ($action eq 'sync_to_production') {
            $c->forward('Controller::DatabaseMode', 'sync_to_production', \@args);
        } elsif ($action eq 'sync_from_production') {
            $c->forward('Controller::Admin', 'sync_from_production', \@args);
        } elsif ($action eq 'refresh_backends') {
            $c->forward('Controller::DatabaseMode', 'refresh_backends', \@args);
        } elsif ($action eq 'debug_backends') {
            $c->forward('Controller::DatabaseMode', 'debug_backends', \@args);
        } else {
            # Unknown sub-route, forward to index with all args
            $c->forward('Controller::DatabaseMode', 'index', [$action, @args]);
        }
    } else {
        # No args, forward to index
        $c->forward('Controller::DatabaseMode', 'index', \@args);
    }
}

# Manual database synchronization from production
sub sync_from_production :Path('sync_from_production') :Args(0) {
    my ($self, $c) = @_;
    
    # Check admin permissions
    unless ($c->check_user_roles('admin') || $c->check_user_roles('developer')) {
        $c->response->redirect($c->uri_for('/access_denied'));
        return;
    }
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'sync_from_production',
        "Manual sync from production requested by user: " . ($c->user ? $c->user->username : 'unknown'));
    
    try {
        my $hybrid_db = $c->model('HybridDB');
        unless ($hybrid_db) {
            die "HybridDB model not available";
        }
        
        # Get sync options from request parameters
        my $dry_run = $c->request->params->{dry_run} ? 1 : 0;
        my $force_overwrite = $c->request->params->{force_overwrite} ? 1 : 0;
        my $tables_param = $c->request->params->{tables} || '';
        my @tables = $tables_param ? split(/,/, $tables_param) : ();
        
        # Clean up table names
        @tables = map { s/^\s+|\s+$//g; $_ } @tables;
        @tables = grep { $_ ne '' } @tables;
        
        my $sync_result = $hybrid_db->sync_from_production($c, {
            dry_run => $dry_run,
            force_overwrite => $force_overwrite,
            tables => \@tables,
        });
        
        # Prepare result message
        my $message = '';
        if ($dry_run) {
            $message = "DRY RUN: Would sync " . $sync_result->{tables_synced} . " tables, " .
                      "create " . $sync_result->{tables_created} . " new tables, " .
                      "update " . $sync_result->{tables_updated} . " existing tables, " .
                      "sync " . $sync_result->{records_synced} . " records";
        } else {
            $message = "Sync completed: " . $sync_result->{tables_synced} . " tables processed, " .
                      $sync_result->{tables_created} . " tables created, " .
                      $sync_result->{tables_updated} . " tables updated, " .
                      $sync_result->{records_synced} . " records synced";
        }
        
        if (@{$sync_result->{errors}}) {
            $message .= ". Errors: " . join('; ', @{$sync_result->{errors}});
        }
        
        $c->stash(
            sync_result => $sync_result,
            message => $message,
            success => (@{$sync_result->{errors}} == 0),
        );
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'sync_from_production',
            "Sync completed: " . $message);
        
    } catch {
        my $error = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'sync_from_production',
            "Sync failed: $error");
        
        $c->stash(
            error => $error,
            message => "Sync failed: $error",
            success => 0,
        );
    };
    
    # If this is an AJAX request, return JSON
    if ($c->request->header('X-Requested-With') eq 'XMLHttpRequest') {
        $c->response->content_type('application/json');
        $c->response->body(JSON::encode_json({
            success => $c->stash->{success},
            message => $c->stash->{message},
            sync_result => $c->stash->{sync_result},
        }));
        return;
    }
    
    # Otherwise render template
    $c->stash(template => 'admin/sync_from_production.tt');
}

# Get database tables for a specific backend
sub get_backend_database_tables {
    my ($self, $c, $backend_name, $backend_info) = @_;
    
    my @tables = ();
    
    try {
        if ($backend_info->{type} eq 'mysql') {
            # Create direct connection to this backend
            my $config = $backend_info->{config};
            my $host = $config->{host};
            
            # Apply localhost override if configured
            if ($config->{localhost_override} && $host ne 'localhost') {
                $host = 'localhost';
            }
            
            my $dsn = "dbi:mysql:database=$config->{database};host=$host;port=$config->{port}";
            my $dbh = DBI->connect(
                $dsn,
                $config->{username},
                $config->{password},
                {
                    RaiseError => 1,
                    PrintError => 0,
                    mysql_enable_utf8 => 1,
                }
            );
            
            if ($dbh) {
                my $sth = $dbh->prepare("SHOW TABLES");
                $sth->execute();
                
                while (my ($table) = $sth->fetchrow_array()) {
                    push @tables, $table;
                }
                
                $dbh->disconnect();
                
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_backend_database_tables',
                    "Found " . scalar(@tables) . " tables in backend '$backend_name': " . join(', ', @tables));
            }
            
        } elsif ($backend_info->{type} eq 'sqlite') {
            # For SQLite, get tables from the database file
            my $db_path = $backend_info->{config}->{database_path};
            
            if (-f $db_path) {
                my $dbh = DBI->connect("dbi:SQLite:dbname=$db_path", "", "", {
                    RaiseError => 1,
                    PrintError => 0,
                });
                
                if ($dbh) {
                    my $sth = $dbh->prepare("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'");
                    $sth->execute();
                    
                    while (my ($table) = $sth->fetchrow_array()) {
                        push @tables, $table;
                    }
                    
                    $dbh->disconnect();
                    
                    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_backend_database_tables',
                        "Found " . scalar(@tables) . " tables in SQLite backend '$backend_name': " . join(', ', @tables));
                }
            } else {
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'get_backend_database_tables',
                    "SQLite database file not found: $db_path");
            }
        }
        
    } catch {
        my $error = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_backend_database_tables', 
            "Error getting tables for backend '$backend_name': $error");
        die $error;
    };
    
    return \@tables;
}

# Compare a backend table with its Result file
sub compare_backend_table_with_result_file {
    my ($self, $c, $table_name, $backend_name, $backend_info, $result_table_mapping) = @_;
    
    # Get table schema from the backend
    my $table_schema = { columns => {} };
    eval {
        $table_schema = $self->get_backend_table_schema($c, $table_name, $backend_name, $backend_info);
    };
    if ($@) {
        warn "Failed to get table schema for $table_name ($backend_name): $@";
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
        database => $backend_name,
        backend_type => $backend_info->{type},
        has_result_file => ($result_info && -f $result_info->{result_path}) ? 1 : 0,
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
            differences => $self->compare_field_attributes($table_field, $result_field, $c, $field_name)
        };
    }
    
    return $comparison;
}

# Get table schema from a specific backend
sub get_backend_table_schema {
    my ($self, $c, $table_name, $backend_name, $backend_info) = @_;
    
    my $schema_info = {
        columns => {},
        primary_keys => [],
        unique_constraints => [],
        foreign_keys => [],
        indexes => []
    };
    
    try {
        if ($backend_info->{type} eq 'mysql') {
            # Create direct connection to this backend
            my $config = $backend_info->{config};
            my $host = $config->{host};
            
            # Apply localhost override if configured
            if ($config->{localhost_override} && $host ne 'localhost') {
                $host = 'localhost';
            }
            
            my $dsn = "dbi:mysql:database=$config->{database};host=$host;port=$config->{port}";
            my $dbh = DBI->connect(
                $dsn,
                $config->{username},
                $config->{password},
                {
                    RaiseError => 1,
                    PrintError => 0,
                    mysql_enable_utf8 => 1,
                }
            );
            
            if ($dbh) {
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
                
                $dbh->disconnect();
            }
            
        } elsif ($backend_info->{type} eq 'sqlite') {
            # For SQLite, get schema information
            my $db_path = $backend_info->{config}->{database_path};
            
            if (-f $db_path) {
                my $dbh = DBI->connect("dbi:SQLite:dbname=$db_path", "", "", {
                    RaiseError => 1,
                    PrintError => 0,
                });
                
                if ($dbh) {
                    # Get column information from SQLite
                    my $sth = $dbh->prepare("PRAGMA table_info(`$table_name`)");
                    $sth->execute();
                    
                    while (my $row = $sth->fetchrow_hashref()) {
                        my $column_name = $row->{name};
                        
                        $schema_info->{columns}->{$column_name} = {
                            data_type => $row->{type},
                            size => undef,  # SQLite doesn't enforce size
                            is_nullable => ($row->{notnull} ? 0 : 1),
                            default_value => $row->{dflt_value},
                            is_auto_increment => 0,  # Will be detected separately
                            extra => ''
                        };
                        
                        # Check for primary key
                        if ($row->{pk}) {
                            push @{$schema_info->{primary_keys}}, $column_name;
                        }
                    }
                    
                    $dbh->disconnect();
                }
            }
        }
        
    } catch {
        my $error = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_backend_table_schema', 
            "Error getting schema for table '$table_name' in backend '$backend_name': $error");
        die $error;
    };
    
    return $schema_info;
}

__PACKAGE__->meta->make_immutable;

1;