package Comserv::Controller::Navigation;
use Moose;
use namespace::autoclean;
use Data::Dumper;

BEGIN { extends 'Catalyst::Controller'; }

# Class-level cache for navigation data
has '_navigation_cache' => (
    is => 'rw',
    isa => 'HashRef',
    default => sub { {} }
);

has '_tables_checked' => (
    is => 'rw',
    isa => 'Bool',
    default => 0
);

has '_cache_timestamp' => (
    is => 'rw',
    isa => 'Int',
    default => 0
);

=head1 NAME

Comserv::Controller::Navigation - Catalyst Controller for navigation components

=head1 DESCRIPTION

This controller handles database queries for navigation components,
replacing the direct DBI usage in templates with proper model usage.

=cut

# Method to get internal links for a specific category and site
sub get_internal_links {
    my ($self, $c, $category, $site_name) = @_;
    
    $c->log->debug("Getting internal links for category: $category, site: $site_name");
    
    # Initialize results array
    my @results;
    
    # Use eval to catch any database errors
    eval {
        # Try to use the DBIx::Class API first
        my $rs = $c->model('DBEncy')->resultset('InternalLinksTb')->search({
            category => $category,
            sitename => [ $site_name, 'All' ]
        }, {
            order_by => { -asc => 'link_order' }
        });
        
        while (my $row = $rs->next) {
            push @results, { $row->get_columns };
        }
        
        # If no results and we might need to fall back to direct SQL
        if (!@results) {
            # Get the database handle from the DBEncy model
            my $dbh = $c->model('DBEncy')->schema->storage->dbh;
            
            # Prepare and execute the query
            my $query = "SELECT * FROM internal_links_tb WHERE category = ? AND (sitename = ? OR sitename = 'All') ORDER BY link_order";
            my $sth = $dbh->prepare($query);
            $sth->execute($category, $site_name);
            
            # Fetch all results
            while (my $row = $sth->fetchrow_hashref) {
                push @results, $row;
            }
        }
        
        $c->log->debug("Found " . scalar(@results) . " internal links");
    };
    if ($@) {
        $c->log->error("Error getting internal links: $@");
    }
    
    return \@results;
}

# Method to get pages for a specific menu and site
sub get_pages {
    my ($self, $c, $menu, $site_name, $status) = @_;
    
    $status //= 2; # Default status is 2 (active)
    
    $c->log->debug("Getting pages for menu: $menu, site: $site_name, status: $status");
    
    # Initialize results array
    my @results;
    
    # Use eval to catch any database errors
    eval {
        # Try to use the DBIx::Class API first
        my $rs = $c->model('DBEncy')->resultset('PageTb')->search({
            menu => $menu,
            status => $status,
            sitename => [ $site_name, 'All' ]
        }, {
            order_by => { -asc => 'link_order' }
        });
        
        while (my $row = $rs->next) {
            push @results, { $row->get_columns };
        }
        
        # If no results and we might need to fall back to direct SQL
        if (!@results) {
            # Get the database handle from the DBEncy model
            my $dbh = $c->model('DBEncy')->schema->storage->dbh;
            
            # Prepare and execute the query
            my $query = "SELECT * FROM page_tb WHERE menu = ? AND status = ? AND (sitename = ? OR sitename = 'All') ORDER BY link_order";
            my $sth = $dbh->prepare($query);
            $sth->execute($menu, $status, $site_name);
            
            # Fetch all results
            while (my $row = $sth->fetchrow_hashref) {
                push @results, $row;
            }
        }
        
        $c->log->debug("Found " . scalar(@results) . " pages");
    };
    if ($@) {
        $c->log->error("Error getting pages: $@");
    }
    
    return \@results;
}

# Method to get admin pages
sub get_admin_pages {
    my ($self, $c, $site_name) = @_;
    
    $c->log->debug("Getting admin pages for site: $site_name");
    
    # Initialize results array
    my @results;
    
    # Use eval to catch any database errors
    eval {
        # Try to use the DBIx::Class API first
        my $rs = $c->model('DBEncy')->resultset('PageTb')->search({
            menu => 'Admin',
            status => 2,
            sitename => [ $site_name, 'All' ]
        }, {
            order_by => { -asc => 'link_order' }
        });
        
        while (my $row = $rs->next) {
            push @results, { $row->get_columns };
        }
        
        # If no results and we might need to fall back to direct SQL
        if (!@results) {
            # Get the database handle from the DBEncy model
            my $dbh = $c->model('DBEncy')->schema->storage->dbh;
            
            # Prepare and execute the query
            my $query = "SELECT * FROM page_tb WHERE (menu = 'Admin' AND status = 2) AND (sitename = ? OR sitename = 'All') ORDER BY link_order";
            my $sth = $dbh->prepare($query);
            $sth->execute($site_name);
            
            # Fetch all results
            while (my $row = $sth->fetchrow_hashref) {
                push @results, $row;
            }
        }
        
        $c->log->debug("Found " . scalar(@results) . " admin pages");
    };
    if ($@) {
        $c->log->error("Error getting admin pages: $@");
    }
    
    return \@results;
}

# Method to get admin links
sub get_admin_links {
    my ($self, $c, $site_name) = @_;
    
    $c->log->debug("Getting admin links for site: $site_name");
    
    # Initialize results array
    my @results;
    
    # Use eval to catch any database errors
    eval {
        # Try to use the DBIx::Class API first
        my $rs = $c->model('DBEncy')->resultset('InternalLinksTb')->search({
            category => 'Admin_links',
            sitename => [ $site_name, 'All' ]
        }, {
            order_by => { -asc => 'link_order' }
        });
        
        while (my $row = $rs->next) {
            push @results, { $row->get_columns };
        }
        
        # If no results and we might need to fall back to direct SQL
        if (!@results) {
            # Get the database handle from the DBEncy model
            my $dbh = $c->model('DBEncy')->schema->storage->dbh;
            
            # Prepare and execute the query
            my $query = "SELECT * FROM internal_links_tb WHERE category = 'Admin_links' AND (sitename = ? OR sitename = 'All') ORDER BY link_order";
            my $sth = $dbh->prepare($query);
            $sth->execute($site_name);
            
            # Fetch all results
            while (my $row = $sth->fetchrow_hashref) {
                push @results, $row;
            }
        }
        
        $c->log->debug("Found " . scalar(@results) . " admin links");
    };
    if ($@) {
        $c->log->error("Error getting admin links: $@");
    }
    
    return \@results;
}

# Method to get private links for a specific user
sub get_private_links {
    my ($self, $c, $username, $site_name) = @_;
    
    $c->log->debug("Getting private links for user: $username, site: $site_name");
    
    # Initialize results array
    my @results;
    
    # Use eval to catch any database errors
    eval {
        # Try to use the DBIx::Class API first
        my $rs = $c->model('DBEncy')->resultset('InternalLinksTb')->search({
            category => 'Private_links',
            description => $username,  # Using description field to store username
            sitename => [ $site_name, 'All' ]
        }, {
            order_by => { -asc => 'link_order' }
        });
        
        while (my $row = $rs->next) {
            push @results, { $row->get_columns };
        }
        
        # If no results and we might need to fall back to direct SQL
        if (!@results) {
            # Get the database handle from the DBEncy model
            my $dbh = $c->model('DBEncy')->schema->storage->dbh;
            
            # Prepare and execute the query
            my $query = "SELECT * FROM internal_links_tb WHERE category = 'Private_links' AND description = ? AND (sitename = ? OR sitename = 'All') ORDER BY link_order";
            my $sth = $dbh->prepare($query);
            $sth->execute($username, $site_name);
            
            # Fetch all results
            while (my $row = $sth->fetchrow_hashref) {
                push @results, $row;
            }
        }
        
        $c->log->debug("Found " . scalar(@results) . " private links for user: $username");
    };
    if ($@) {
        $c->log->error("Error getting private links: $@");
    }
    
    return \@results;
}

# Unified method to add links (public or private based on permissions)
sub add_link :Path('/navigation/add_link') :Args(0) {
    my ($self, $c) = @_;
    
    # Check if user is logged in
    unless ($c->user_exists && $c->session->{username}) {
        $c->flash->{error_msg} = "You must be logged in to add links.";
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }
    
    my $username = $c->session->{username};
    my $user_roles = $c->session->{roles} || [];
    my $user_sitename = $c->session->{SiteName} || '';
    
    # Determine user permissions
    my $permissions = $self->get_user_link_permissions($c);
    
    if ($c->req->method eq 'POST') {
        my $name = $c->req->param('name');
        my $url = $c->req->param('url');
        my $target = $c->req->param('target') || '_self';
        my $category = $c->req->param('category');
        my $sitename = $c->req->param('sitename');
        my $link_type = $c->req->param('link_type') || 'private'; # private, public
        
        # Validate required fields
        unless ($name && $url && $category) {
            $c->flash->{error_msg} = "Name, URL, and category are required fields.";
            $c->stash->{permissions} = $permissions;
            $c->stash->{form_data} = $c->req->params;
            $c->stash->{template} = 'navigation/add_link.tt';
            return;
        }
        
        # Validate permissions
        unless ($self->validate_link_permissions($c, $link_type, $category, $sitename)) {
            $c->flash->{error_msg} = "You don't have permission to create this type of link.";
            $c->stash->{permissions} = $permissions;
            $c->stash->{form_data} = $c->req->params;
            $c->stash->{template} = 'navigation/add_link.tt';
            return;
        }
        
        # Get the next link order for this category/site
        my $max_order = $self->get_max_link_order($c, $category, $sitename, $username, $link_type);
        
        # Prepare link data
        my $link_data = {
            category => $category,
            sitename => $sitename,
            name => $name,
            url => $url,
            target => $target,
            link_order => $max_order + 1,
            status => 1
        };
        
        # For private links, store username in description
        if ($link_type eq 'private') {
            $link_data->{description} = $username;
        }
        
        # Add the link
        eval {
            $c->model('DBEncy')->resultset('InternalLinksTb')->create($link_data);
            $c->flash->{success_msg} = "Link '$name' added successfully.";
        };
        if ($@) {
            $c->log->error("Error adding link: $@");
            $c->flash->{error_msg} = "Error adding link. Please try again.";
        }
        
        $c->response->redirect($c->uri_for('/navigation/manage_links'));
        return;
    }
    
    # Pre-populate form based on URL parameters
    my $preset_category = $c->req->param('category') || '';
    my $preset_sitename = $c->req->param('sitename') || $user_sitename;
    
    $c->stash->{permissions} = $permissions;
    $c->stash->{preset_category} = $preset_category;
    $c->stash->{preset_sitename} = $preset_sitename;
    $c->stash->{template} = 'navigation/add_link.tt';
}

# Method to manage all user's links
sub manage_links :Path('/navigation/manage_links') :Args(0) {
    my ($self, $c) = @_;
    
    # Check if user is logged in
    unless ($c->user_exists && $c->session->{username}) {
        $c->flash->{error_msg} = "You must be logged in to manage links.";
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }
    
    my $username = $c->session->{username};
    my $permissions = $self->get_user_link_permissions($c);
    
    # Get user's links based on permissions
    my $user_links = $self->get_user_manageable_links($c, $username, $permissions);
    
    $c->stash->{user_links} = $user_links;
    $c->stash->{permissions} = $permissions;
    $c->stash->{template} = 'navigation/manage_links.tt';
}

# Method to edit a link
sub edit_link :Path('/navigation/edit_link') :Args(0) {
    my ($self, $c) = @_;
    
    # Check if user is logged in
    unless ($c->user_exists && $c->session->{username}) {
        $c->flash->{error_msg} = "You must be logged in to edit links.";
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }
    
    my $link_id = $c->req->param('id');
    my $username = $c->session->{username};
    
    unless ($link_id) {
        $c->flash->{error_msg} = "Link ID is required.";
        $c->response->redirect($c->uri_for('/navigation/manage_links'));
        return;
    }
    
    # Get the link and verify ownership
    my $link;
    eval {
        $link = $c->model('DBEncy')->resultset('InternalLinksTb')->find($link_id);
    };
    
    unless ($link) {
        $c->flash->{error_msg} = "Link not found.";
        $c->response->redirect($c->uri_for('/navigation/manage_links'));
        return;
    }
    
    # Verify the user owns this link (for private links only)
    if ($link->category eq 'Private_links' && $link->description ne $username) {
        $c->flash->{error_msg} = "You can only edit your own private links.";
        $c->response->redirect($c->uri_for('/navigation/manage_links'));
        return;
    }
    
    if ($c->req->method eq 'POST') {
        my $name = $c->req->param('name');
        my $url = $c->req->param('url');
        my $target = $c->req->param('target') || '_self';
        
        # Validate required fields
        unless ($name && $url) {
            $c->flash->{error_msg} = "Name and URL are required fields.";
            $c->stash->{link} = { $link->get_columns };
            $c->stash->{template} = 'navigation/edit_link.tt';
            return;
        }
        
        # Update the link
        eval {
            $link->update({
                name => $name,
                url => $url,
                target => $target,
            });
            
            $c->flash->{success_msg} = "Link '$name' updated successfully.";
        };
        if ($@) {
            $c->log->error("Error updating link: $@");
            $c->flash->{error_msg} = "Error updating link. Please try again.";
        }
        
        $c->response->redirect($c->uri_for('/navigation/manage_links'));
        return;
    }
    
    # Show the edit form
    $c->stash->{link} = { $link->get_columns };
    $c->stash->{template} = 'navigation/edit_link.tt';
}

# Method to delete a link
sub delete_link :Path('/navigation/delete_link') :Args(0) {
    my ($self, $c) = @_;
    
    # Check if user is logged in
    unless ($c->user_exists && $c->session->{username}) {
        $c->flash->{error_msg} = "You must be logged in to delete links.";
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }
    
    my $link_id = $c->req->param('id');
    my $username = $c->session->{username};
    
    unless ($link_id) {
        $c->flash->{error_msg} = "Link ID is required.";
        $c->response->redirect($c->uri_for('/navigation/manage_links'));
        return;
    }
    
    # Get the link and verify ownership
    my $link;
    eval {
        $link = $c->model('DBEncy')->resultset('InternalLinksTb')->find($link_id);
    };
    
    unless ($link) {
        $c->flash->{error_msg} = "Link not found.";
        $c->response->redirect($c->uri_for('/navigation/manage_links'));
        return;
    }
    
    # Verify the user owns this link (for private links only)
    if ($link->category eq 'Private_links' && $link->description ne $username) {
        $c->flash->{error_msg} = "You can only delete your own private links.";
        $c->response->redirect($c->uri_for('/navigation/manage_links'));
        return;
    }
    
    # Delete the link
    my $link_name = $link->name;
    eval {
        $link->delete();
        $c->flash->{success_msg} = "Link '$link_name' deleted successfully.";
    };
    if ($@) {
        $c->log->error("Error deleting link: $@");
        $c->flash->{error_msg} = "Error deleting link. Please try again.";
    }
    
    $c->response->redirect($c->uri_for('/navigation/manage_links'));
}

# Method to get user's link permissions based on roles
sub get_user_link_permissions {
    my ($self, $c) = @_;
    
    my $username = $c->session->{username} || '';
    my $roles = $c->session->{roles} || [];
    my $group = $c->session->{group} || '';
    my $sitename = $c->session->{SiteName} || '';
    
    # Convert roles to array if needed
    if (!ref($roles)) {
        $roles = [$roles];
    }
    
    my $permissions = {
        can_create_private => 1,  # All logged-in users can create private links
        can_create_public => 0,   # Only privileged users
        can_manage_all_sites => 0, # Only CSC SiteName admin
        available_categories => ['Private_links'],
        available_sites => [$sitename || 'All'],
        user_role => 'user'
    };
    
    # Check for admin privileges
    my $is_admin = 0;
    if (ref($roles) eq 'ARRAY') {
        $is_admin = grep { lc($_) eq 'admin' } @$roles;
    }
    
    # Also check legacy group field
    if (!$is_admin && $group && lc($group) eq 'admin') {
        $is_admin = 1;
    }
    
    if ($is_admin) {
        $permissions->{can_create_public} = 1;
        $permissions->{user_role} = 'admin';
        push @{$permissions->{available_categories}}, 
             'Main_links', 'Member_links', 'Admin_links', 'Hosted_link';
    }
    
    # Check for CSC SiteName admin (can manage all sites)
    if (grep { lc($_) eq 'csc' } @$roles) {
        $permissions->{can_manage_all_sites} = 1;
        $permissions->{user_role} = 'csc_admin';
        
        # Get all available sites
        my @all_sites = ('All');
        eval {
            # You might want to get this from a sites table or config
            push @all_sites, $sitename if $sitename;
        };
        $permissions->{available_sites} = \@all_sites;
    }
    
    return $permissions;
}

# Method to validate if user can create a specific type of link
sub validate_link_permissions {
    my ($self, $c, $link_type, $category, $sitename) = @_;
    
    my $permissions = $self->get_user_link_permissions($c);
    
    # Check link type permissions
    if ($link_type eq 'private' && !$permissions->{can_create_private}) {
        return 0;
    }
    
    if ($link_type eq 'public' && !$permissions->{can_create_public}) {
        return 0;
    }
    
    # Check category permissions
    unless (grep { $_ eq $category } @{$permissions->{available_categories}}) {
        return 0;
    }
    
    # Check site permissions
    unless (grep { $_ eq $sitename } @{$permissions->{available_sites}}) {
        return 0;
    }
    
    return 1;
}

# Method to get maximum link order for a category
sub get_max_link_order {
    my ($self, $c, $category, $sitename, $username, $link_type) = @_;
    
    my $search_criteria = {
        category => $category,
        sitename => $sitename
    };
    
    # For private links, filter by username
    if ($link_type eq 'private') {
        $search_criteria->{description} = $username;
    }
    
    my $max_order = 0;
    eval {
        my $rs = $c->model('DBEncy')->resultset('InternalLinksTb')->search(
            $search_criteria,
            {
                select => [{ max => 'link_order' }],
                as => ['max_order']
            }
        );
        
        my $row = $rs->first;
        $max_order = $row ? ($row->get_column('max_order') || 0) : 0;
    };
    
    return $max_order;
}

# Method to get all links that user can manage
sub get_user_manageable_links {
    my ($self, $c, $username, $permissions) = @_;
    
    my @all_links = ();
    
    # Get private links (user's own)
    if ($permissions->{can_create_private}) {
        my $private_links = $self->get_private_links($c, $username, $permissions->{available_sites}->[0]);
        for my $link (@$private_links) {
            $link->{link_type} = 'private';
            $link->{manageable} = 1;
        }
        push @all_links, @$private_links;
    }
    
    # Get public links if user has admin permissions
    if ($permissions->{can_create_public}) {
        for my $category (@{$permissions->{available_categories}}) {
            next if $category eq 'Private_links';
            
            for my $sitename (@{$permissions->{available_sites}}) {
                my $public_links = $self->get_internal_links($c, $category, $sitename);
                for my $link (@$public_links) {
                    $link->{link_type} = 'public';
                    $link->{manageable} = 1;
                    $link->{category_display} = $category;
                }
                push @all_links, @$public_links;
            }
        }
    }
    
    return \@all_links;
}

# Method to populate navigation data in the stash with caching
sub populate_navigation_data {
    my ($self, $c) = @_;
    
    # Use eval to catch any errors
    eval {
        my $site_name = $c->stash->{SiteName} || $c->session->{SiteName} || 'default';
        my $username = $c->session->{username} || '';
        
        # Create cache key based on site and user
        my $cache_key = "${site_name}_${username}";
        my $current_time = time();
        my $cache_ttl = 300; # 5 minutes cache
        
        # Check if we have valid cached data
        if ($self->_navigation_cache->{$cache_key} && 
            ($current_time - $self->_cache_timestamp) < $cache_ttl) {
            
            # Use cached data
            my $cached_data = $self->_navigation_cache->{$cache_key};
            $c->stash->{$_} = $cached_data->{$_} for keys %$cached_data;
            $c->log->debug("Using cached navigation data for site: $site_name");
            return;
        }
        
        $c->log->debug("Populating fresh navigation data for site: $site_name");
        
        # Set is_admin flag based on user roles
        my $is_admin = 0;
        if ($c->user_exists && $c->session->{roles}) {
            if (ref($c->session->{roles}) eq 'ARRAY') {
                $is_admin = grep { lc($_) eq 'admin' } @{$c->session->{roles}};
            } elsif (!ref($c->session->{roles})) {
                $is_admin = ($c->session->{roles} =~ /\badmin\b/i) ? 1 : 0;
            }
        }
        
        # Also check the legacy group field
        if (!$is_admin && $c->session->{group} && lc($c->session->{group}) eq 'admin') {
            $is_admin = 1;
        }
        
        # Set the is_admin flag in stash for use in templates
        $c->stash->{is_admin} = $is_admin;
        
        # Only check tables once per application lifecycle
        if (!$self->_tables_checked) {
            $self->_ensure_navigation_tables_exist($c);
            $self->_tables_checked(1);
        }
        
        # Prepare data structure for caching
        my $nav_data = {
            is_admin => $is_admin
        };
        
        # Populate member links
        $nav_data->{member_links} = $self->get_internal_links($c, 'Member_links', $site_name);
        $nav_data->{member_pages} = $self->get_pages($c, 'member', $site_name);
        
        # Populate main links
        $nav_data->{main_links} = $self->get_internal_links($c, 'Main_links', $site_name);
        $nav_data->{main_pages} = $self->get_pages($c, 'Main', $site_name);
        
        # Populate hosted links
        $nav_data->{hosted_links} = $self->get_internal_links($c, 'Hosted_link', $site_name);
        
        # Populate admin links and pages only for admin users
        if ($is_admin) {
            $nav_data->{admin_pages} = $self->get_admin_pages($c, $site_name);
            $nav_data->{admin_links} = $self->get_admin_links($c, $site_name);
        }
        
        # Populate private links for logged-in users
        if ($c->user_exists && $username) {
            $nav_data->{private_links} = $self->get_private_links($c, $username, $site_name);
        }
        
        # Cache the data
        $self->_navigation_cache->{$cache_key} = $nav_data;
        $self->_cache_timestamp($current_time);
        
        # Set stash data
        $c->stash->{$_} = $nav_data->{$_} for keys %$nav_data;
        
        $c->log->debug("Navigation data populated and cached successfully");
    };
    if ($@) {
        $c->log->error("Error populating navigation data: $@");
    }
}

# Separate method for table existence checking (called only once)
sub _ensure_navigation_tables_exist {
    my ($self, $c) = @_;
    
    eval {
        # Ensure tables exist before querying them
        my $db_model = $c->model('DBEncy');
        my $schema = $db_model->schema;
        
        # Check if tables exist in the database
        my $dbh = $schema->storage->dbh;
        my $tables = $db_model->list_tables();
        my $internal_links_exists = grep { $_ eq 'internal_links_tb' } @$tables;
        my $page_tb_exists = grep { $_ eq 'page_tb' } @$tables;
        
        # If tables don't exist, try to create them
        if (!$internal_links_exists || !$page_tb_exists) {
            $c->log->debug("Navigation tables don't exist. Attempting to create them.");
            
            # Create tables if they don't exist
            $db_model->create_table_from_result('InternalLinksTb', $schema, $c);
            $db_model->create_table_from_result('PageTb', $schema, $c);
            
            # Check if tables were created successfully
            $tables = $db_model->list_tables();
            $internal_links_exists = grep { $_ eq 'internal_links_tb' } @$tables;
            $page_tb_exists = grep { $_ eq 'page_tb' } @$tables;
            
            # If tables still don't exist, try to create them using SQL files
            if (!$internal_links_exists || !$page_tb_exists) {
                $c->log->debug("Creating tables from SQL files.");
                
                # Try to execute SQL files
                if (!$internal_links_exists) {
                    my $sql_file = $c->path_to('sql', 'internal_links_tb.sql')->stringify;
                    if (-e $sql_file) {
                        my $sql = do { local (@ARGV, $/) = $sql_file; <> };
                        my @statements = split /;/, $sql;
                        foreach my $statement (@statements) {
                            $statement =~ s/^\s+|\s+$//g;  # Trim whitespace
                            next unless $statement;  # Skip empty statements
                            eval { $dbh->do($statement); };
                            if ($@) {
                                $c->log->error("Error executing SQL: $@");
                            }
                        }
                    } else {
                        $c->log->error("SQL file not found: $sql_file");
                    }
                }
                
                if (!$page_tb_exists) {
                    my $sql_file = $c->path_to('sql', 'page_tb.sql')->stringify;
                    if (-e $sql_file) {
                        my $sql = do { local (@ARGV, $/) = $sql_file; <> };
                        my @statements = split /;/, $sql;
                        foreach my $statement (@statements) {
                            $statement =~ s/^\s+|\s+$//g;  # Trim whitespace
                            next unless $statement;  # Skip empty statements
                            eval { $dbh->do($statement); };
                            if ($@) {
                                $c->log->error("Error executing SQL: $@");
                            }
                        }
                    } else {
                        $c->log->error("SQL file not found: $sql_file");
                    }
                }
            }
        }
    };
    if ($@) {
        $c->log->error("Error ensuring navigation tables exist: $@");
    }
}

# Method to clear navigation cache (useful for admin operations)
sub clear_navigation_cache {
    my ($self, $c) = @_;
    $self->_navigation_cache({});
    $self->_cache_timestamp(0);
    $c->log->debug("Navigation cache cleared");
}

# Auto method to populate navigation data for all requests
sub auto :Private {
    my ($self, $c) = @_;
    
    # Use eval to catch any errors
    eval {
        $self->populate_navigation_data($c);
    };
    if ($@) {
        $c->log->error("Error in Navigation auto method: $@");
    }
    
    return 1; # Allow the request to proceed
}

__PACKAGE__->meta->make_immutable;

1;