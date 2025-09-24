package Comserv::Controller::Documentation;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;
use Comserv::Controller::Documentation::ScanMethods qw(_scan_directories _categorize_pages);
use File::Find;
use File::Basename;
use File::Spec;
use FindBin;
use Time::Piece;
use URI::Escape;
use JSON;

BEGIN { extends 'Catalyst::Controller'; }

# Set the namespace to handle both /Documentation and /documentation routes
__PACKAGE__->config(namespace => 'Documentation');

# Add a chained action to handle the lowercase route
sub documentation_base :Chained('/') :PathPart('documentation') :CaptureArgs(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'documentation_base',
        "Captured lowercase documentation route");
}

# Handle the lowercase index route
sub documentation_index :Chained('documentation_base') :PathPart('') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'documentation_index',
        "Handling lowercase documentation index route");
    $c->forward('index');
}

# Handle the lowercase view route with a page parameter
sub documentation_view :Chained('documentation_base') :PathPart('') :Args(1) {
    my ($self, $c, $page) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'documentation_view',
        "Handling lowercase documentation view route for page: $page");
    $c->forward('view', [$page]);
}

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

has 'documentation_config' => (
    is => 'ro',
    default => sub { Comserv::Util::DocumentationConfig->instance }
);

# Store documentation pages with metadata
has 'documentation_pages' => (
    is => 'ro',
    default => sub { {} },
    lazy => 1,
);

# Store documentation categories - now loaded from config
has 'documentation_categories' => (
    is => 'ro',
    default => sub { {} },
    lazy => 1,
);

# Initialize - scan filesystem for documentation files
sub BUILD {
    my ($self) = @_;
    my $logger = $self->logging;

    Comserv::Util::Logging::log_to_file("Starting Documentation controller initialization");

    # Initialize default categories
    %{$self->documentation_categories} = (
        'user_guides' => {
            title => 'User Guides',
            description => 'Documentation for end users of the system',
            icon => 'fas fa-users',
            roles => ['normal', 'editor', 'admin', 'developer'],
            pages => []
        },
        'admin_guides' => {
            title => 'Administrator Guides',
            description => 'Documentation for system administrators',
            icon => 'fas fa-shield-alt',
            roles => ['admin', 'developer'],
            pages => []
        },
        'developer_guides' => {
            title => 'Developer Documentation',
            description => 'Documentation for developers',
            icon => 'fas fa-code',
            roles => ['developer'],
            pages => []
        },
        'tutorials' => {
            title => 'Tutorials',
            description => 'Step-by-step tutorials and guides',
            icon => 'fas fa-graduation-cap',
            roles => ['normal', 'editor', 'admin', 'developer'],
            pages => []
        },
        'modules' => {
            title => 'Module Documentation',
            description => 'Documentation for system modules',
            icon => 'fas fa-puzzle-piece',
            roles => ['developer', 'admin'],
            pages => []
        },
        'site_specific' => {
            title => 'Site-Specific Documentation',
            description => 'Documentation specific to individual sites',
            icon => 'fas fa-building',
            roles => ['admin', 'developer'],
            pages => []
        }
    );

    # Note: File scanning will be done on first request since we need Catalyst context
    # for proper logging. The _scan_directories and _categorize_pages methods will be
    # called from the index method when needed.

    Comserv::Util::Logging::log_to_file(sprintf("Documentation system initialized with %d categories and %d pages",
        scalar keys %{$self->documentation_categories},
        scalar keys %{$self->documentation_pages}));
}

sub auto :Private {
    my ($self, $c) = @_;

    # Get the current action
    my $action = $c->action->name;

    # Get the path from the request
    my $path = $c->req->path;

    # If the path starts with 'documentation/' and isn't a known action
    if ($path =~ m{^documentation/(.+)$} &&
        $action ne 'index' &&
        $action ne 'view' &&
        !$c->controller('Documentation')->action_for($action)) {

        my $page = $1;

        # Log the action
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto',
            "Redirecting documentation request to view action: $page");

        # Forward to the view action with the page name
        $c->forward('view', [$page]);
        return 0; # Skip further processing
    }

    return 1; # Continue processing
}

# Main documentation index - handles /Documentation route
sub index :Path('/Documentation') :Args(0) {
    my ($self, $c) = @_;

    # Log the action
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Accessing documentation index");
    
    # Ensure documentation has been scanned
    $self->_ensure_scanned($c);

    # Get the current user's role
    my $user_role = 'normal';  # Default to normal user
    my $is_admin = 0;  # Flag to track if user has admin role
    
    # Use Root controller to check if user exists
    my $root_controller = $c->controller('Root');

    # If user exists, determine their role properly
    if ($root_controller->user_exists($c)) {
        # Check for admin role first using the Root controller's method
        if ($root_controller->check_user_roles($c, 'admin')) {
            $user_role = 'admin';
            $is_admin = 1;
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'index',
                "Admin role confirmed via Root controller");
        }
        # Check for developer role
        elsif ($root_controller->check_user_roles($c, 'developer')) {
            $user_role = 'developer';
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'index',
                "Developer role confirmed via Root controller");
        }
        # For other users, check session roles but don't override admin/developer
        else {
            if ($c->session->{roles}) {
                my $roles = $c->session->{roles};
                if (ref($roles) eq 'ARRAY' && @{$roles}) {
                    # Use the first non-empty role
                    $user_role = $roles->[0];
                    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'index',
                        "Role from session array: $user_role");
                } elsif (!ref($roles) && $roles ne '' && $roles ne 'none') {
                    # Handle string roles
                    $user_role = $roles;
                    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'index',
                        "Role from session string: $user_role");
                }
            }
        }
        
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'index',
            "User role determined: $user_role, is_admin: $is_admin");
    } else {
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'index',
            "User does not exist, using default role: $user_role");
    }
    
    # Special case for site CSC - ensure admin role is recognized
    if ($c->stash->{SiteName} && $c->stash->{SiteName} eq 'CSC') {
        # Check if user should have admin privileges on this site
        if ($c->session->{username} && ($c->session->{username} eq 'Shanta' || $c->session->{username} eq 'admin')) {
            $user_role = 'admin';
            $is_admin = 1;
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', 
                "Admin role granted for CSC site user: " . $c->session->{username});
        }
    }

    # Log the final role determination
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
        "Final user role determined: $user_role");

    # Get the current site name
    my $site_name = $c->stash->{SiteName} || 'default';

    # Log user role and site for debugging
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
        "User role: $user_role, Site: $site_name");

    # Log session roles for debugging
    if ($c->session->{roles} && ref $c->session->{roles} eq 'ARRAY') {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
            "Session roles: " . join(", ", @{$c->session->{roles}}));
    }

    # Get all documentation pages
    my $pages = $self->documentation_pages;

    # Filter pages based on user role and site
    my %filtered_pages;
    foreach my $page_name (keys %$pages) {
        my $metadata = $pages->{$page_name};

        # Log the admin status for debugging
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'index',
            "Processing page $page_name, is_admin: $is_admin");

        # Skip if this is site-specific documentation for a different site
        # But allow admins to see all site-specific documentation
        if ($metadata->{site} ne 'all' && $metadata->{site} ne $site_name) {
            # Only skip for non-admins
            next unless $is_admin;
        }

        # Skip if the user doesn't have the required role
        # But always include for admins
        my $has_role = $is_admin; # Admins can see everything

        # Debug log for admin status
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'index',
            "Admin check for $page_name: is_admin=$is_admin, user_role=$user_role");

        unless ($has_role) {
            foreach my $role (@{$metadata->{roles}}) {
                # Check if role matches user_role
                if ($role eq $user_role) {
                    $has_role = 1;
                    last;
                }
                # Check session roles
                elsif ($c->session->{roles} && ref $c->session->{roles} eq 'ARRAY') {
                    if (grep { $_ eq $role } @{$c->session->{roles}}) {
                        $has_role = 1;
                        last;
                    }
                }
                # Special case for normal role - any authenticated user can access normal content
                elsif ($role eq 'normal' && $user_role) {
                    $has_role = 1;
                    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'index',
                        "Normal role access granted for user with role $user_role");
                    last;
                }
            }
        }
        
        # Log access decision
        if (!$has_role) {
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'index',
                "Access denied to page $page_name for user with role $user_role");
        }
        
        next unless $has_role;

        # Add to filtered pages
        $filtered_pages{$page_name} = $metadata;

        # Log access granted
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'index',
            "Access granted to $page_name for user with role $user_role");
    }

    # Sort pages alphabetically by title for better presentation
    my @sorted_pages = sort {
        lc($self->_format_title($a)) cmp lc($self->_format_title($b))
    } keys %filtered_pages;

    # Create a structured list of documentation pages with metadata
    my $structured_pages = {};
    foreach my $page_name (@sorted_pages) {
        my $metadata = $filtered_pages{$page_name};
        my $path = $metadata->{path};
        my $title = $self->_format_title($page_name);

        # Always use the view action with the page name as parameter
        my $url = $c->uri_for($self->action_for('view'), [$page_name]);

        $structured_pages->{$page_name} = {
            title => $title,
            path => $path,
            url => $url,
            site => $metadata->{site},
            roles => $metadata->{roles},
            file_type => $metadata->{format} || 'other',
            description => $metadata->{description} || 'Documentation file.',
        };
    }

    # Set up stash variables for the template
    $c->stash(
        template => 'Documentation.tt',
        pages => $structured_pages,
        sorted_pages => \@sorted_pages,
        user_role => $user_role,
        is_admin => $is_admin,
        site_name => $site_name,
        page_count => scalar @sorted_pages,
    );

    # Log successful completion
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
        sprintf("Documentation index loaded with %d pages for user role %s",
            scalar @sorted_pages, $user_role));
}

# Handle view for both uppercase and lowercase routes
sub view :Path('/Documentation') :Args(1) {
    my ($self, $c, $page) = @_;

    # Log the action
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view', "Accessing documentation page: $page");
    
    # Ensure documentation has been scanned
    $self->_ensure_scanned($c);

    # Get the current user's role
    my $user_role = 'normal';  # Default to normal user
    my $is_admin = 0;  # Flag to track if user has admin role
    
    # Use Root controller to check if user exists
    my $root_controller = $c->controller('Root');

    # If user exists, determine their role properly
    if ($root_controller->user_exists($c)) {
        # Check for admin role first using the Root controller's method
        if ($root_controller->check_user_roles($c, 'admin')) {
            $user_role = 'admin';
            $is_admin = 1;
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'view',
                "Admin role confirmed via Root controller");
        }
        # Check for developer role
        elsif ($root_controller->check_user_roles($c, 'developer')) {
            $user_role = 'developer';
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'view',
                "Developer role confirmed via Root controller");
        }
        # For other users, check session roles but don't override admin/developer
        else {
            if ($c->session->{roles}) {
                my $roles = $c->session->{roles};
                if (ref($roles) eq 'ARRAY' && @{$roles}) {
                    # Use the first non-empty role
                    $user_role = $roles->[0];
                    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'view',
                        "Role from session array: $user_role");
                } elsif (!ref($roles) && $roles ne '' && $roles ne 'none') {
                    # Handle string roles
                    $user_role = $roles;
                    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'view',
                        "Role from session string: $user_role");
                }
            }
        }
        
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'view',
            "User role determined: $user_role, is_admin: $is_admin");
    } else {
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'view',
            "User does not exist, using default role: $user_role");
    }
    
    # Special case for site CSC - ensure admin role is recognized
    if ($c->stash->{SiteName} && $c->stash->{SiteName} eq 'CSC') {
        # Check if user should have admin privileges on this site
        if ($c->session->{username} && ($c->session->{username} eq 'Shanta' || $c->session->{username} eq 'admin')) {
            $user_role = 'admin';
            $is_admin = 1;
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view', 
                "Admin role granted for CSC site user: " . $c->session->{username});
        }
    }

    # Get the current site name
    my $site_name = $c->stash->{SiteName} || 'default';

    # Log user role and site for debugging
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view',
        "User role: $user_role, Site: $site_name, Page: $page");

    # Get all documentation pages
    my $pages = $self->documentation_pages;

    # Check if the requested page exists and user has access
    if (exists $pages->{$page}) {
        my $metadata = $pages->{$page};

        # Check site access
        if ($metadata->{site} ne 'all' && $metadata->{site} ne $site_name && !$is_admin) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'view',
                "Access denied to page $page: site mismatch ($metadata->{site} vs $site_name)");
            $c->response->status(403);
            $c->stash(
                error_msg => "Access denied: This documentation is not available for your site.",
                template => 'Documentation/error.tt'
            );
            return;
        }

        # Check role access
        my $has_role = $is_admin; # Admins can see everything
        unless ($has_role) {
            foreach my $role (@{$metadata->{roles}}) {
                if ($role eq $user_role || 
                    ($c->session->{roles} && ref $c->session->{roles} eq 'ARRAY' && grep { $_ eq $role } @{$c->session->{roles}}) ||
                    ($role eq 'normal' && $user_role)) {
                    $has_role = 1;
                    last;
                }
            }
        }

        unless ($has_role) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'view',
                "Access denied to page $page: insufficient role ($user_role)");
            $c->response->status(403);
            $c->stash(
                error_msg => "Access denied: You don't have permission to view this documentation.",
                template => 'Documentation/error.tt'
            );
            return;
        }

        # User has access, now try to load the content
        my $path = $metadata->{path};
        my $full_path = $c->path_to('root', $path);

        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'view',
            "Attempting to load file: $full_path");

        if (-e $full_path) {
            # Handle different file types
            if ($path =~ /\.md$/i) {
                # Read the markdown file
                open my $fh, '<:encoding(UTF-8)', $full_path or die "Cannot open $full_path: $!";
                my $content = do { local $/; <$fh> };
                close $fh;

                # Get file modification time
                my $mtime = (stat($full_path))[9];
                my $last_updated = localtime($mtime);
                $last_updated = $last_updated->strftime('%Y-%m-%d %H:%M:%S');

                # Pass the content to the markdown viewer template
                my $stash_data = {
                    page_name => $page,
                    page_id => $page,  # Add page_id for Edit Roles button
                    page_title => $metadata->{title} || $self->_format_title($page),
                    markdown_content => $content,
                    last_updated => $last_updated,
                    user_role => $user_role,
                    site_name => $site_name,
                    template => 'Documentation/markdown_viewer.tt'
                };
                
                # Add special CSS and JavaScript for Linux commands documentation
                if ($page eq 'linux_commands') {
                    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view',
                        "Loading special CSS and JS for Linux commands documentation");
                    
                    $stash_data->{additional_css} = ['/static/css/linux_commands.css'];
                    $stash_data->{additional_js} = ['/static/js/linux_commands.js'];
                }
                
                $c->stash(%$stash_data);
                return;
            }
            elsif ($path =~ /\.tt$/i) {
                # Handle template files
                $c->stash(
                    page_name => $page,
                    page_id => $page,  # Add page_id for Edit Roles button
                    page_title => $metadata->{title} || $self->_format_title($page),
                    user_role => $user_role,
                    site_name => $site_name,
                    template => $path
                );
                return;
            }
            else {
                # Handle other file types (images, PDFs, etc.)
                my $content_type = 'text/plain';
                if ($page =~ /\.html?$/i) {
                    $content_type = 'text/html';
                } elsif ($page =~ /\.pdf$/i) {
                    $content_type = 'application/pdf';
                } elsif ($page =~ /\.(jpe?g|png|gif)$/i) {
                    $content_type = 'image/' . lc($1);
                }

                # Read the file - binary mode for all files to be safe
                open my $fh, '<:raw', $full_path or die "Cannot open $full_path: $!";
                my $content = do { local $/; <$fh> };
                close $fh;

                # Set the response
                $c->response->content_type($content_type);
                $c->response->body($content);
                return;
            }
        }
    }

    # If we get here, the page wasn't found in config or file doesn't exist
    # Try to find it as a template file first (priority), then markdown file in the Documentation directory
    my $tt_path = "Documentation/$page.tt";
    my $tt_full_path = $c->path_to('root', $tt_path);
    
    if (-e $tt_full_path) {
        # Handle template file
        $c->stash(
            page_name => $page,
            page_id => $page,  # Add page_id for Edit Roles button
            page_title => $self->_format_title($page),
            user_role => $user_role,
            site_name => $site_name,
            template => $tt_path
        );
        return;
    }
    
    # If no .tt file found, try to find it as a markdown file
    my $md_path = "Documentation/$page.md";
    my $md_full_path = $c->path_to('root', $md_path);

    if (-e $md_full_path) {
        # Read the markdown file
        open my $fh, '<:encoding(UTF-8)', $md_full_path or die "Cannot open $md_full_path: $!";
        my $content = do { local $/; <$fh> };
        close $fh;

        # Get file modification time
        my $mtime = (stat($md_full_path))[9];
        my $last_updated = localtime($mtime);
        $last_updated = $last_updated->strftime('%Y-%m-%d %H:%M:%S');

        # Pass the content to the markdown viewer template
        my $stash_data = {
            page_name => $page,
            page_id => $page,  # Add page_id for Edit Roles button
            page_title => $self->_format_title($page),
            markdown_content => $content,
            last_updated => $last_updated,
            user_role => $user_role,
            site_name => $site_name,
            template => 'Documentation/markdown_viewer.tt'
        };
        
        # Add special CSS and JavaScript for Linux commands documentation
        if ($page eq 'linux_commands') {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view',
                "Loading special CSS and JS for Linux commands documentation");
            
            $stash_data->{additional_css} = ['/static/css/linux_commands.css'];
            $stash_data->{additional_js} = ['/static/js/linux_commands.js'];
        }
        
        $c->stash(%$stash_data);
        return;
    }

    # Page not found - provide detailed debugging information
    my $debug_info = "Debugging Information:\n";
    $debug_info .= "1. Checked JSON config for page '$page': NOT FOUND\n";
    $debug_info .= "2. Checked fallback Template Toolkit file: Documentation/$page.tt: " . 
                   (-e $c->path_to('root', "Documentation/$page.tt") ? "EXISTS" : "NOT FOUND") . "\n";
    $debug_info .= "3. Checked fallback Markdown file: Documentation/$page.md: " . 
                   (-e $c->path_to('root', "Documentation/$page.md") ? "EXISTS" : "NOT FOUND") . "\n";

    # Check if it might be a nested path issue
    if ($page =~ m{^(.+)/([^/]+)$}) {
        my ($dir, $filename) = ($1, $2);
        $debug_info .= "4. Detected nested path - checking alternate locations:\n";
        $debug_info .= "   - Documentation/$dir/$filename.tt: " . 
                       (-e $c->path_to('root', "Documentation/$dir/$filename.tt") ? "EXISTS" : "NOT FOUND") . "\n";
        $debug_info .= "   - Documentation/$dir/$filename.md: " . 
                       (-e $c->path_to('root', "Documentation/$dir/$filename.md") ? "EXISTS" : "NOT FOUND") . "\n";
    }
    
    $debug_info .= "\nTo fix this issue:\n";
    $debug_info .= "1. Add the page entry to documentation_config.json under appropriate category\n";
    $debug_info .= "2. Add the path mapping in 'default_paths' section of documentation_config.json\n";
    $debug_info .= "3. Ensure the file exists at the specified path\n";

    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'view',
        "Documentation page not found: $page\n$debug_info");
    
    $c->response->status(404);
    $c->stash(
        error_msg => "Documentation page '$page' not found.",
        debug_info => $debug_info,
        page_name => $page,
        template => 'Documentation/error.tt'
    );
}

# Ensure documentation scanning has been done
sub _ensure_scanned {
    my ($self, $c) = @_;
    
    # Check if we've already scanned (pages will be empty initially)
    return if keys %{$self->documentation_pages} > 0;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_ensure_scanned',
        "Performing initial documentation scan");
    
    # Import and call the scanning functions
    _scan_directories($self, $c);
    _categorize_pages($self, $c);
}

# Handle role editing for documentation files
sub edit_roles :Path('/Documentation/edit_roles') :Args {
    my ($self, $c, @path_segments) = @_;
    
    # Join all path segments to reconstruct the full page name
    my $page_name = join('/', @path_segments);
    
    # Decode URL-encoded page name (handles page names with forward slashes)
    $page_name = uri_unescape($page_name) if $page_name;
    
    # The page_name is already the original page name with forward slashes
    my $original_page_name = $page_name;

    # Log the action
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_roles', 
        "Accessing role editor for page: $page_name");

    # Check if user has admin privileges
    my $is_admin = 0;
    my $is_csc_admin = 0;
    my $user_role = 'normal';
    
    # Check session roles first (this works even without user_exists)
    if ($c->session->{roles} && ref $c->session->{roles} eq 'ARRAY') {
        if (grep { lc($_) eq 'admin' } @{$c->session->{roles}}) {
            $is_admin = 1;
            $user_role = 'admin';
        }
    }
    
    # Check if user is CSC admin based on session SiteName (similar to CloudflareAPI)
    my $user_sitename = $c->session->{SiteName} || $c->stash->{SiteName} || '';
    if ($user_sitename eq 'CSC') {
        $is_csc_admin = 1;
        $is_admin = 1;  # CSC admins are always admins
        $user_role = 'csc_admin';
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_roles',
            "CSC admin access granted for user: " . ($c->session->{username} || 'unknown'));
    }
    
    # Additional check for authenticated users
    if ($c->user_exists) {
        # Special case for CSC site admin users (legacy check)
        if ($c->stash->{SiteName} && $c->stash->{SiteName} eq 'CSC') {
            if ($c->session->{username} && ($c->session->{username} eq 'Shanta' || $c->session->{username} eq 'admin')) {
                $is_admin = 1;
                $is_csc_admin = 1;
                $user_role = 'csc_admin';
            }
        }
    }

    # Only allow admins to edit roles
    unless ($is_admin) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'edit_roles',
            "Access denied to role editor for non-admin user");
        $c->response->status(403);
        $c->stash(
            error_msg => "Access denied. Role editing requires administrator privileges.",
            template => 'Documentation/error.tt'
        );
        return;
    }

    # Ensure documentation has been scanned
    $self->_ensure_scanned($c);

    # Get the page metadata using original page name (with slashes)
    my $pages = $self->documentation_pages;
    
    # Debug: Log what keys exist and what we're looking for
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_roles',
        "Looking for page key: '$original_page_name'. Available keys: " . join(', ', sort keys %$pages));
    
    if (!exists $pages->{$original_page_name}) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'edit_roles',
            "Documentation page not found for role editing: $original_page_name. Offering to create new entry.");
        
        # Check if this is a form submission to create the new page entry
        if ($c->request->method eq 'POST' && $c->request->param('action') eq 'create_page_entry') {
            my @new_roles = $c->request->param('roles');
            my $site = $c->request->param('site') || 'all';
            my $description = $c->request->param('description') || 'Documentation page';
            
            # Create the new page entry in memory
            $pages->{$original_page_name} = {
                path => "Documentation/$original_page_name.md",
                site => $site,
                roles => \@new_roles,
                format => 'markdown',
                description => $description
            };
            
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_roles',
                "Created new page entry for $original_page_name with roles: " . join(', ', @new_roles));
            
            # Redirect to the edit roles form for the newly created entry
            $c->response->redirect($c->uri_for($self->action_for('edit_roles'), [$page_name]));
            return;
        }
        
        # Show form to create new page entry
        $c->stash(
            template => 'admin/documentation/create_page_entry.tt',
            page_name => $original_page_name,
            url_page_name => $page_name,
            available_roles => ['normal', 'editor', 'admin', 'developer'],
            available_sites => ['all', 'CSC', 'mcoop'], # This could be made dynamic
            suggested_description => $self->_generate_description_from_filename($original_page_name),
            suggested_roles => $self->_suggest_roles_from_path($original_page_name),
            suggested_site => $self->_suggest_site_from_path($original_page_name)
        );
        return;
    }

    my $page_metadata = $pages->{$original_page_name};

    # Handle form submission
    if ($c->request->method eq 'POST') {
        my @new_roles = $c->request->param('roles');
        
        # Log the role update attempt
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_roles',
            "Updating roles for $page_name: " . join(', ', @new_roles));

        # Update the roles in memory for current session
        $page_metadata->{roles} = \@new_roles;
        
        # Handle additional fields for CSC admin users
        my %additional_updates = ();
        if ($is_csc_admin) {
            # Get additional form fields that CSC admins can modify
            my $title = $c->request->param('title');
            my $description = $c->request->param('description');
            my $path = $c->request->param('path');
            my $format = $c->request->param('format');
            my $site = $c->request->param('site');
            my @categories = $c->request->param('categories');
            
            # Store updates to apply to JSON config
            $additional_updates{title} = $title if defined $title && $title ne '';
            $additional_updates{description} = $description if defined $description && $description ne '';
            $additional_updates{path} = $path if defined $path && $path ne '';
            $additional_updates{format} = $format if defined $format && $format ne '';
            $additional_updates{site} = $site if defined $site && $site ne '';
            $additional_updates{categories} = \@categories if @categories;
            
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_roles',
                "CSC admin updating additional fields: " . join(', ', keys %additional_updates));
        }
        
        # Persist changes to documentation configuration JSON file
        my $doc_config = $self->documentation_config;
        my $save_success = 0;
        
        # Try to find matching entry in JSON config by path or id
        my $pages = $doc_config->get_pages();
        my $config_updated = 0;
        
        foreach my $page (@$pages) {
            # Check if this page matches by different possible identifiers
            my $matches = 0;
            
            # Match by id (if page_name maps to id somehow)
            if ($page->{id} && ($page->{id} eq $page_name || $page->{id} eq $original_page_name)) {
                $matches = 1;
            }
            # Match by path containing the page name
            elsif ($page->{path} && ($page->{path} =~ /\Q$page_name\E/ || $page->{path} =~ /\Q$original_page_name\E/)) {
                $matches = 1;
            }
            # Match by derived page name from path
            elsif ($page->{path}) {
                my $derived_name = $page->{path};
                $derived_name =~ s/^Documentation\///;  # Remove Documentation/ prefix
                $derived_name =~ s/\.(md|tt)$//;       # Remove file extension
                if ($derived_name eq $page_name || $derived_name eq $original_page_name) {
                    $matches = 1;
                }
            }
            
            if ($matches) {
                # Always update roles
                $page->{roles} = \@new_roles;
                
                # Update additional fields for CSC admin
                if ($is_csc_admin) {
                    foreach my $field (keys %additional_updates) {
                        $page->{$field} = $additional_updates{$field};
                    }
                }
                
                $config_updated = 1;
                
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_roles',
                    "Updated JSON config entry for page ID: $page->{id}, path: $page->{path}");
                last;
            }
        }
        
        if ($config_updated) {
            # Save the updated configuration
            $save_success = $doc_config->save_config();
            
            if ($save_success) {
                # Get a fresh instance to ensure we're working with updated data
                # The save_config() method clears the singleton, so next instance() call gets fresh data
                $doc_config = Comserv::Util::DocumentationConfig->instance();
                
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_roles',
                    "Successfully saved role changes to documentation_config.json");
            } else {
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'edit_roles',
                    "Failed to save role changes to documentation_config.json");
            }
        } else {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'edit_roles',
                "No matching entry found in JSON config for page: $page_name");
        }
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_roles',
            "Role update completed for $page_name. New roles: " . join(', ', @new_roles) . 
            " (Saved to JSON: " . ($save_success ? "Yes" : "No") . ")");

        # Redirect back to documentation index
        $c->response->redirect($c->uri_for('/Documentation'));
        return;
    }

    # Set up stash for the role editing template
    my $stash_data = {
        template => 'admin/documentation/edit_file_access.tt',
        page_name => $page_name,
        page_title => $self->_format_title($page_name),
        page_metadata => $page_metadata,
        current_roles => $page_metadata->{roles} || [],
        available_roles => ['normal', 'editor', 'admin', 'developer'],
        user_role => $user_role,
        is_admin => $is_admin,
        is_csc_admin => $is_csc_admin,
    };
    
    # Add additional data for CSC admin users
    if ($is_csc_admin) {
        $stash_data->{current_title} = $page_metadata->{title} || $self->_format_title($page_name);
        $stash_data->{current_description} = $page_metadata->{description} || '';
        $stash_data->{current_path} = $page_metadata->{path} || "Documentation/$page_name.md";
        $stash_data->{current_format} = $page_metadata->{format} || 'markdown';
        $stash_data->{current_site} = $page_metadata->{site} || 'all';
        $stash_data->{current_categories} = $page_metadata->{categories} || [];
        
        # Get available categories from config
        my $doc_config = $self->documentation_config;
        my $categories_config = $doc_config->get_categories();
        $stash_data->{available_categories} = [sort keys %$categories_config];
    }
    
    $c->stash($stash_data);
}

# Helper method to format titles
sub _format_title {
    my ($self, $name) = @_;
    
    # Remove file extensions
    $name =~ s/\.(md|tt|html?)$//i;
    
    # Replace underscores and hyphens with spaces
    $name =~ s/[_-]/ /g;
    
    # Capitalize each word
    $name =~ s/\b(\w)/uc($1)/ge;
    
    return $name;
}

# Helper methods for creating new page entries

# Generate a human-readable description from filename
sub _generate_description_from_filename {
    my ($self, $filename) = @_;
    
    # Remove path and extension
    my $name = $filename;
    $name =~ s{^.*/}{};  # Remove path
    $name =~ s/\.[^.]+$//;  # Remove extension
    
    # Convert underscores and dashes to spaces
    $name =~ s/[_-]+/ /g;
    
    # Capitalize words
    $name = join(' ', map { ucfirst(lc($_)) } split(/\s+/, $name));
    
    return $name . " documentation";
}

# Suggest roles based on file path
sub _suggest_roles_from_path {
    my ($self, $path) = @_;
    
    # Default roles
    my @roles = ('normal', 'editor', 'admin', 'developer');
    
    # Admin-only paths
    if ($path =~ m{/(admin|system|proxmox|cloudflare|session_history)/} ||
        $path =~ m{/(controllers|models)/}) {
        @roles = ('admin', 'developer');
    }
    # Developer-only paths
    elsif ($path =~ m{/(developer|api|changelog)/}) {
        @roles = ('developer');
    }
    # Editor and up
    elsif ($path =~ m{/(editor)/}) {
        @roles = ('editor', 'admin', 'developer');
    }
    
    return \@roles;
}

# Suggest site based on file path
sub _suggest_site_from_path {
    my ($self, $path) = @_;
    
    # Check for site-specific paths
    if ($path =~ m{/sites/([^/]+)/}) {
        return uc($1);  # Return uppercase site name
    }
    
    return 'all';  # Default to all sites
}

# Method to detect new files that aren't in the config
sub check_for_new_files :Local {
    my ($self, $c) = @_;
    
    # Log the action
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'check_for_new_files',
        "Checking for new documentation files not in config");

    # Ensure admin access
    my $root_controller = $c->controller('Root');
    unless ($root_controller->user_exists($c) && $root_controller->check_user_roles($c, 'admin')) {
        $c->stash(error => 'Admin access required');
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }

    # Get current config to check existing files
    my $config_path = $c->path_to('config', 'documentation_config.json');
    my $config_content;
    
    if (-f $config_path) {
        open(my $fh, '<', $config_path) or die "Cannot read config file: $!";
        $config_content = do { local $/; <$fh> };
        close($fh);
    }
    
    my $config;
    eval { $config = JSON::decode_json($config_content); };
    if ($@) {
        $c->stash(error => "Failed to parse documentation config: $@");
        $c->detach('index');
        return;
    }
    
    # Create a hash of existing files in config for quick lookup
    my %existing_files;
    foreach my $page (@{$config->{pages} || []}) {
        $existing_files{$page->{path}} = 1;
    }
    
    # Scan for documentation files
    my $doc_root = $c->path_to('root', 'Documentation');
    my @new_files;
    
    File::Find::find(sub {
        my $file = $File::Find::name;
        return unless -f $file;
        return unless /\.(md|tt)$/i;
        
        # Convert to relative path from Documentation root
        my $rel_path = File::Spec->abs2rel($file, $c->path_to('root'));
        
        # Skip if already in config
        return if $existing_files{$rel_path};
        
        # Skip certain directories/files
        return if $rel_path =~ m{/(\.git|tmp|cache)/};
        return if basename($file) =~ /^(README|CHANGELOG|LICENSE)/i;
        
        push @new_files, {
            path => $rel_path,
            full_path => $file,
            title => $self->_suggest_title_from_filename(basename($file)),
            suggested_roles => $self->_suggest_roles_from_path($rel_path),
            suggested_categories => $self->_suggest_categories_from_path($rel_path),
            format => ($file =~ /\.tt$/i) ? 'template' : 'markdown'
        };
        
    }, $doc_root);
    
    $c->stash(
        template => 'admin/documentation/new_files.tt',
        new_files => \@new_files,
        config_categories => $config->{categories} || {}
    );
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'check_for_new_files',
        "Found " . scalar(@new_files) . " new files not in config");
}

# Method to add a new file to the config
sub add_file :Local {
    my ($self, $c) = @_;
    
    # Ensure admin access
    my $root_controller = $c->controller('Root');
    unless ($root_controller->user_exists($c) && $root_controller->check_user_roles($c, 'admin')) {
        $c->stash(error => 'Admin access required');
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }
    
    if ($c->request->method eq 'POST') {
        # Get form data
        my $params = $c->request->params;
        
        # Validate required fields
        unless ($params->{id} && $params->{title} && $params->{path}) {
            $c->stash(error => 'Missing required fields: id, title, or path');
            $c->response->redirect($c->uri_for($self->action_for('check_for_new_files')));
            return;
        }
        
        # Load current config
        my $config_path = $c->path_to('config', 'documentation_config.json');
        my $config_content;
        
        if (-f $config_path) {
            open(my $fh, '<', $config_path) or die "Cannot read config file: $!";
            $config_content = do { local $/; <$fh> };
            close($fh);
        }
        
        my $config;
        eval { $config = JSON::decode_json($config_content); };
        if ($@) {
            $c->stash(error => "Failed to parse documentation config: $@");
            $c->response->redirect($c->uri_for($self->action_for('check_for_new_files')));
            return;
        }
        
        # Parse roles and categories from form
        my @roles = ref $params->{roles} ? @{$params->{roles}} : ($params->{roles});
        my @categories = ref $params->{categories} ? @{$params->{categories}} : ($params->{categories});
        
        # Create new page entry
        my $new_page = {
            id => $params->{id},
            title => $params->{title},
            path => $params->{path},
            description => $params->{description} || 'Documentation file',
            format => $params->{format} || 'markdown',
            roles => \@roles,
            categories => \@categories,
            site => $params->{site} || 'all'
        };
        
        # Add to config
        push @{$config->{pages}}, $new_page;
        
        # Write back to config file
        my $json = JSON->new->pretty->encode($config);
        
        open(my $fh, '>', $config_path) or die "Cannot write config file: $!";
        print $fh $json;
        close($fh);
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_file',
            "Added new file to config: " . $params->{path});
        
        $c->stash(success => "File added to documentation system successfully");
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }
    
    # Show add form
    $c->response->redirect($c->uri_for($self->action_for('check_for_new_files')));
}

# Suggest categories based on file path
sub _suggest_categories_from_path {
    my ($self, $path) = @_;
    
    my @categories;
    
    if ($path =~ m{/admin/}) {
        push @categories, 'admin_guides';
    }
    if ($path =~ m{/(developer|controllers|models)/}) {
        push @categories, 'developer_guides';
    }
    if ($path =~ m{/system/}) {
        push @categories, 'system_management';
    }
    if ($path =~ m{/proxmox/}) {
        push @categories, 'proxmox';
    }
    if ($path =~ m{/changelog/}) {
        push @categories, 'changelog';
    }
    if ($path =~ m{/tutorial/}) {
        push @categories, 'user_guides';
    }
    
    # Default to user_guides if no specific category found
    unless (@categories) {
        @categories = ('user_guides');
    }
    
    return \@categories;
}

__PACKAGE__->meta->make_immutable;

1;