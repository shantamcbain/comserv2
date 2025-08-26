
package Comserv::Controller::Admin;


use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;
use Data::Dumper;
use JSON;
use Try::Tiny;
use MIME::Base64;
use File::Slurp;
use File::Basename;
use File::Path qw(make_path);
use File::Copy;
use Digest::SHA qw(sha256_hex);

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
    my $username = $c->user_exists ? $c->user->username : 'Guest';
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
sub index :Chained('base') :PathPart('') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', 
        "Starting Admin index action");
    
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

# Page migration from Forager to Ency schema
sub migrate_pages :Chained('base') :PathPart('migrate_pages') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'migrate_pages', 
        "Starting page migration process");
    
    if ($c->request->method eq 'POST') {
        my $action = $c->request->param('action') || '';
        
        if ($action eq 'preview') {
            # Preview migration - show what would be migrated
            my $preview_data = $self->_preview_page_migration($c);
            $c->stash(
                preview_data => $preview_data,
                show_preview => 1
            );
        }
        elsif ($action eq 'migrate') {
            # Perform actual migration
            my $selected_pages = $c->request->param('selected_pages') || [];
            $selected_pages = [$selected_pages] unless ref($selected_pages) eq 'ARRAY';
            
            my $migration_result = $self->_perform_page_migration($c, $selected_pages);
            $c->stash(
                migration_result => $migration_result,
                show_result => 1
            );
        }
    }
    
    $c->stash(
        template => 'admin/migrate_pages.tt'
    );
}

# Preview what pages would be migrated
sub _preview_page_migration {
    my ($self, $c) = @_;
    
    my @forager_pages = ();
    my @mapping_issues = ();
    my $total_count = 0;
    
    eval {
        # Get all pages from Forager schema
        @forager_pages = $c->model('DBForager')->resultset('Page')->search(
            {},
            {
                order_by => ['sitename', 'menu', 'link_order']
            }
        );
        
        $total_count = scalar(@forager_pages);
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_preview_page_migration', 
            "Found $total_count pages in Forager schema");
        
        # Check for potential mapping issues
        foreach my $page (@forager_pages) {
            my @issues = ();
            
            # Check if page_code already exists in Ency
            my $existing = $c->model('DBEncy')->resultset('Page')->find({ page_code => $page->page_code });
            if ($existing) {
                push @issues, "Page code '" . $page->page_code . "' already exists in destination";
            }
            
            # Check for required fields
            unless ($page->sitename) {
                push @issues, "Missing sitename";
            }
            unless ($page->menu) {
                push @issues, "Missing menu";
            }
            unless ($page->page_code) {
                push @issues, "Missing page_code";
            }
            
            if (@issues) {
                push @mapping_issues, {
                    page => $page,
                    issues => \@issues
                };
            }
        }
        
    };
    
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_preview_page_migration', 
            "Error during preview: $@");
        push @mapping_issues, { error => "Database error: $@" };
    }
    
    return {
        forager_pages => \@forager_pages,
        mapping_issues => \@mapping_issues,
        total_count => $total_count,
        issues_count => scalar(@mapping_issues)
    };
}

# Perform the actual page migration
sub _perform_page_migration {
    my ($self, $c, $selected_pages) = @_;
    
    my $migrated_count = 0;
    my $skipped_count = 0;
    my $error_count = 0;
    my @migration_log = ();
    my @errors = ();
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_perform_page_migration', 
        "Starting migration of " . scalar(@$selected_pages) . " selected pages");
    
    foreach my $page_id (@$selected_pages) {
        eval {
            # Get the Forager page
            my $forager_page = $c->model('DBForager')->resultset('Page')->find($page_id);
            unless ($forager_page) {
                push @errors, "Forager page with ID $page_id not found";
                $error_count++;
                next;
            }
            
            # Check if already exists in Ency
            my $existing = $c->model('DBEncy')->resultset('Page')->find({ page_code => $forager_page->page_code });
            if ($existing) {
                push @migration_log, "Skipped: Page code '" . $forager_page->page_code . "' already exists";
                $skipped_count++;
                next;
            }
            
            # Map the data from Forager to Ency schema
            my $ency_data = $self->_map_forager_to_ency_page($forager_page, $c);
            
            # Create the new page in Ency schema
            my $new_page = $c->model('DBEncy')->resultset('Page')->create($ency_data);
            
            push @migration_log, "Migrated: " . $forager_page->page_code . " -> ID " . $new_page->id;
            $migrated_count++;
            
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_perform_page_migration', 
                "Successfully migrated page: " . $forager_page->page_code);
        };
        
        if ($@) {
            my $error_msg = "Error migrating page ID $page_id: $@";
            push @errors, $error_msg;
            $error_count++;
            
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_perform_page_migration', 
                $error_msg);
        }
    }
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_perform_page_migration', 
        "Migration completed: $migrated_count migrated, $skipped_count skipped, $error_count errors");
    
    return {
        migrated_count => $migrated_count,
        skipped_count => $skipped_count,
        error_count => $error_count,
        migration_log => \@migration_log,
        errors => \@errors
    };
}

# Map Forager page data to Ency page schema
sub _map_forager_to_ency_page {
    my ($self, $forager_page, $c) = @_;
    
    # Map the fields from Forager to Ency schema
    my $ency_data = {
        sitename => $forager_page->sitename,
        menu => $forager_page->menu,
        page_code => $forager_page->page_code,
        title => $forager_page->app_title || $forager_page->page_code, # Use app_title or fallback to page_code
        body => $forager_page->body,
        description => $forager_page->description,
        keywords => $forager_page->keywords,
        link_order => $forager_page->link_order || 0,
        status => $forager_page->status || 'active',
        roles => 'public', # Default to public, can be customized
        created_by => $forager_page->username_of_poster || $forager_page->last_mod_by || 'migrated'
    };
    
    # Set timestamps if available
    if ($forager_page->last_mod_date) {
        $ency_data->{created_at} = $forager_page->last_mod_date;
        $ency_data->{updated_at} = $forager_page->last_mod_date;
    }
    
    return $ency_data;
}

# Schema Manager - View and manage database schemas
sub schema_manager :Chained('base') :PathPart('schema_manager') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'schema_manager', 
        "Starting schema manager");
    
    my $database = $c->request->param('database') || 'ENCY';
    
    my @tables = ();
    eval {
        if ($database eq 'ENCY') {
            my $schema = $c->model('DBEncy')->schema;
            @tables = $schema->storage->dbh->tables(undef, undef, '%', 'TABLE');
        } elsif ($database eq 'FORAGER') {
            my $schema = $c->model('DBForager')->schema;
            @tables = $schema->storage->dbh->tables(undef, undef, '%', 'TABLE');
        }
        
        # Clean up table names (remove schema prefixes if present)
        @tables = map { 
            my $table = $_;
            $table =~ s/^.*\.//;  # Remove schema prefix
            $table =~ s/^`(.*)`$/$1/;  # Remove backticks
            $table;
        } @tables;
        
        @tables = sort @tables;
    };
    
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'schema_manager', 
            "Error getting tables: $@");
        $c->stash(error_msg => "Error getting tables: $@");
    }
    
    $c->stash(
        database => $database,
        tables => \@tables,
        template => 'admin/SchemaManager.tt'
    );
}

# Compare schemas between databases
sub compare_schema :Chained('base') :PathPart('compare_schema') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'compare_schema', 
        "Starting schema comparison");
    
    my $comparison_result = {};
    
    eval {
        # Get tables from both schemas
        my $ency_schema = $c->model('DBEncy')->schema;
        my @ency_tables = $ency_schema->storage->dbh->tables(undef, undef, '%', 'TABLE');
        
        my $forager_schema = $c->model('DBForager')->schema;
        my @forager_tables = $forager_schema->storage->dbh->tables(undef, undef, '%', 'TABLE');
        
        # Clean up table names
        @ency_tables = map { 
            my $table = $_;
            $table =~ s/^.*\.//;
            $table =~ s/^`(.*)`$/$1/;
            $table;
        } sort @ency_tables;
        
        @forager_tables = map { 
            my $table = $_;
            $table =~ s/^.*\.//;
            $table =~ s/^`(.*)`$/$1/;
            $table;
        } sort @forager_tables;
        
        # Find differences
        my %ency_hash = map { $_ => 1 } @ency_tables;
        my %forager_hash = map { $_ => 1 } @forager_tables;
        
        my @only_in_ency = grep { !$forager_hash{$_} } @ency_tables;
        my @only_in_forager = grep { !$ency_hash{$_} } @forager_tables;
        my @common_tables = grep { $forager_hash{$_} } @ency_tables;
        
        $comparison_result = {
            ency_tables => \@ency_tables,
            forager_tables => \@forager_tables,
            only_in_ency => \@only_in_ency,
            only_in_forager => \@only_in_forager,
            common_tables => \@common_tables
        };
    };
    
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'compare_schema', 
            "Error comparing schemas: $@");
        $c->stash(error_msg => "Error comparing schemas: $@");
    }
    
    $c->stash(
        comparison => $comparison_result,
        template => 'admin/compare_schema.tt'
    );
}

# Migrate schema - placeholder for future implementation
sub migrate_schema :Chained('base') :PathPart('migrate_schema') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'migrate_schema', 
        "Starting schema migration");
    
    $c->stash(
        message => "Schema migration functionality is not yet implemented. Please use the specific migration tools like 'Migrate Pages' for now.",
        template => 'admin/migrate_schema.tt'
    );
}

# Admin users management
sub users :Chained('base') :PathPart('users') :Args(0) {
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
        $c->response->redirect($c->uri_for('/login', {
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
sub content :Chained('base') :PathPart('content') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'content', 
        "Starting content action");
    
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
        $c->response->redirect($c->uri_for('/login', {
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
        $c->response->redirect($c->uri_for('/login', {
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
        $c->response->redirect($c->uri_for('/login', {
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

        $c->response->redirect($c->uri_for('/login', {
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

# Database management functionality
sub database :Path('/admin/database') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'database', 
        "Starting database management action");
    
    # Check if the user has admin role
    unless ($c->user_exists && ($c->check_user_roles('admin') || $c->session->{username} eq 'Shanta')) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'database', 
            "Access denied: User does not have admin role");
        
        $c->flash->{error_msg} = "You need to be an administrator to access this area.";
        $c->response->redirect($c->uri_for('/user/login', {
            destination => $c->req->uri
        }));
        return;
    }
    
    # Handle POST requests for database operations
    if ($c->req->method eq 'POST') {
        my $action = $c->req->param('action');
        
        if ($action eq 'create_pages_table') {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'database', 
                "Creating pages_content table");
            
            eval {
                my $schema_manager = $c->model('DBSchemaManager');
                my $result = $schema_manager->create_pages_table($c);
                
                $c->flash->{success_msg} = "Pages table created successfully! " .
                    "Executed $result->{executed_count} of $result->{total_statements} statements.";
                
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'database', 
                    "Pages table created successfully");
            };
            if ($@) {
                my $error = $@;
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'database', 
                    "Error creating pages table: $error");
                $c->flash->{error_msg} = "Error creating pages table: $error";
            }
        }
        elsif ($action eq 'check_tables') {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'database', 
                "Checking database tables");
            
            eval {
                my $schema_manager = $c->model('DBSchemaManager');
                my $tables = $schema_manager->list_tables($c, 'ENCY');
                
                $c->stash(database_tables => $tables);
                $c->flash->{success_msg} = "Database tables checked successfully. Found " . 
                    scalar(@$tables) . " tables.";
            };
            if ($@) {
                my $error = $@;
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'database', 
                    "Error checking tables: $error");
                $c->flash->{error_msg} = "Error checking tables: $error";
            }
        }
        
        $c->response->redirect($c->uri_for('/admin/database'));
        return;
    }
    
    # Check table status
    my $table_status = {};
    eval {
        my $schema_manager = $c->model('DBSchemaManager');
        $table_status->{pages_content} = $schema_manager->table_exists($c, 'ENCY', 'pages_content');
        
        # Get list of all tables
        my $tables = $schema_manager->list_tables($c, 'ENCY');
        $c->stash(database_tables => $tables);
    };
    if ($@) {
        my $error = $@;
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'database', 
            "Warning checking table status: $error");
        $c->stash(database_error => $error);
    }
    
    # Use the standard debug message system
    if ($c->session->{debug_mode}) {
        push @{$c->stash->{debug_msg}}, "Admin controller database view - Template: admin/database.tt";
        push @{$c->stash->{debug_msg}}, "Table status: " . Dumper($table_status);
    }
    
    # Set the template and stash data
    $c->stash(
        template => 'admin/database.tt',
        table_status => $table_status
    );
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'database', 
        "Completed database management action");
}

=head1 AUTHOR

Shanta McBain

=head1 LICENSE

This library is free software. You can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

__PACKAGE__->meta->make_immutable;

1;