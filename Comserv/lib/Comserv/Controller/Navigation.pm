package Comserv::Controller::Navigation;
use Moose;
use namespace::autoclean;
use Data::Dumper;

BEGIN { extends 'Catalyst::Controller'; }

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
        # PERFORMANCE FIX: Use cached database model to avoid repeated ACCEPT_CONTEXT calls
        my $db_model = $c->stash->{_cached_db_model} || $c->model('DBEncy');
        
        # Try to use the DBIx::Class API first
        my $rs = $db_model->resultset('InternalLinksTb')->search({
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
            # Get the database handle from the cached model
            my $dbh = $db_model->schema->storage->dbh;
            
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
        # PERFORMANCE FIX: Use cached database model to avoid repeated ACCEPT_CONTEXT calls
        my $db_model = $c->stash->{_cached_db_model} || $c->model('DBEncy');
        
        # Try to use the DBIx::Class API first
        my $rs = $db_model->resultset('PageTb')->search({
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
            # Get the database handle from the cached model
            my $dbh = $db_model->schema->storage->dbh;
            
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
        # PERFORMANCE FIX: Use cached database model to avoid repeated ACCEPT_CONTEXT calls
        my $db_model = $c->stash->{_cached_db_model} || $c->model('DBEncy');
        
        # Try to use the DBIx::Class API first
        my $rs = $db_model->resultset('PageTb')->search({
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
            # Get the database handle from the cached model
            my $dbh = $db_model->schema->storage->dbh;
            
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
        # PERFORMANCE FIX: Use cached database model to avoid repeated ACCEPT_CONTEXT calls
        my $db_model = $c->stash->{_cached_db_model} || $c->model('DBEncy');
        
        # Try to use the DBIx::Class API first
        my $rs = $db_model->resultset('InternalLinksTb')->search({
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
            # Get the database handle from the cached model
            my $dbh = $db_model->schema->storage->dbh;
            
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
        # PERFORMANCE FIX: Use cached database model to avoid repeated ACCEPT_CONTEXT calls
        my $db_model = $c->stash->{_cached_db_model} || $c->model('DBEncy');
        
        # Try to use the DBIx::Class API first
        my $rs = $db_model->resultset('InternalLinksTb')->search({
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
            # Get the database handle from the cached model
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
            $c->stash->{template} = 'navigation/add_private_link.tt';
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
    $c->stash->{template} = 'navigation/add_private_link.tt';
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
    $c->stash->{template} = 'navigation/manage_private_links.tt';
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
            $c->stash->{template} = 'navigation/edit_private_link.tt';
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
    $c->stash->{template} = 'navigation/edit_private_link.tt';
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
            $c->stash->{template} = 'navigation/add_link.tt';
            return;
        }
        
        # SECURITY: Site-specific permissions validation
        my $current_site = $c->session->{SiteName} || '';
        if ($current_site ne 'SiteName' && $current_site ne 'CSC') {
            # Non-privileged sites can only modify their own site
            if ($site_name ne $current_site && $site_name ne 'All') {
                $c->flash->{error_msg} = "You can only add links for your current site ($current_site).";
                $c->stash->{menu_type} = $menu_type;
                $c->stash->{template} = 'navigation/add_link.tt';
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
    $c->stash->{template} = 'navigation/add_link.tt';
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
    $c->stash->{template} = 'navigation/manage_links.tt';
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
            $c->stash->{template} = 'navigation/edit_link.tt';
            return;
        }
        
        # SECURITY: Site-specific permissions validation for updates
        if ($current_site ne 'SiteName' && $current_site ne 'CSC') {
            # Non-privileged sites can only modify their own site
            if ($site_name ne $current_site && $site_name ne 'All') {
                $c->flash->{error_msg} = "You can only update links for your current site ($current_site).";
                $c->stash->{link} = { $link->get_columns };
                $c->stash->{template} = 'navigation/edit_link.tt';
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
    $c->stash->{template} = 'navigation/edit_link.tt';
}

# Method to populate navigation data in the stash
sub populate_navigation_data {
    my ($self, $c) = @_;
    
    # Use eval to catch any errors
    eval {
        my $site_name = $c->stash->{SiteName} || $c->session->{SiteName} || 'default';
        $c->log->debug("Populating navigation data for site: $site_name");
        
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
        $c->log->debug("Set is_admin flag to: " . ($is_admin ? 'true' : 'false'));
        
        # PERFORMANCE FIX: Cache the database model instance to avoid repeated ACCEPT_CONTEXT calls
        my $db_model = $c->stash->{_cached_db_model};
        if (!$db_model) {
            $db_model = $c->model('DBEncy');
            $c->stash->{_cached_db_model} = $db_model;
        }
        my $schema = $db_model->schema;
        
        # PERFORMANCE FIX: Cache table existence check to avoid repeated queries
        my $tables_checked = $c->stash->{_tables_checked};
        if (!$tables_checked) {
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
            
            # Mark tables as checked to avoid repeating this expensive operation
            $c->stash->{_tables_checked} = 1;
        }
        
        # PERFORMANCE FIX: Cache navigation data in session to avoid repeated database queries
        my $nav_cache_key = "nav_cache_${site_name}_" . ($c->session->{username} || 'guest') . "_" . ($is_admin ? 'admin' : 'user');
        my $nav_cache_time = $c->session->{"${nav_cache_key}_time"} || 0;
        my $cache_ttl = 300; # 5 minutes cache
        
        if (time() - $nav_cache_time < $cache_ttl && $c->session->{$nav_cache_key}) {
            # Use cached navigation data
            my $cached_nav = $c->session->{$nav_cache_key};
            $c->stash->{member_links} = $cached_nav->{member_links};
            $c->stash->{member_pages} = $cached_nav->{member_pages};
            $c->stash->{main_links} = $cached_nav->{main_links};
            $c->stash->{main_pages} = $cached_nav->{main_pages};
            $c->stash->{hosted_links} = $cached_nav->{hosted_links};
            $c->stash->{admin_pages} = $cached_nav->{admin_pages} if $is_admin;
            $c->stash->{admin_links} = $cached_nav->{admin_links} if $is_admin;
            $c->stash->{private_links} = $cached_nav->{private_links};
            
            $c->log->debug("Using cached navigation data (age: " . (time() - $nav_cache_time) . "s)");
        } else {
            # Fetch fresh navigation data
            $c->stash->{member_links} = $self->get_internal_links($c, 'Member_links', $site_name);
            $c->stash->{member_pages} = $self->get_pages($c, 'member', $site_name);
            
            $c->stash->{main_links} = $self->get_internal_links($c, 'Main_links', $site_name);
            $c->stash->{main_pages} = $self->get_pages($c, 'Main', $site_name);
            
            $c->stash->{hosted_links} = $self->get_internal_links($c, 'Hosted_link', $site_name);
            
            # Populate admin links and pages only for admin users
            if ($is_admin) {
                $c->stash->{admin_pages} = $self->get_admin_pages($c, $site_name);
                $c->stash->{admin_links} = $self->get_admin_links($c, $site_name);
            }
            
            # Populate private links for logged-in users
            if ($c->user_exists && $c->session->{username}) {
                $c->stash->{private_links} = $self->get_private_links($c, $c->session->{username}, $site_name);
            }
            
            # Cache the navigation data
            $c->session->{$nav_cache_key} = {
                member_links => $c->stash->{member_links},
                member_pages => $c->stash->{member_pages},
                main_links => $c->stash->{main_links},
                main_pages => $c->stash->{main_pages},
                hosted_links => $c->stash->{hosted_links},
                admin_pages => $c->stash->{admin_pages},
                admin_links => $c->stash->{admin_links},
                private_links => $c->stash->{private_links},
            };
            $c->session->{"${nav_cache_key}_time"} = time();
            
            $c->log->debug("Cached fresh navigation data");
        }
        
        $c->log->debug("Navigation data populated successfully");
    };
    if ($@) {
        $c->log->error("Error populating navigation data: $@");
    }
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