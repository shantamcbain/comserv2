package Comserv::Controller::Pages;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

BEGIN { extends 'Catalyst::Controller'; }

# Display a page by page_code
sub view :Path('/page') :Args(1) {
    my ($self, $c, $page_code) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view', "Viewing page: $page_code");
    
    # Get current site and user roles
    my $sitename = $c->stash->{SiteName} || $c->session->{SiteName} || 'CSC';
    my $user_roles = $c->session->{roles} || 'public';
    
    # Find the page
    my $page = $c->model('DBEncy')->resultset('Page')->find({ page_code => $page_code });
    
    unless ($page) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'view', "Page not found: $page_code");
        $c->response->status(404);
        $c->stash(
            error_msg => "Page not found: $page_code",
            template => 'error.tt'
        );
        return;
    }
    
    # Check site access: CSC can view any page, others only their own site's pages
    if ($sitename ne 'CSC' && $page->sitename ne $sitename) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'view', 
            "Site access denied: User from site '$sitename' trying to access page from site '" . $page->sitename . "'");
        $c->response->status(403);
        $c->stash(
            error_msg => "Access denied: Page belongs to a different site",
            template => 'error.tt'
        );
        return;
    }
    
    # Check if user has access to this page based on roles
    unless ($self->_check_page_access($c, $page, $user_roles)) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'view', "Role access denied to page: $page_code for roles: $user_roles");
        $c->response->status(403);
        $c->stash(
            error_msg => "Access denied to page: " . $page->title,
            template => 'error.tt'
        );
        return;
    }
    
    $c->stash(
        page => $page,
        template => 'pages/view.tt'
    );
}

# List pages for current site and user role
sub list :Path('/pages') :Args(0) {
    my ($self, $c) = @_;
    
    my $sitename = $c->stash->{SiteName} || $c->session->{SiteName} || 'CSC';
    my $user_roles = $c->session->{roles} || 'public';
    my $menu = $c->request->params->{menu} || 'Main';
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'list', "Listing pages for site: $sitename, menu: $menu, roles: $user_roles");
    
    my $pages_by_site = {};
    my @accessible_pages = ();
    
    if ($sitename eq 'CSC') {
        # CSC sees all pages grouped by site
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'list', "CSC user - fetching all pages grouped by site");
        
        # Get all active pages for the specified menu
        my @all_pages = $c->model('DBEncy')->resultset('Page')->search(
            {
                menu => $menu,
                status => 'active'
            },
            {
                order_by => ['sitename', 'link_order']
            }
        );
        
        # Group pages by site and filter by access
        foreach my $page (@all_pages) {
            if ($self->_check_page_access($c, $page, $user_roles)) {
                my $page_sitename = $page->sitename;
                push @{$pages_by_site->{$page_sitename}}, $page;
            }
        }
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'list', 
            "CSC user - found pages for sites: " . join(', ', keys %$pages_by_site));
        
    } else {
        # Other sites see only their own pages
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'list', "Non-CSC user - fetching pages for site: $sitename");
        
        my @pages = $c->model('DBEncy')->resultset('Page')->search(
            {
                sitename => $sitename,
                menu => $menu,
                status => 'active'
            },
            {
                order_by => 'link_order'
            }
        );
        
        # Filter by user access
        @accessible_pages = grep { $self->_check_page_access($c, $_, $user_roles) } @pages;
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'list', 
            "Non-CSC user - found " . scalar(@accessible_pages) . " accessible pages");
    }
    
    $c->stash(
        pages => \@accessible_pages,
        pages_by_site => $pages_by_site,
        sitename => $sitename,
        menu => $menu,
        is_csc => ($sitename eq 'CSC'),
        template => 'pages/list.tt'
    );
}

# Admin: Create new page
sub create :Path('/pages/create') :Args(0) {
    my ($self, $c) = @_;
    
    # Check admin access
    unless ($self->_check_admin_access($c)) {
        $c->response->status(403);
        $c->stash(error_msg => "Admin access required", template => 'error.tt');
        return;
    }
    
    my $current_sitename = $c->stash->{SiteName} || $c->session->{SiteName} || 'CSC';
    
    if ($c->request->method eq 'POST') {
        my $params = $c->request->params;
        
        # Validate site access: non-CSC admins can only create pages for their own site
        if ($current_sitename ne 'CSC' && $params->{sitename} ne $current_sitename) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'create', 
                "Non-CSC admin from site '$current_sitename' trying to create page for site '" . $params->{sitename} . "'");
            $c->stash(
                error_msg => "You can only create pages for your own site ($current_sitename)",
                form_data => $params
            );
        } else {
            # Create new page
            my $page_data = {
                sitename => $params->{sitename},
                menu => $params->{menu},
                page_code => $params->{page_code},
                title => $params->{title},
                body => $params->{body},
                description => $params->{description},
                keywords => $params->{keywords},
                link_order => $params->{link_order} || 0,
                status => $params->{status} || 'active',
                roles => $params->{roles} || 'public',
                created_by => $c->session->{username} || 'admin'
            };
            
            eval {
                my $page = $c->model('DBEncy')->resultset('Page')->create($page_data);
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create', "Page created: " . $page->page_code);
                
                $c->flash->{success_message} = 'Page created successfully';
                $c->response->redirect($c->uri_for('/page', $page->page_code));
            };
            
            if ($@) {
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create', "Error creating page: $@");
                $c->stash(
                    error_msg => "Error creating page: $@",
                    form_data => $params
                );
            }
        }
    }
    
    # Get available sites for CSC admins
    my $available_sites = [];
    if ($current_sitename eq 'CSC') {
        # CSC can create pages for any site
        my $sites = $c->model('Site')->get_all_sites($c);
        $available_sites = [map { $_->name } @$sites] if $sites;
    } else {
        # Other admins can only create pages for their own site
        $available_sites = [$current_sitename];
    }
    
    $c->stash(
        available_sites => $available_sites,
        current_sitename => $current_sitename,
        is_csc => ($current_sitename eq 'CSC'),
        template => 'pages/create.tt'
    );
}

# Admin: Edit existing page
sub edit :Path('/pages/edit') :Args(1) {
    my ($self, $c, $page_code) = @_;
    
    # Check admin access
    unless ($self->_check_admin_access($c)) {
        $c->response->status(403);
        $c->stash(error_msg => "Admin access required", template => 'error.tt');
        return;
    }
    
    my $current_sitename = $c->stash->{SiteName} || $c->session->{SiteName} || 'CSC';
    
    my $page = $c->model('DBEncy')->resultset('Page')->find({ page_code => $page_code });
    unless ($page) {
        $c->response->status(404);
        $c->stash(error_msg => "Page not found: $page_code", template => 'error.tt');
        return;
    }
    
    # Check if admin can edit this page: CSC can edit any page, others only their own site's pages
    if ($current_sitename ne 'CSC' && $page->sitename ne $current_sitename) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'edit', 
            "Non-CSC admin from site '$current_sitename' trying to edit page from site '" . $page->sitename . "'");
        $c->response->status(403);
        $c->stash(
            error_msg => "You can only edit pages from your own site ($current_sitename)",
            template => 'error.tt'
        );
        return;
    }
    
    if ($c->request->method eq 'POST') {
        my $params = $c->request->params;
        
        # Validate site change: non-CSC admins cannot change sitename to other sites
        if ($current_sitename ne 'CSC' && $params->{sitename} ne $current_sitename) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'edit', 
                "Non-CSC admin from site '$current_sitename' trying to change page site to '" . $params->{sitename} . "'");
            $c->stash(
                error_msg => "You can only assign pages to your own site ($current_sitename)",
                page => $page
            );
        } else {
            eval {
                $page->update({
                    sitename => $params->{sitename},
                    menu => $params->{menu},
                    title => $params->{title},
                    body => $params->{body},
                    description => $params->{description},
                    keywords => $params->{keywords},
                    link_order => $params->{link_order},
                    status => $params->{status},
                    roles => $params->{roles}
                });
                
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit', "Page updated: $page_code");
                
                $c->flash->{success_message} = 'Page updated successfully';
                $c->response->redirect($c->uri_for('/page', $page_code));
            };
            
            if ($@) {
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'edit', "Error updating page: $@");
                $c->stash(error_msg => "Error updating page: $@");
            }
        }
    }
    
    # Get available sites for CSC admins
    my $available_sites = [];
    if ($current_sitename eq 'CSC') {
        # CSC can assign pages to any site
        my $sites = $c->model('Site')->get_all_sites($c);
        $available_sites = [map { $_->name } @$sites] if $sites;
    } else {
        # Other admins can only assign pages to their own site
        $available_sites = [$current_sitename];
    }
    
    $c->stash(
        page => $page,
        available_sites => $available_sites,
        current_sitename => $current_sitename,
        is_csc => ($current_sitename eq 'CSC'),
        template => 'pages/edit.tt'
    );
}

# Check if user has admin access
sub _check_admin_access {
    my ($self, $c) = @_;
    
    # Get roles from session
    my $roles = $c->session->{roles};
    
    return 0 unless defined $roles;
    
    # Handle both array and string formats
    if (ref($roles) eq 'ARRAY') {
        # Check if 'admin' is in the roles array
        foreach my $role (@$roles) {
            return 1 if lc($role) eq 'admin';
        }
    } elsif (!ref($roles)) {
        # Check if roles string contains 'admin' with word boundaries
        return 1 if $roles =~ /\badmin\b/i;
    }
    
    return 0;
}

# Check if user has access to page based on roles
sub _check_page_access {
    my ($self, $c, $page, $user_roles) = @_;
    
    my $page_roles = $page->roles || 'public';
    
    # Public pages are accessible to everyone
    return 1 if $page_roles eq 'public';
    
    # Check if user has required role
    return $user_roles && $user_roles =~ /$page_roles/;
}

__PACKAGE__->meta->make_immutable;

1;