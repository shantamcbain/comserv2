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

# Helper method to get user roles (returns array of all roles)
sub get_user_roles {
    my ($self, $c) = @_;
    
    return ['guest'] unless $c->user_exists;
    
    my @user_roles = ();
    
    # Get roles from session
    my $roles = $c->session->{roles};
    if (ref($roles) eq 'ARRAY') {
        @user_roles = @$roles;
    } elsif (defined $roles && !ref($roles)) {
        @user_roles = split(/[,\s]+/, $roles);
    }
    
    # Get user groups as additional roles
    my $user_groups = $c->session->{user_groups};
    if (ref($user_groups) eq 'ARRAY') {
        push @user_roles, @$user_groups;
    } elsif (defined $user_groups && !ref($user_groups)) {
        push @user_roles, split(/[,\s]+/, $user_groups);
    }
    
    # Clean up roles (lowercase, remove duplicates)
    my %seen;
    @user_roles = grep { !$seen{lc($_)}++ } map { lc($_) } @user_roles;
    
    # Ensure we have at least 'member' if user exists but no specific roles
    push @user_roles, 'member' unless @user_roles;
    
    return \@user_roles;
}

# Helper method to create cache key from multiple roles
sub create_cache_key {
    my ($self, $c) = @_;
    
    my $roles = $self->get_user_roles($c);
    my $site_name = $c->session->{SiteName} || 'All';
    my $username = $c->session->{username} || 'guest';
    
    # Sort roles for consistent cache key
    my $roles_str = join('_', sort @$roles);
    
    return "${roles_str}_${site_name}_${username}";
}

# Method to build complete navigation menu for user roles and store in session
sub build_navigation_cache {
    my ($self, $c) = @_;
    
    my $cache_key = $self->create_cache_key($c);
    
    # Check if we already have cached navigation for this session
    if ($c->session->{navigation_cache} && 
        $c->session->{navigation_cache_key} eq $cache_key &&
        $c->session->{navigation_cache_time} && 
        (time() - $c->session->{navigation_cache_time}) < 3600) { # 1 hour cache
        
        $c->log->debug("Using cached navigation for: $cache_key");
        return $c->session->{navigation_cache};
    }
    
    $c->log->debug("Building navigation cache for: $cache_key");
    
    my $user_roles = $self->get_user_roles($c);
    my $site_name = $c->session->{SiteName} || 'All';
    my $username = $c->session->{username} || 'guest';
    
    my $navigation = $self->build_role_based_navigation($c, $user_roles, $site_name, $username);
    
    # Store in session
    $c->session->{navigation_cache} = $navigation;
    $c->session->{navigation_cache_key} = $cache_key;
    $c->session->{navigation_cache_time} = time();
    
    return $navigation;
}

# Build navigation based on multiple user roles
sub build_role_based_navigation {
    my ($self, $c, $user_roles, $site_name, $username) = @_;
    
    my $page_url = $c->req->path || '';
    
    my $navigation = {
        # Always include main menu
        main_menu => $self->get_pages($c, 'Main', $site_name),
        top_menu => $self->get_internal_links($c, 'Top_menu', $site_name),
        footer_menu => $self->get_internal_links($c, 'Footer_menu', $site_name),
    };
    
    # Add custom menu items for main menu (gradual integration)
    my $custom_main_items = $self->get_custom_menu_items($c, 'main', $user_roles, $site_name, $page_url);
    if (@$custom_main_items) {
        $navigation->{custom_main_menu} = $self->build_custom_dropdown_structure($c, $custom_main_items);
    }
    
    # Add role-specific navigation
    foreach my $role (@$user_roles) {
        if ($role eq 'admin') {
            $navigation->{admin_menu} = $self->get_admin_pages($c, $site_name);
            $navigation->{admin_links} = $self->get_admin_links($c, $site_name);
            
            # Add custom admin menu items
            my $custom_admin_items = $self->get_custom_menu_items($c, 'admin', $user_roles, $site_name, $page_url);
            if (@$custom_admin_items) {
                $navigation->{custom_admin_menu} = $self->build_custom_dropdown_structure($c, $custom_admin_items);
            }
        }
        
        # Add other role-specific menus as needed
        if ($role eq 'manager') {
            $navigation->{manager_menu} = $self->get_internal_links($c, 'Manager_menu', $site_name);
            
            # Add custom manager menu items
            my $custom_manager_items = $self->get_custom_menu_items($c, 'manager', $user_roles, $site_name, $page_url);
            if (@$custom_manager_items) {
                $navigation->{custom_manager_menu} = $self->build_custom_dropdown_structure($c, $custom_manager_items);
            }
        }
        
        if ($role eq 'editor') {
            $navigation->{editor_menu} = $self->get_internal_links($c, 'Editor_menu', $site_name);
            
            # Add custom editor menu items
            my $custom_editor_items = $self->get_custom_menu_items($c, 'editor', $user_roles, $site_name, $page_url);
            if (@$custom_editor_items) {
                $navigation->{custom_editor_menu} = $self->build_custom_dropdown_structure($c, $custom_editor_items);
            }
        }
        
        # Add more roles as your system requires
    }
    
    # Add private links for logged-in users (not guests)
    if ($username ne 'guest') {
        $navigation->{private_links} = $self->get_private_links($c, $username, $site_name);
    }
    
    # Add menu visibility information
    $navigation->{menu_visibility} = {
        main => $self->is_menu_visible($c, 'main', $user_roles, $site_name, $page_url),
        admin => $self->is_menu_visible($c, 'admin', $user_roles, $site_name, $page_url),
        manager => $self->is_menu_visible($c, 'manager', $user_roles, $site_name, $page_url),
        editor => $self->is_menu_visible($c, 'editor', $user_roles, $site_name, $page_url),
        member => $self->is_menu_visible($c, 'member', $user_roles, $site_name, $page_url),
        global => $self->is_menu_visible($c, 'global', $user_roles, $site_name, $page_url),
        hosted => $self->is_menu_visible($c, 'hosted', $user_roles, $site_name, $page_url),
    };
    
    return $navigation;
}

# Method to invalidate navigation cache (call when navigation changes)
sub invalidate_navigation_cache {
    my ($self, $c) = @_;
    
    delete $c->session->{navigation_cache};
    delete $c->session->{navigation_cache_key};
    delete $c->session->{navigation_cache_time};
    
    $c->log->debug("Navigation cache invalidated");
}

# Convenient method to get cached navigation
sub get_navigation {
    my ($self, $c) = @_;
    
    return $self->build_navigation_cache($c);
}

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

# Method to add a private link
sub add_private_link :Path('/navigation/add_private_link') :Args(0) {
    my ($self, $c) = @_;
    
    # Check if user is logged in
    unless ($c->user_exists && $c->session->{username}) {
        $c->flash->{error_msg} = "You must be logged in to add private links.";
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }
    
    if ($c->req->method eq 'POST') {
        my $name = $c->req->param('name');
        my $url = $c->req->param('url');
        my $target = $c->req->param('target') || '_self';
        my $site_name = $c->session->{SiteName} || 'All';
        my $username = $c->session->{username};
        
        # Validate required fields
        unless ($name && $url) {
            $c->flash->{error_msg} = "Name and URL are required fields.";
            $c->stash->{template} = 'Navigation/add_private_link.tt';
            return;
        }
        
        # Get the next link order
        my $max_order = 0;
        eval {
            my $rs = $c->model('DBEncy')->resultset('InternalLinksTb')->search({
                category => 'Private_links',
                description => $username,
                sitename => $site_name
            }, {
                select => [{ max => 'link_order' }],
                as => ['max_order']
            });
            
            my $row = $rs->first;
            $max_order = $row ? ($row->get_column('max_order') || 0) : 0;
        };
        
        # Add the private link
        eval {
            $c->model('DBEncy')->resultset('InternalLinksTb')->create({
                category => 'Private_links',
                sitename => $site_name,
                name => $name,
                url => $url,
                target => $target,
                description => $username,  # Store username in description field
                link_order => $max_order + 1,
                status => 1
            });
            
            $c->flash->{success_msg} = "Private link '$name' added successfully.";
        };
        if ($@) {
            $c->log->error("Error adding private link: $@");
            $c->flash->{error_msg} = "Error adding private link. Please try again.";
        }
        
        $c->response->redirect($c->uri_for('/navigation/manage_private_links'));
        return;
    }
    
    # Show the add form
    $c->stash->{template} = 'Navigation/add_private_link.tt';
}

# Method to manage private links
sub manage_private_links :Path('/navigation/manage_private_links') :Args(0) {
    my ($self, $c) = @_;
    
    # Check if user is logged in
    unless ($c->user_exists && $c->session->{username}) {
        $c->flash->{error_msg} = "You must be logged in to manage private links.";
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }
    
    my $username = $c->session->{username};
    my $site_name = $c->session->{SiteName} || 'All';
    
    # Get user's private links
    $c->stash->{private_links} = $self->get_private_links($c, $username, $site_name);
    $c->stash->{template} = 'Navigation/manage_private_links.tt';
}

# Method to edit a private link
sub edit_private_link :Path('/navigation/edit_private_link') :Args(1) {
    my ($self, $c, $link_id) = @_;
    
    # Check if user is logged in
    unless ($c->user_exists && $c->session->{username}) {
        $c->flash->{error_msg} = "You must be logged in to edit private links.";
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }
    
    my $username = $c->session->{username};
    
    # Get the link to edit
    my $link;
    eval {
        $link = $c->model('DBEncy')->resultset('InternalLinksTb')->find({
            id => $link_id,
            category => 'Private_links',
            description => $username
        });
    };
    
    unless ($link) {
        $c->flash->{error_msg} = "Link not found or you don't have permission to edit it.";
        $c->response->redirect($c->uri_for('/navigation/manage_private_links'));
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
            $c->stash->{template} = 'Navigation/edit_private_link.tt';
            return;
        }
        
        # Update the private link
        eval {
            $link->update({
                name => $name,
                url => $url,
                target => $target
            });
            
            $c->flash->{success_msg} = "Private link '$name' updated successfully.";
        };
        if ($@) {
            $c->log->error("Error updating private link: $@");
            $c->flash->{error_msg} = "Error updating private link. Please try again.";
        }
        
        $c->response->redirect($c->uri_for('/navigation/manage_private_links'));
        return;
    }
    
    # Show the edit form
    $c->stash->{link} = { $link->get_columns };
    $c->stash->{template} = 'Navigation/edit_private_link.tt';
}

# Method to delete a private link
sub delete_private_link :Path('/navigation/delete_private_link') :Args(1) {
    my ($self, $c, $link_id) = @_;
    
    # Check if user is logged in
    unless ($c->user_exists && $c->session->{username}) {
        $c->flash->{error_msg} = "You must be logged in to delete private links.";
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }
    
    my $username = $c->session->{username};
    
    # Verify the link belongs to the current user
    eval {
        my $link = $c->model('DBEncy')->resultset('InternalLinksTb')->find({
            id => $link_id,
            category => 'Private_links',
            description => $username
        });
        
        if ($link) {
            $link->delete;
            $c->flash->{success_msg} = "Private link deleted successfully.";
        } else {
            $c->flash->{error_msg} = "Link not found or you don't have permission to delete it.";
        }
    };
    if ($@) {
        $c->log->error("Error deleting private link: $@");
        $c->flash->{error_msg} = "Error deleting private link. Please try again.";
    }
    
    $c->response->redirect($c->uri_for('/navigation/manage_private_links'));
}

# Admin method to add links to any menu
sub add_link :Path('/navigation/add_link') :Args(0) {
    my ($self, $c) = @_;
    
    # Check if user is admin
    unless ($c->user_exists && $c->check_user_roles('admin')) {
        $c->flash->{error_msg} = "You must be an administrator to add menu links.";
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }
    
    my $menu_type = $c->req->param('menu') || 'admin';
    
    if ($c->req->method eq 'POST') {
        my $category = $c->req->param('category');
        my $name = $c->req->param('name');
        my $url = $c->req->param('url');
        my $target = $c->req->param('target') || '_self';
        my $site_name = $c->req->param('sitename') || $c->session->{SiteName} || 'All';
        my $view_name = $c->req->param('view_name') || $name;
        my $page_code = $c->req->param('page_code') || '';
        
        # Validate required fields
        unless ($category && $name && $url) {
            $c->flash->{error_msg} = "Category, Name and URL are required fields.";
            $c->stash->{menu_type} = $menu_type;
            $c->stash->{template} = 'Navigation/add_link.tt';
            return;
        }
        
        # SECURITY: Site-specific permissions validation
        my $current_site = $c->session->{SiteName} || '';
        if ($current_site ne 'SiteName' && $current_site ne 'CSC') {
            # Non-privileged sites can only modify their own site
            if ($site_name ne $current_site && $site_name ne 'All') {
                $c->flash->{error_msg} = "You can only add links for your current site ($current_site).";
                $c->stash->{menu_type} = $menu_type;
                $c->stash->{template} = 'Navigation/add_link.tt';
                return;
            }
            # Force site_name to current site for non-privileged sites
            $site_name = $current_site;
        }
        # SiteName and CSC sites can modify any site (no restrictions)
        
        # Get the next link order
        my $max_order = 0;
        eval {
            my $rs = $c->model('DBEncy')->resultset('InternalLinksTb')->search({
                category => $category,
                sitename => $site_name
            }, {
                select => [{ max => 'link_order' }],
                as => ['max_order']
            });
            
            my $row = $rs->first;
            $max_order = $row ? ($row->get_column('max_order') || 0) : 0;
        };
        
        # Add the link
        eval {
            $c->model('DBEncy')->resultset('InternalLinksTb')->create({
                category => $category,
                sitename => $site_name,
                name => $name,
                url => $url,
                target => $target,
                view_name => $view_name,
                page_code => $page_code,
                link_order => $max_order + 1,
                status => 1
            });
            
            $c->flash->{success_msg} = "Link '$name' added successfully to $category.";
        };
        if ($@) {
            $c->log->error("Error adding link: $@");
            $c->flash->{error_msg} = "Error adding link. Please try again.";
        }
        
        $c->response->redirect($c->uri_for('/navigation/manage_links'));
        return;
    }
    
    # Show the add form
    $c->stash->{menu_type} = $menu_type;
    $c->stash->{template} = 'Navigation/add_link.tt';
}

# Admin method to manage all menu links
sub manage_links :Path('/navigation/manage_links') :Args(0) {
    my ($self, $c) = @_;
    
    # Check if user is admin
    unless ($c->user_exists && $c->check_user_roles('admin')) {
        $c->flash->{error_msg} = "You must be an administrator to manage menu links.";
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }
    
    my $site_name = $c->session->{SiteName} || 'All';
    
    # Get all link categories with site-specific permissions
    my %links_by_category = ();
    eval {
        my $search_criteria;
        
        if ($site_name eq 'SiteName' || $site_name eq 'CSC') {
            # SiteName and CSC sites can see all links from all sites
            $search_criteria = {};
        } else {
            # Other sites can only see their own links and 'All' links
            $search_criteria = {
                sitename => [ $site_name, 'All' ]
            };
        }
        
        my $rs = $c->model('DBEncy')->resultset('InternalLinksTb')->search($search_criteria, {
            order_by => ['category', 'link_order']
        });
        
        while (my $row = $rs->next) {
            my $data = { $row->get_columns };
            push @{$links_by_category{$data->{category}}}, $data;
        }
    };
    if ($@) {
        $c->log->error("Error getting links: $@");
        $c->flash->{error_msg} = "Error retrieving links.";
    }
    
    $c->stash->{links_by_category} = \%links_by_category;
    $c->stash->{template} = 'Navigation/manage_links.tt';
}

# Admin method to delete any menu link
sub delete_link :Path('/navigation/delete_link') :Args(1) {
    my ($self, $c, $link_id) = @_;
    
    # Check if user is admin
    unless ($c->user_exists && $c->check_user_roles('admin')) {
        $c->flash->{error_msg} = "You must be an administrator to delete menu links.";
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }
    
    # Delete the link
    eval {
        my $link = $c->model('DBEncy')->resultset('InternalLinksTb')->find($link_id);
        
        if ($link) {
            # SECURITY: Check if user can delete this link based on site permissions
            my $current_site = $c->session->{SiteName} || '';
            my $link_site = $link->sitename || '';
            
            if ($current_site ne 'SiteName' && $current_site ne 'CSC') {
                # Non-privileged sites can only delete their own site's links
                if ($link_site ne $current_site && $link_site ne 'All') {
                    $c->flash->{error_msg} = "You can only delete links for your current site ($current_site).";
                    $c->response->redirect($c->uri_for('/navigation/manage_links'));
                    return;
                }
            }
            # SiteName and CSC sites can delete any link (no restrictions)
            
            my $name = $link->name;
            my $category = $link->category;
            $link->delete;
            $c->flash->{success_msg} = "Link '$name' deleted from $category successfully.";
        } else {
            $c->flash->{error_msg} = "Link not found.";
        }
    };
    if ($@) {
        $c->log->error("Error deleting link: $@");
        $c->flash->{error_msg} = "Error deleting link. Please try again.";
    }
    
    $c->response->redirect($c->uri_for('/navigation/manage_links'));
}

# Admin method to edit any menu link
sub edit_link :Path('/navigation/edit_link') :Args(1) {
    my ($self, $c, $link_id) = @_;
    
    # Check if user is admin
    unless ($c->user_exists && $c->check_user_roles('admin')) {
        $c->flash->{error_msg} = "You must be an administrator to edit menu links.";
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }
    
    # Get the link
    my $link;
    eval {
        $link = $c->model('DBEncy')->resultset('InternalLinksTb')->find($link_id);
    };
    
    unless ($link) {
        $c->flash->{error_msg} = "Link not found.";
        $c->response->redirect($c->uri_for('/navigation/manage_links'));
        return;
    }
    
    # SECURITY: Check if user can edit this link based on site permissions
    my $current_site = $c->session->{SiteName} || '';
    my $link_site = $link->sitename || '';
    
    if ($current_site ne 'SiteName' && $current_site ne 'CSC') {
        # Non-privileged sites can only edit their own site's links
        if ($link_site ne $current_site && $link_site ne 'All') {
            $c->flash->{error_msg} = "You can only edit links for your current site ($current_site).";
            $c->response->redirect($c->uri_for('/navigation/manage_links'));
            return;
        }
    }
    # SiteName and CSC sites can edit any link (no restrictions)
    
    if ($c->req->method eq 'POST') {
        my $category = $c->req->param('category');
        my $name = $c->req->param('name');
        my $url = $c->req->param('url');
        my $target = $c->req->param('target') || '_self';
        my $site_name = $c->req->param('sitename') || 'All';
        my $view_name = $c->req->param('view_name') || $name;
        my $page_code = $c->req->param('page_code') || '';
        
        # Validate required fields
        unless ($category && $name && $url) {
            $c->flash->{error_msg} = "Category, Name and URL are required fields.";
            $c->stash->{link} = { $link->get_columns };
            $c->stash->{template} = 'Navigation/edit_link.tt';
            return;
        }
        
        # SECURITY: Site-specific permissions validation for updates
        if ($current_site ne 'SiteName' && $current_site ne 'CSC') {
            # Non-privileged sites can only modify their own site
            if ($site_name ne $current_site && $site_name ne 'All') {
                $c->flash->{error_msg} = "You can only update links for your current site ($current_site).";
                $c->stash->{link} = { $link->get_columns };
                $c->stash->{template} = 'Navigation/edit_link.tt';
                return;
            }
            # Force site_name to current site for non-privileged sites
            $site_name = $current_site;
        }
        # SiteName and CSC sites can modify any site (no restrictions)
        
        # Update the link
        eval {
            $link->update({
                category => $category,
                sitename => $site_name,
                name => $name,
                url => $url,
                target => $target,
                view_name => $view_name,
                page_code => $page_code
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
    $c->stash->{template} = 'Navigation/edit_link.tt';
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

# Method to check if a menu should be visible based on menu_visibility table
sub is_menu_visible {
    my ($self, $c, $menu_name, $user_roles, $site_name, $page_url) = @_;
    
    $c->log->debug("Checking menu visibility for: $menu_name, site: $site_name");
    
    # Default to visible if no rules found
    my $is_visible = 1;
    
    eval {
        # Get visibility rules for this menu, ordered by priority (lower = higher priority)
        my $rs = $c->model('DBEncy')->resultset('MenuVisibility')->search({
            menu_name => $menu_name,
            site_name => [ $site_name, 'All' ]
        }, {
            order_by => { -asc => 'priority' }
        });
        
        while (my $rule = $rs->next) {
            # Check if this rule applies to current context
            my $rule_applies = 1;
            
            # Check role match
            if (defined $rule->role_name && $rule->role_name ne '') {
                my $role_matches = 0;
                foreach my $user_role (@$user_roles) {
                    if (lc($user_role) eq lc($rule->role_name)) {
                        $role_matches = 1;
                        last;
                    }
                }
                $rule_applies = 0 unless $role_matches;
            }
            
            # Check page pattern match
            if (defined $rule->page_pattern && $rule->page_pattern ne '' && defined $page_url) {
                my $pattern = $rule->page_pattern;
                # Simple pattern matching - can be enhanced later
                if ($pattern =~ /\*/) {
                    # Wildcard pattern
                    $pattern =~ s/\*/.*?/g;
                    $rule_applies = 0 unless $page_url =~ /$pattern/i;
                } else {
                    # Exact match
                    $rule_applies = 0 unless lc($page_url) eq lc($pattern);
                }
            }
            
            # Apply the rule if it matches
            if ($rule_applies) {
                $is_visible = $rule->is_visible;
                $c->log->debug("Menu visibility rule applied: $menu_name = " . ($is_visible ? 'visible' : 'hidden'));
                last; # First matching rule wins (due to priority ordering)
            }
        }
    };
    if ($@) {
        $c->log->error("Error checking menu visibility: $@");
        # Default to visible on error
        $is_visible = 1;
    }
    
    return $is_visible;
}

# Method to get custom menu items for a specific parent menu
sub get_custom_menu_items {
    my ($self, $c, $parent_menu, $user_roles, $site_name, $page_url) = @_;
    
    $c->log->debug("Getting custom menu items for parent: $parent_menu, site: $site_name");
    
    my @results;
    
    eval {
        # Get active custom menu items for this parent menu
        my $rs = $c->model('DBEncy')->resultset('CustomMenu')->search({
            parent_menu => $parent_menu,
            site_name => [ $site_name, 'All' ],
            is_active => 1
        }, {
            order_by => { -asc => 'sort_order' }
        });
        
        while (my $item = $rs->next) {
            # Check role requirements
            my $role_ok = 1;
            if (defined $item->required_role && $item->required_role ne '') {
                $role_ok = 0;
                foreach my $user_role (@$user_roles) {
                    if (lc($user_role) eq lc($item->required_role)) {
                        $role_ok = 1;
                        last;
                    }
                }
            }
            
            # Check page pattern
            my $page_ok = 1;
            if (defined $item->page_pattern && $item->page_pattern ne '' && defined $page_url) {
                my $pattern = $item->page_pattern;
                if ($pattern =~ /\*/) {
                    # Wildcard pattern
                    $pattern =~ s/\*/.*?/g;
                    $page_ok = ($page_url =~ /$pattern/i) ? 1 : 0;
                } else {
                    # Exact match
                    $page_ok = (lc($page_url) eq lc($pattern)) ? 1 : 0;
                }
            }
            
            # Add item if it passes all checks
            if ($role_ok && $page_ok) {
                push @results, {
                    id => $item->id,
                    title => $item->title,
                    url => $item->url,
                    icon_class => $item->icon_class || 'icon-link',
                    target => $item->target || '_self',
                    is_dropdown => $item->is_dropdown,
                    dropdown_parent_id => $item->dropdown_parent_id,
                    menu_group => $item->menu_group,
                    sort_order => $item->sort_order,
                    description => $item->description
                };
            }
        }
        
        $c->log->debug("Found " . scalar(@results) . " custom menu items for parent: $parent_menu");
    };
    if ($@) {
        $c->log->error("Error getting custom menu items: $@");
    }
    
    return \@results;
}

# Method to build dropdown structure from flat custom menu items
sub build_custom_dropdown_structure {
    my ($self, $c, $menu_items) = @_;
    
    my @top_level = ();
    my %children_by_parent = ();
    
    # Separate top-level items from dropdown children
    foreach my $item (@$menu_items) {
        if ($item->{dropdown_parent_id}) {
            push @{$children_by_parent{$item->{dropdown_parent_id}}}, $item;
        } else {
            push @top_level, $item;
        }
    }
    
    # Attach children to their parents
    foreach my $parent (@top_level) {
        if ($parent->{is_dropdown} && $children_by_parent{$parent->{id}}) {
            $parent->{children} = $children_by_parent{$parent->{id}};
        }
    }
    
    return \@top_level;
}

__PACKAGE__->meta->make_immutable;

1;