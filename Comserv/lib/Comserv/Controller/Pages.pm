package Comserv::Controller::Pages;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;
use Comserv::Util::AdminAuth;

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
    
    # Check site access: CSC can view any page, others only their own site's pages, unless shared
    my $is_shared = 0;
    if ($page->can('share_with') && $page->share_with) {
        my $shared_str = $page->share_with;
        if ($shared_str eq 'all' || grep { $_ eq $sitename } split(/\s*,\s*/, $shared_str)) {
            $is_shared = 1;
        }
    }
    
    if ($sitename ne 'CSC' && $page->sitename ne $sitename && !$is_shared) {
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
        # Other sites see their own pages and pages shared with them
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'list', "Non-CSC user - fetching pages for site: $sitename (including shared pages)");
        
        my @pages = $c->model('DBEncy')->resultset('Page')->search(
            {
                '-or' => [
                    { sitename => $sitename },
                    { share_with => { 'like' => "%$sitename%" } },
                    { share_with => 'all' },
                ],
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
                share_with => $params->{share_with} || '',
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
                    roles => $params->{roles},
                    share_with => $params->{share_with} || ''
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

# Action to migrate legacy pages from Forager to Ency
sub migrate_pages :Path('/admin/migrate_pages') :Args(0) {
    my ($self, $c) = @_;
    
    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->check_admin_access($c, 'migrate_pages')) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'migrate_pages',
            "Access denied for migrate_pages - username: " . ($c->session->{username} || 'none'));
        $c->flash->{error_msg} = "Access denied. Admin access required.";
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }
    
    my $action = $c->req->param('action') || '';
    
    if ($action eq 'preview') {
        my $db_forager = $c->model('DBForager');
        my $db_ency = $c->model('DBEncy');
        
        my @pages = $db_forager->resultset('PageTb')->all;
        my @mapping_issues;
        my $issues_count = 0;
        
        for my $p (@pages) {
            my @issues;
            if (!defined $p->page_code || $p->page_code eq '') {
                push @issues, "Missing page code";
            } else {
                my $exists = $db_ency->resultset('Page')->find({ page_code => $p->page_code });
                if ($exists) {
                    push @issues, "Duplicate page code (already exists in Ency)";
                }
            }
            if (!defined $p->sitename || $p->sitename eq '') {
                push @issues, "Missing sitename";
            }
            if (!defined $p->menu || $p->menu eq '') {
                push @issues, "Missing menu";
            }
            
            if (@issues) {
                $issues_count++;
                push @mapping_issues, {
                    page => $p,
                    issues => \@issues,
                };
            }
        }
        
        $c->stash(
            show_preview => 1,
            preview_data => {
                total_count => scalar @pages,
                issues_count => $issues_count,
                mapping_issues => \@mapping_issues,
                forager_pages => \@pages,
            }
        );
    }
    elsif ($action eq 'migrate') {
        my $db_forager = $c->model('DBForager');
        my $db_ency = $c->model('DBEncy');
        
        my @selected_ids = $c->req->param('selected_pages');
        
        if (!@selected_ids) {
            $c->stash(error_msg => "No pages selected for migration.");
        }
        else {
            my $migrated_count = 0;
            my $skipped_count = 0;
            my $error_count = 0;
            my @migration_log;
            my @errors;
            
            for my $id (@selected_ids) {
                my $p = $db_forager->resultset('PageTb')->find($id);
                unless ($p) {
                    $error_count++;
                    push @errors, "Legacy record ID '$id' not found in Forager page_tb.";
                    next;
                }
                
                my $exists = $db_ency->resultset('Page')->find({ page_code => $p->page_code });
                if ($exists) {
                    $skipped_count++;
                    push @migration_log, "Skipped duplicate page code '" . $p->page_code . "'.";
                    next;
                }
                
                eval {
                    $db_ency->resultset('Page')->create({
                        sitename    => $p->sitename || 'CSC',
                        menu        => $p->menu || 'main',
                        page_code   => $p->page_code,
                        title       => $p->app_title || $p->page_code,
                        body        => $p->body || '',
                        description => $p->description,
                        keywords    => $p->keywords,
                        link_order  => $p->link_order || 0,
                        status      => $p->status || 'active',
                        roles       => 'public',
                        created_by  => $p->username_of_poster || 'admin',
                    });
                    $migrated_count++;
                    push @migration_log, "Successfully migrated page '" . $p->page_code . "' (" . ($p->app_title || '') . ").";
                };
                if ($@) {
                    $error_count++;
                    push @errors, "Failed to migrate page '" . $p->page_code . "': $@";
                }
            }
            
            $c->stash(
                show_result => 1,
                migration_result => {
                    migrated_count => $migrated_count,
                    skipped_count => $skipped_count,
                    error_count => $error_count,
                    migration_log => \@migration_log,
                    errors => \@errors,
                }
            );
        }
    }
    
    $c->stash(template => 'admin/migrate_pages.tt');
}

# Action to manage/administer pages in pages_content table
sub pages :Path('/admin/pages') :Args(0) {
    my ($self, $c) = @_;
    
    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->check_admin_access($c, 'pages')) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'pages',
            "Access denied for pages - username: " . ($c->session->{username} || 'none'));
        $c->flash->{error_msg} = "Access denied. Admin access required.";
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }
    
    my $db_ency = $c->model('DBEncy');
    my $action = $c->req->param('action') || 'list';
    my $error_msg;
    my $success_msg;
    
    my $current_sitename = $c->stash->{SiteName} || $c->session->{SiteName} || 'CSC';
    
    # Get available roles for the current site
    my @site_roles_db = ();
    eval {
        @site_roles_db = $db_ency->resultset('SiteRole')->search(
            { sitename => $current_sitename },
            { order_by => 'role_name' }
        )->all;
    };
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'pages', "Error fetching site roles: $@");
    }
    
    my %seen_roles = map { $_ => 1 } qw(public normal member editor developer admin WorkshopLeader);
    my @available_roles = qw(public normal member editor developer admin WorkshopLeader);
    
    foreach my $r (@site_roles_db) {
        my $name = $r->role_name;
        unless ($seen_roles{$name}) {
            $seen_roles{$name} = 1;
            push @available_roles, $name;
        }
    }
    $c->stash(available_roles => \@available_roles);
    
    # Get all sites for sharing options
    my @all_sites_list = ();
    eval {
        @all_sites_list = $db_ency->resultset('Site')->search({}, { order_by => 'name' })->all;
    };
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'pages', "Error fetching sites: $@");
    }
    my @site_names_all = map { $_->name } @all_sites_list;
    my %seen_sites = map { $_ => 1 } @site_names_all;
    foreach my $s (qw(CSC HelpDesk Apiary Weather ENCY Workshops Planning)) {
        unless ($seen_sites{$s}) {
            push @site_names_all, $s;
            $seen_sites{$s} = 1;
        }
    }
    $c->stash(all_sites => \@site_names_all);
    
    if ($action eq 'create') {
        $c->stash(
            show_form => 'create',
            page_item => { sitename => $current_sitename },
        );
    }
    elsif ($action eq 'edit') {
        my $id = $c->req->param('id');
        my $page_item = $db_ency->resultset('Page')->find($id);
        if ($page_item) {
            if ($current_sitename ne 'CSC' && $page_item->sitename ne $current_sitename) {
                $c->flash->{error_msg} = "Access denied. Page belongs to a different site.";
                $c->response->redirect($c->uri_for('/admin/pages'));
                return;
            }
            my $page_role = $page_item->roles || '';
            if ($page_role && !$seen_roles{$page_role}) {
                $seen_roles{$page_role} = 1;
                push @available_roles, $page_role;
            }
            $c->stash(
                show_form => 'edit',
                page_item => $page_item,
            );
        } else {
            $c->flash->{error_msg} = "Page not found.";
            $c->response->redirect($c->uri_for('/admin/pages'));
            return;
        }
    }
    elsif ($action eq 'save') {
        my $id = $c->req->param('id');
        my $sitename = $c->req->param('sitename') || 'CSC';
        my $menu = $c->req->param('menu') || 'main';
        my $page_code = $c->req->param('page_code') || '';
        my $title = $c->req->param('title') || '';
        my $body = $c->req->param('body') || '';
        my $description = $c->req->param('description');
        my $keywords = $c->req->param('keywords');
        my $link_order = $c->req->param('link_order') || 0;
        my $status = $c->req->param('status') || 'active';
        my $roles = $c->req->param('roles') || 'public';
        my $share_with = $c->req->param('share_with') || '';
        
        # Enforce current site if not CSC
        if ($current_sitename ne 'CSC') {
            $sitename = $current_sitename;
        }
        
        if ($page_code eq '' || $title eq '' || $body eq '') {
            $error_msg = "Page Code, Title, and Body are required fields.";
            my $page_data = {
                id => $id,
                sitename => $sitename,
                menu => $menu,
                page_code => $page_code,
                title => $title,
                body => $body,
                description => $description,
                keywords => $keywords,
                link_order => $link_order,
                status => $status,
                roles => $roles,
                share_with => $share_with,
            };
            $c->stash(
                show_form => $id ? 'edit' : 'create',
                page_item => $page_data,
                error_msg => $error_msg,
            );
        }
        else {
            my $exists_cond = { page_code => $page_code };
            if ($id) {
                $exists_cond->{id} = { '!=' => $id };
            }
            my $exists = $db_ency->resultset('Page')->search($exists_cond)->first;
            if ($exists) {
                $error_msg = "Duplicate page code '$page_code'. Page Code must be unique.";
                my $page_data = {
                    id => $id,
                    sitename => $sitename,
                    menu => $menu,
                    page_code => $page_code,
                    title => $title,
                    body => $body,
                    description => $description,
                    keywords => $keywords,
                    link_order => $link_order,
                    status => $status,
                    roles => $roles,
                    share_with => $share_with,
                };
                $c->stash(
                    show_form => $id ? 'edit' : 'create',
                    page_item => $page_data,
                    error_msg => $error_msg,
                );
            }
            else {
                eval {
                    if ($id) {
                        my $page_item = $db_ency->resultset('Page')->find($id);
                        if ($current_sitename ne 'CSC' && $page_item->sitename ne $current_sitename) {
                            die "Access denied: cannot edit page belonging to another site.";
                        }
                        $page_item->update({
                            sitename    => $sitename,
                            menu        => $menu,
                            page_code   => $page_code,
                            title       => $title,
                            body        => $body,
                            description => $description,
                            keywords    => $keywords,
                            link_order  => $link_order,
                            status      => $status,
                            roles       => $roles,
                            share_with  => $share_with,
                        });
                        $c->flash->{success_msg} = "Page updated successfully.";
                    } else {
                        my $current_user = $c->session->{username} || 'admin';
                        $db_ency->resultset('Page')->create({
                            sitename    => $sitename,
                            menu        => $menu,
                            page_code   => $page_code,
                            title       => $title,
                            body        => $body,
                            description => $description,
                            keywords    => $keywords,
                            link_order  => $link_order,
                            status      => $status,
                            roles       => $roles,
                            share_with  => $share_with,
                            created_by  => $current_user,
                        });
                        $c->flash->{success_msg} = "Page created successfully.";
                    }
                };
                if ($@) {
                    $error_msg = "Database error: $@";
                    my $page_data = {
                        id => $id,
                        sitename => $sitename,
                        menu => $menu,
                        page_code => $page_code,
                        title => $title,
                        body => $body,
                        description => $description,
                        keywords => $keywords,
                        link_order => $link_order,
                        status => $status,
                        roles => $roles,
                        share_with => $share_with,
                    };
                    $c->stash(
                        show_form => $id ? 'edit' : 'create',
                        page_item => $page_data,
                        error_msg => $error_msg,
                    );
                } else {
                    $c->response->redirect($c->uri_for('/admin/pages'));
                    return;
                }
            }
        }
    }
    elsif ($action eq 'delete') {
        my $id = $c->req->param('id');
        my $page_item = $db_ency->resultset('Page')->find($id);
        if ($page_item) {
            if ($current_sitename ne 'CSC' && $page_item->sitename ne $current_sitename) {
                $c->flash->{error_msg} = "Access denied. Page belongs to a different site.";
            } else {
                eval {
                    $page_item->delete;
                    $c->flash->{success_msg} = "Page deleted successfully.";
                };
                if ($@) {
                    $c->flash->{error_msg} = "Failed to delete page: $@";
                }
            }
        } else {
            $c->flash->{error_msg} = "Page not found.";
        }
        $c->response->redirect($c->uri_for('/admin/pages'));
        return;
    }
    
    if ($action eq 'list') {
        my $search = $c->req->param('search') || '';
        my $filter_site = $c->req->param('filter_site') || '';
        my $filter_status = $c->req->param('filter_status') || '';
        
        my %search_cond;
        if ($search) {
            $search_cond{'-or'} = [
                { title     => { like => "%$search%" } },
                { page_code => { like => "%$search%" } },
            ];
        }
        if ($current_sitename ne 'CSC') {
            $search_cond{sitename} = $current_sitename;
        } elsif ($filter_site) {
            $search_cond{sitename} = $filter_site;
        }
        if ($filter_status) {
            $search_cond{status} = $filter_status;
        }
        
        my @pages = $db_ency->resultset('Page')->search(\%search_cond, {
            order_by => ['sitename', 'menu', 'link_order']
        })->all;
        
        my @site_names;
        if ($current_sitename ne 'CSC') {
            push @site_names, $current_sitename;
        } else {
            my @sites = $db_ency->resultset('Page')->search({}, {
                select => ['sitename'],
                distinct => 1,
            })->all;
            @site_names = map { $_->sitename } @sites;
        }
        
        $c->stash(
            pages         => \@pages,
            site_names    => \@site_names,
            search        => $search,
            filter_site   => $current_sitename ne 'CSC' ? $current_sitename : $filter_site,
            filter_status => $filter_status,
        );
    }
    
    $c->stash(
        template => 'admin/pages.tt',
        success_msg => $c->flash->{success_msg} || $c->stash->{success_msg},
        error_msg => $c->flash->{error_msg} || $c->stash->{error_msg},
        current_site  => $current_sitename,
    );
}

__PACKAGE__->meta->make_immutable;

1;