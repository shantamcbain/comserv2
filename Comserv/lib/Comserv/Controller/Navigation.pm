package Comserv::Controller::Navigation;
use Moose;
use namespace::autoclean;
use Data::Dumper;

BEGIN { extends 'Catalyst::Controller'; }

use URI::Escape qw(uri_escape);

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

# Helper: current sitename convenience
sub _current_site {
    my ($self, $c) = @_;
    return $c->stash->{SiteName} || $c->session->{SiteName} || 'All';
}

# Method to get internal links for a specific category and site
sub get_internal_links {
    my ($self, $c, $category, $site_name) = @_;
    
    $c->log->debug("Getting internal links for category: $category, site: $site_name");
    
    # Initialize results array
    my @results;
    
    # Use eval to catch any database errors
    eval {
        # Determine username (for owner-private logic)
        my $username = $c->session->{username} || '';
        my $root_controller = $c->controller('Root');
        my $is_logged_in = $root_controller->user_exists($c) && $username ? 1 : 0;

        # Show:
        # - public links in category for site/all
        # - PLUS private links owned by this user (category anywhere they added it)
        my %where = (
            category => $category,
            sitename => [ $site_name, 'All' ],
        );

        # Try to use the DBIx::Class API first
        my $rs = $c->model('DBEncy')->resultset('InternalLinksTb')->search({
            %where
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
            my $query = qq{
                SELECT *
                FROM internal_links_tb
                WHERE category = ?
                  AND (sitename = ? OR sitename = 'All')
                ORDER BY link_order
            };
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
        # Private links are stored with description=username (Phase 1 approach)
        # Aggregate across categories but respect site scope (current site + All)
        my $rs = $c->model('DBEncy')->resultset('InternalLinksTb')->search(
            {
                description => $username,
                sitename    => [ $site_name, 'All' ],
            },
            {
                order_by => [
                    { -asc => 'category' },
                    { -asc => 'link_order' },
                    { -asc => 'name' },
                ],
            }
        );
        
        while (my $row = $rs->next) {
            push @results, { $row->get_columns };
        }
        
        # If no results and we might need to fall back to direct SQL
        if (!@results) {
            # Get the database handle from the DBEncy model
            my $dbh = $c->model('DBEncy')->schema->storage->dbh;
            
            # Prepare and execute the query
            my $query = qq{
                SELECT *
                FROM internal_links_tb
                WHERE description = ?
                  AND (sitename = ? OR sitename = 'All')
                ORDER BY category ASC, link_order ASC, name ASC
            };
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
    my $root_controller = $c->controller('Root');
    unless ($root_controller->user_exists($c) && $c->session->{username}) {
        $c->flash->{error_msg} = "You must be logged in to add links.";
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }
    
    my $username = $c->session->{username};
    my $user_roles = $c->session->{roles} || [];
    my $user_sitename = $c->session->{SiteName} || '';
    
    # Determine user permissions
    my $permissions = $self->get_user_link_permissions($c);
    my $return_url  = $c->req->param('return_url') || $c->req->referer || $c->uri_for('/')->as_string;
    # ensure we always have a safe relative fallback
    $return_url = $c->uri_for('/')->as_string unless $return_url;
    
    if ($c->req->method eq 'POST') {
        my $name = $c->req->param('name');
        my $url = $c->req->param('url');
        my $target = $c->req->param('target') || '_self';
        my $category = $c->req->param('category');
        my $sitename = $c->req->param('sitename');
        my $link_type = $c->req->param('link_type') || 'private'; # private, public
        my $cross_site = $c->req->param('cross_site') ? 1 : 0;    # show on all sites
        my $effective_site = $cross_site ? 'All' : ($sitename || $user_sitename || $self->_current_site($c));
        
        # Validate required fields
        unless ($name && $url && $category) {
            $c->flash->{error_msg} = "Name, URL, and category are required fields.";
            $c->stash->{permissions} = $permissions;
            $c->stash->{form_data} = $c->req->params;
            $c->stash->{template} = 'Navigation/add_link.tt';
            return;
        }
        
        # Validate permissions
        unless ($self->validate_link_permissions($c, $link_type, $category, $effective_site)) {
            $c->flash->{error_msg} = "You don't have permission to create this type of link.";
            $c->stash->{permissions} = $permissions;
            $c->stash->{form_data} = $c->req->params;
            $c->stash->{template} = 'Navigation/add_link.tt';
            return;
        }
        
        # Get the next link order for this category/site
        my $max_order = $self->get_max_link_order($c, $category, $effective_site, $username, $link_type);
        
        # Prepare link data
        my $link_data = {
            category => $category,
            sitename => $effective_site,
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
            # Clear cached nav so the new link appears immediately
            $self->clear_navigation_cache($c);
        };
        if ($@) {
            $c->log->error("Error adding link: $@");
            $c->flash->{error_msg} = "Error adding link. Please try again.";
        }
        
        # Redirect to where user clicked "+ Add Link"
        $c->response->redirect($return_url);
        return;
    }
    
    # Pre-populate form based on URL parameters
    my $preset_category = $c->req->param('category') || '';
    my $preset_sitename = $c->req->param('sitename') || $user_sitename;
    my $preset_return   = $return_url;
    my $preset_linktype = 'private';
    
    $c->stash->{permissions} = $permissions;
    $c->stash->{preset_category} = $preset_category;
    $c->stash->{preset_sitename} = $preset_sitename;
    $c->stash->{preset_return_url} = $preset_return;
    $c->stash->{preset_link_type} = $preset_linktype;
    $c->stash->{template} = 'Navigation/add_link.tt';
}

# Method to manage all user's links
sub manage_links :Path('/navigation/manage_links') :Args(0) {
    my ($self, $c) = @_;
    
    # Check if user is logged in
    my $root_controller = $c->controller('Root');
    unless ($root_controller->user_exists($c) && $c->session->{username}) {
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
    $c->stash->{template_title} = 'Manage Links';
    $c->stash->{template} = 'Navigation/manage_links.tt';
}

# Method to edit a link
sub edit_link :Path('/navigation/edit_link') :Args(0) {
    my ($self, $c) = @_;
    
    # Check if user is logged in
    my $root_controller = $c->controller('Root');
    unless ($root_controller->user_exists($c) && $c->session->{username}) {
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
            $c->stash->{template} = 'Navigation/edit_link.tt';
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
    $c->stash->{template} = 'Navigation/edit_link.tt';
}

# Method to delete a link
sub delete_link :Path('/navigation/delete_link') :Args(0) {
    my ($self, $c) = @_;
    
    # Check if user is logged in
    my $root_controller = $c->controller('Root');
    unless ($root_controller->user_exists($c) && $c->session->{username}) {
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
        can_create_private  => 1,  # All logged-in users can create private links
        can_create_public   => 0,  # Only admins (developer scaffolding reserved)
        can_manage_all_sites => 0,
        # Users can add private links into any category they can see. Keep a sane default list.
        available_categories => ['Main_links','Member_links','Admin_links','Hosted_link','Private_links'],
        # Sites: current site + All for cross-site private (allowed)
        available_sites => [$sitename || 'All', 'All'],
        user_role => 'normal'
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
        $permissions->{user_role}         = 'admin';
        # admin already has the full list above
    }
    
    # Developer scaffolding (future role) - keep structure ready
    if (grep { lc($_) eq 'developer' } @$roles) {
        # For now, developer behaves like normal. When enabled later, adjust here.
        $permissions->{user_role} = $is_admin ? 'admin' : 'normal';
    }
    
    # Cross-site handling: normal users can set private links to All; admins can do both types cross-site.
    # available_sites already includes current and 'All'
    
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
    
    # Check category permissions (private links can be added to any known category in available list)
    unless (grep { $_ eq $category } @{$permissions->{available_categories}}) {
        return 0;
    }
    
    # Check site permissions (allow current site and 'All')
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
        my $max_cache_age = 3600; # 1 hour max for the whole cache structure
        
        # Periodically clear the entire cache to prevent indefinite growth
        if (($current_time - $self->_cache_timestamp) > $max_cache_age) {
            $c->log->debug("Navigation cache exceeded max age, clearing all entries");
            $self->_navigation_cache({});
        }
        
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
        my $root_controller = $c->controller('Root');
        if ($root_controller->user_exists($c) && $c->session->{roles}) {
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
        if ($root_controller->user_exists($c) && $username) {
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
        my $navigation_exists = grep { $_ eq 'navigation' } @$tables;
        
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
        
        # Check and run migration for navigation table if it exists but lacks is_private column
        if ($navigation_exists) {
            my $has_is_private = $self->column_exists($c, 'navigation', 'is_private');
            if (!$has_is_private) {
                $c->log->info("Running migration to add is_private column to navigation table");
                $self->run_navigation_migration($c);
            }
        }
    };
    if ($@) {
        $c->log->error("Error ensuring navigation tables exist: $@");
    }
}

# Method to get navigation items filtered by privacy settings
sub get_navigation_items {
    my ($self, $c, $menu_name, $user_logged_in) = @_;
    
    $c->log->debug("Getting navigation items for menu: $menu_name, user_logged_in: " . ($user_logged_in ? 'yes' : 'no'));
    
    my @results;
    
    eval {
        # Get navigation items from the new navigation table
        my $rs = $c->model('DBEncy')->resultset('Navigation')->search(
            { 
                menu => $menu_name,
                -or => [
                    { is_private => 0 },                    # Public items always shown
                    { is_private => 1, -and => $user_logged_in ? () : ('0=1') } # Private items only if logged in
                ]
            },
            { 
                order_by => [
                    { -asc => 'parent_id' },    # Top-level items first (parent_id is null)
                    { -asc => 'order' }         # Then by order within same level
                ],
                prefetch => ['page', 'parent', 'children']
            }
        );
        
        while (my $nav_item = $rs->next) {
            my $item_data = {
                id          => $nav_item->id,
                page_id     => $nav_item->page_id,
                menu        => $nav_item->menu,
                parent_id   => $nav_item->parent_id,
                order       => $nav_item->order,
                is_private  => $nav_item->is_private,
            };
            
            # Include page data if available
            if ($nav_item->page) {
                $item_data->{page} = {
                    id          => $nav_item->page->id,
                    name        => $nav_item->page->name,
                    url         => $nav_item->page->url,
                    target      => $nav_item->page->target,
                    description => $nav_item->page->description,
                    status      => $nav_item->page->status,
                };
            }
            
            push @results, $item_data;
        }
        
        $c->log->debug("Found " . scalar(@results) . " navigation items");
    };
    if ($@) {
        $c->log->error("Error getting navigation items: $@");
    }
    
    return \@results;
}

# Method to get hierarchical navigation structure
sub get_navigation_tree {
    my ($self, $c, $menu_name, $user_logged_in) = @_;
    
    my $items = $self->get_navigation_items($c, $menu_name, $user_logged_in);
    
    # Build hierarchical structure
    my %item_lookup = map { $_->{id} => $_ } @$items;
    my @tree = ();
    
    foreach my $item (@$items) {
        if (defined $item->{parent_id} && exists $item_lookup{$item->{parent_id}}) {
            # Add as child to parent
            $item_lookup{$item->{parent_id}}->{children} ||= [];
            push @{$item_lookup{$item->{parent_id}}->{children}}, $item;
        } else {
            # Top-level item
            push @tree, $item;
        }
    }
    
    return \@tree;
}

# Helper method to check if a column exists in a table
sub column_exists {
    my ($self, $c, $table_name, $column_name) = @_;
    
    eval {
        my $dbh = $c->model('DBEncy')->schema->storage->dbh;
        my $sth = $dbh->prepare("SHOW COLUMNS FROM `$table_name` LIKE ?");
        $sth->execute($column_name);
        my $result = $sth->fetchrow_arrayref();
        return $result ? 1 : 0;
    };
    if ($@) {
        $c->log->error("Error checking if column exists: $@");
        return 0;
    }
}

# Method to run the navigation table migration
sub run_navigation_migration {
    my ($self, $c) = @_;
    
    eval {
        my $dbh = $c->model('DBEncy')->schema->storage->dbh;
        
        # Add is_private column
        $dbh->do("ALTER TABLE `navigation` ADD COLUMN `is_private` TINYINT(1) NOT NULL DEFAULT 0 COMMENT 'Flag to mark navigation items as private (1) or public (0)'");
        
        # Create indexes for better performance
        $dbh->do("CREATE INDEX `idx_navigation_privacy` ON `navigation` (`is_private`)");
        $dbh->do("CREATE INDEX `idx_navigation_menu_privacy` ON `navigation` (`menu`, `is_private`)");
        
        # Update table comment
        $dbh->do("ALTER TABLE `navigation` COMMENT = 'Navigation structure with hierarchical support and public/private visibility'");
        
        $c->log->info("Successfully ran navigation migration - added is_private column");
    };
    if ($@) {
        $c->log->error("Error running navigation migration: $@");
    }
}

# Method to add a navigation item (Admin interface)
sub add_navigation_item :Path('/navigation/add') :Args(0) {
    my ($self, $c) = @_;
    
    # Check if user is admin
    my $root_controller = $c->controller('Root');
    unless ($root_controller->user_exists($c) && $c->session->{roles} && 
            (grep { $_ eq 'admin' } @{$c->session->{roles}})) {
        $c->flash->{error_msg} = "Administrative privileges required.";
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }
    
    if ($c->req->method eq 'POST') {
        my $page_id = $c->req->param('page_id');
        my $menu = $c->req->param('menu');
        my $parent_id = $c->req->param('parent_id') || undef;
        my $order = $c->req->param('order') || 0;
        my $is_private = $c->req->param('is_private') ? 1 : 0;
        
        # Validate required fields
        unless ($page_id && $menu) {
            $c->flash->{error_msg} = "Page ID and Menu are required fields.";
            $c->stash->{template} = 'Navigation/add.tt';
            return;
        }
        
        # Add the navigation item
        eval {
            $c->model('DBEncy')->resultset('Navigation')->create({
                page_id => $page_id,
                menu => $menu,
                parent_id => $parent_id,
                order => $order,
                is_private => $is_private,
            });
            $c->flash->{success_msg} = "Navigation item added successfully.";
            $self->clear_navigation_cache($c);
            $c->response->redirect($c->uri_for('/navigation/manage'));
            return;
        };
        if ($@) {
            $c->log->error("Error adding navigation item: $@");
            $c->flash->{error_msg} = "Error adding navigation item: $@";
        }
    }
    
    # Load pages for dropdown
    $c->stash->{pages} = [$c->model('DBEncy')->resultset('PageTb')->search({}, 
                         { order_by => 'name' })->all];
    $c->stash->{template} = 'Navigation/add.tt';
}

# Method to manage navigation items (Admin interface)
sub manage :Path('/navigation/manage') :Args(0) {
    my ($self, $c) = @_;
    
    # Check if user is admin
    my $root_controller = $c->controller('Root');
    unless ($root_controller->user_exists($c) && $c->session->{roles} && 
            (grep { $_ eq 'admin' } @{$c->session->{roles}})) {
        $c->flash->{error_msg} = "Administrative privileges required.";
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }
    
    # Get all navigation items
    my @navigation_items = $c->model('DBEncy')->resultset('Navigation')->search({}, {
        order_by => ['menu', 'parent_id', 'order'],
        prefetch => 'page'
    })->all;
    
    $c->stash->{navigation_items} = \@navigation_items;
    $c->stash->{template} = 'Navigation/manage.tt';
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

# Alias method for backward compatibility
sub populate_navigation {
    my ($self, $c) = @_;
    return $self->populate_navigation_data($c);
}

__PACKAGE__->meta->make_immutable;

1;
