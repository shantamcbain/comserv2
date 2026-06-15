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
    
    # Find the page for the active site so each site can have its own "home" page.
    my $page = $c->model('DBEncy')->resultset('Page')->search(
        {
            sitename   => $sitename,
            page_code  => $page_code,
        },
        { rows => 1 }
    )->single;

    if (!$page) {
        # Fallback to shared pages or CSC pages
        $page = $c->model('DBEncy')->resultset('Page')->search(
            {
                page_code => $page_code,
                '-or' => [
                    { sitename => 'CSC' },
                    { share_with => 'all' },
                    { share_with => { 'like' => "%$sitename%" } }
                ]
            },
            { rows => 1 }
        )->single;
    }
    
    unless ($page) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'view', "Page not found: $page_code");
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
    
    my $body = $page->body || '';
    my $title = $page->title;
    
    if ($body =~ m{<html}i) {
        if ($body =~ m{<title>(.*?)</title>}is) {
            my $extracted_title = $1;
            $extracted_title =~ s/<[^>]*>//g;
            $extracted_title =~ s/^\s+|\s+$//g;
            if ($extracted_title && (!$title || $title eq $page->page_code)) {
                $title = $extracted_title;
            }
        }
        
        if ($body =~ m{<body[^>]*>(.*?)</body>}is) {
            $body = $1;
        } else {
            $body =~ s{<html[^>]*>}{}gi;
            $body =~ s{</html>}{}gi;
            $body =~ s{<head[^>]*>.*?</head>}{}gis;
        }
    }

    my $is_pub = (($page->page_type // '') eq 'newsletter_pub');
    my $is_newsletter = !$is_pub && (
        (($page->page_type // '') eq 'newsletter')
        || (($page->menu // '') eq 'newsletter')
    );

    my ($nl_meta, $nl_can_send) = (undef, 0);
    if ($is_newsletter) {
        my $nl = $c->controller('Newsletter');
        if ($nl) {
            $nl_meta     = $nl->_parse_newsletter_meta($page->keywords, $page->page_code, $page->title);
            $nl_can_send = $nl->_has_newsletter_admin_role($c) ? 1 : 0;
        }
    }

    $c->stash(
        page => $page,
        rendered_body => $body,
        page_title => $title,
        ScriptDisplayName => $is_newsletter ? 'Newsletter' : 'Page',
        is_newsletter => $is_newsletter,
        nl_meta => $nl_meta,
        nl_can_send => $nl_can_send,
        template => $is_newsletter ? 'pages/newsletter_view.tt' : 'pages/view.tt',
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
        page_title => 'Pages List',
        ScriptDisplayName => 'Pages',
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
                sitename => $params->{sitename} || $current_sitename,
                menu => $params->{menu} || 'main',
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
            
            my $exists = $c->model('DBEncy')->resultset('Page')->search(
                {
                    sitename  => $page_data->{sitename},
                    page_code => $page_data->{page_code},
                },
                { rows => 1 }
            )->single;

            if ($exists) {
                $c->stash(
                    error_msg => "Page code '$page_data->{page_code}' already exists for site '$page_data->{sitename}'.",
                    form_data => $params
                );
            } else {
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
    
    my $page = $c->model('DBEncy')->resultset('Page')->search(
        {
            sitename  => $current_sitename,
            page_code => $page_code,
        },
        { rows => 1 }
    )->single;

    if (!$page && $current_sitename eq 'CSC') {
        $page = $c->model('DBEncy')->resultset('Page')->search(
            { page_code => $page_code },
            { rows => 1 }
        )->single;
    }
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
            my $target_sitename = $params->{sitename};
            my $duplicate = $c->model('DBEncy')->resultset('Page')->search(
                {
                    sitename  => $target_sitename,
                    page_code => $page_code,
                    id        => { '!=' => $page->id },
                },
                { rows => 1 }
            )->single;

            if ($duplicate) {
                $c->stash(
                    error_msg => "Page code '$page_code' already exists for site '$target_sitename'.",
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
    
    my $action = $c->req->param('action') || 'preview';
    
    if ($action eq 'preview') {
        my $db_forager  = $c->model('DBForager');
        my $db_ency     = $c->model('DBEncy');
        my $current_site = $c->stash->{SiteName} || $c->session->{SiteName} || 'CSC';
        my $is_csc       = ($current_site eq 'CSC');

        # Fetch from Forager — status 0 = hidden, exclude those
        my %forager_search = (status => { '!=' => 0 });
        $forager_search{sitename} = $current_site unless $is_csc;

        my @all_pages = $db_forager->resultset('PageTb')->search(
            \%forager_search,
            { order_by => ['sitename', 'menu', { -asc => 'link_order' }] }
        )->all;

        # Split into already-imported and available
        my (@available, @already_imported, @missing_data);
        for my $p (@all_pages) {
            if (!$p->page_code || !$p->sitename || !$p->menu) {
                push @missing_data, $p;
                next;
            }
            my $exists = $db_ency->resultset('Page')->search({
                sitename  => $p->sitename,
                page_code => $p->page_code,
            }, { rows => 1 })->single;

            if ($exists) {
                push @already_imported, $p;
            } else {
                push @available, $p;
            }
        }

        # Get available sites and menus for the edit form
        my @site_names;
        eval {
            my $sites = $c->model('Site')->get_all_sites($c);
            @site_names = map { $_->name } @$sites if $sites && @$sites;
        };
        @site_names = ('CSC') unless @site_names;

        my @menu_options;
        eval {
            my @existing_menus = $db_ency->resultset('Page')->search(
                {}, { select => ['menu'], distinct => 1, order_by => 'menu' }
            )->all;
            @menu_options = map { $_->menu } @existing_menus;
        };
        push @menu_options, 'main', 'admin', 'footer', 'member'
            unless @menu_options;

        $c->stash(
            show_preview       => 1,
            is_csc             => $is_csc,
            site_names         => \@site_names,
            menu_options       => \@menu_options,
            preview_data       => {
                available        => \@available,
                already_imported => \@already_imported,
                missing_data     => \@missing_data,
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
                
                my $exists = $db_ency->resultset('Page')->search({
                    sitename  => $p->sitename || 'CSC',
                    page_code => $p->page_code,
                }, { rows => 1 })->single;
                if ($exists) {
                    $skipped_count++;
                    push @migration_log, "Skipped duplicate page code '" . $p->page_code . "' for site '" . ($p->sitename || 'CSC') . "'.";
                    next;
                }
                
                my $status_str = ($p->status && $p->status eq '1') ? 'active' : 'inactive';
                eval {
                    $db_ency->resultset('Page')->create({
                        sitename    => $p->sitename || 'CSC',
                        menu        => lc($p->menu || 'main'),
                        page_code   => $p->page_code,
                        title       => $p->app_title || $p->page_code,
                        body        => $p->body || '',
                        description => $p->description,
                        keywords    => $p->keywords,
                        link_order  => $p->link_order || 0,
                        status      => $status_str,
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
    
    $c->stash(
        template => 'admin/migrate_pages.tt',
        page_title => 'Migrate Legacy Pages',
        ScriptDisplayName => 'Admin',
    );
}

# Import a single Forager page with optional field overrides (Edit & Import)
sub import_single :Path('/admin/import_single') :Args(0) {
    my ($self, $c) = @_;

    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->check_admin_access($c, 'migrate_pages')) {
        $c->response->status(403);
        $c->stash(json => { error => 'Access denied' });
        $c->forward('View::JSON');
        return;
    }

    my $record_id  = $c->req->param('record_id');
    my $db_forager = $c->model('DBForager');
    my $db_ency    = $c->model('DBEncy');

    my $p = $db_forager->resultset('PageTb')->find($record_id);
    unless ($p) {
        $c->flash->{error_msg} = "Page not found in Forager (id=$record_id).";
        $c->response->redirect($c->uri_for('/admin/migrate_pages'));
        return;
    }

    # Use submitted values, falling back to Forager source values
    my $sitename   = $c->req->param('sitename')   || $p->sitename   || 'CSC';
    my $menu       = $c->req->param('menu')        || $p->menu       || 'main';
    my $page_code  = $c->req->param('page_code')   || $p->page_code;
    my $title      = $c->req->param('title')       || $p->app_title  || $p->page_code;
    my $body       = $c->req->param('body')        // $p->body       // '';
    my $description= $c->req->param('description') // $p->description;
    my $keywords   = $c->req->param('keywords')    // $p->keywords;
    my $link_order = $c->req->param('link_order')  // $p->link_order // 0;
    my $status_raw = $c->req->param('status')      // $p->status     // '1';
    my $status     = ($status_raw eq '1' || $status_raw eq 'active') ? 'active' : 'inactive';
    my $roles      = $c->req->param('roles')       || 'public';

    unless ($page_code) {
        $c->flash->{error_msg} = "Page code is required.";
        $c->response->redirect($c->uri_for('/admin/migrate_pages'));
        return;
    }

    my $exists = $db_ency->resultset('Page')->search(
        { sitename => $sitename, page_code => $page_code },
        { rows => 1 }
    )->single;

    if ($exists) {
        $c->flash->{error_msg} = "Page '$page_code' already exists for site '$sitename'. Edit it at /admin/pages.";
        $c->response->redirect($c->uri_for('/admin/migrate_pages'));
        return;
    }

    eval {
        $db_ency->resultset('Page')->create({
            sitename    => $sitename,
            menu        => lc($menu),
            page_code   => $page_code,
            title       => $title,
            body        => $body,
            description => $description,
            keywords    => $keywords,
            link_order  => $link_order,
            status      => $status,
            roles       => $roles,
            created_by  => $c->session->{username} || 'admin',
        });
    };

    if ($@) {
        $c->flash->{error_msg} = "Import failed: $@";
    } else {
        $c->flash->{success_msg} = "Page '$page_code' imported successfully.";
    }

    $c->response->redirect($c->uri_for('/admin/migrate_pages'));
}

# Toggle hide/unhide a Forager page_tb record (CSC admin only)
# Sets status=0 to hide, status=2 to unhide
sub hide_forager_page :Path('/admin/hide_forager_page') :Args(0) {
    my ($self, $c) = @_;

    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->check_admin_access($c, 'migrate_pages')) {
        $c->flash->{error_msg} = "Access denied.";
        $c->response->redirect($c->uri_for('/admin/migrate_pages'));
        return;
    }

    # Only CSC can hide pages
    my $current_site = $c->stash->{SiteName} || $c->session->{SiteName} || 'CSC';
    unless ($current_site eq 'CSC') {
        $c->flash->{error_msg} = "Only CSC admins can hide pages.";
        $c->response->redirect($c->uri_for('/admin/migrate_pages'));
        return;
    }

    my $record_id = $c->req->param('record_id');
    my $unhide    = $c->req->param('unhide') ? 1 : 0;

    eval {
        my $p = $c->model('DBForager')->resultset('PageTb')->find($record_id);
        if ($p) {
            $p->update({ status => $unhide ? '2' : '0' });
            $c->flash->{success_msg} = $unhide
                ? "Page restored to migration list."
                : "Page hidden from migration list.";
        } else {
            $c->flash->{error_msg} = "Page not found (id=$record_id).";
        }
    };
    $c->flash->{error_msg} = "Error: $@" if $@;

    $c->response->redirect($c->uri_for('/admin/migrate_pages'));
}

# Action to manage/administer pages in the page table
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
    
    # Fetch site display names for mapping
    my %site_display_map;
    eval {
        my @all_sites_db = $db_ency->resultset('Site')->all;
        foreach my $s (@all_sites_db) {
            $site_display_map{$s->name} = $s->site_display_name || $s->name;
        }
    };
    $c->stash(site_display_map => \%site_display_map);
    
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
    
    # Determine available sites for this admin
    my @available_sites_list;
    if ($current_sitename eq 'CSC') {
        @available_sites_list = @site_names_all;
    } else {
        @available_sites_list = ($current_sitename);
    }
    $c->stash(available_sites => \@available_sites_list);
    
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
            my $exists_cond = {
                sitename  => $sitename,
                page_code => $page_code,
            };
            if ($id) {
                $exists_cond->{id} = { '!=' => $id };
            }
            my $exists = $db_ency->resultset('Page')->search($exists_cond)->first;
            if ($exists) {
                $error_msg = "Duplicate page code '$page_code' for site '$sitename'. Each site can have one page with this code.";
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
        if ($current_sitename ne 'CSC') {
            # Show pages belonging to this site OR pages shared with this site
            $search_cond{'-or'} = [
                { sitename => $current_sitename },
                { share_with => 'all' },
                { share_with => { 'like' => "%$current_sitename%" } }
            ];
            if ($search) {
                $search_cond{'-and'} = [
                    { '-or' => delete $search_cond{'-or'} },
                    { '-or' => [
                        { title     => { like => "%$search%" } },
                        { page_code => { like => "%$search%" } }
                    ]}
                ];
            }
        } else {
            # CSC admin - can filter by site
            if ($filter_site) {
                $search_cond{sitename} = $filter_site;
            }
            if ($search) {
                $search_cond{'-or'} = [
                    { title     => { like => "%$search%" } },
                    { page_code => { like => "%$search%" } },
                ];
            }
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
            pages            => \@pages,
            site_names       => \@site_names,
            site_display_map => $c->stash->{site_display_map},
            search           => $search,
            filter_site      => $current_sitename ne 'CSC' ? $current_sitename : $filter_site,
            filter_status    => $filter_status,
        );
    }
    
    $c->stash(
        template => 'admin/pages.tt',
        success_msg => $c->flash->{success_msg} || $c->stash->{success_msg},
        error_msg => $c->flash->{error_msg} || $c->stash->{error_msg},
        current_site  => $current_sitename,
        page_title => 'Page Management',
        ScriptDisplayName => 'Admin',
    );
}

__PACKAGE__->meta->make_immutable;

1;
