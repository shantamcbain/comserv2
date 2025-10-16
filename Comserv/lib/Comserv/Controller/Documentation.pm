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

    # Load categories from JSON configuration
    $self->_load_categories_from_config();

    # Note: File scanning will be done on first request since we need Catalyst context
    # for proper logging. The _scan_directories and _categorize_pages methods will be
    # called from the index method when needed.

    Comserv::Util::Logging::log_to_file(sprintf("Documentation system initialized with %d categories and %d pages",
        scalar keys %{$self->documentation_categories},
        scalar keys %{$self->documentation_pages}));
}

# Load categories from JSON configuration file
sub _load_categories_from_config {
    my ($self) = @_;
    
    # Path to the JSON config file
    my $config_file = $FindBin::Bin . '/../root/Documentation/config/documentation_config.json';
    
    # Initialize with empty hash
    %{$self->documentation_categories} = ();
    
    if (-f $config_file) {
        eval {
            # Read and parse JSON config
            open my $fh, '<', $config_file or die "Cannot open config file: $!";
            my $json_content = do { local $/; <$fh> };
            close $fh;
            
            my $config = JSON->new->decode($json_content);
            
            if ($config->{categories}) {
                # Convert JSON categories to internal format
                foreach my $category_key (keys %{$config->{categories}}) {
                    my $category = $config->{categories}{$category_key};
                    
                    # Use roles from JSON if provided, otherwise set default roles based on category type
                    my @roles;
                    if ($category->{roles} && ref $category->{roles} eq 'ARRAY') {
                        @roles = @{$category->{roles}};
                    } else {
                        # Fallback to default role assignment based on category name
                        if ($category_key =~ /admin/) {
                            @roles = ('admin', 'developer');
                        } elsif ($category_key =~ /developer/) {
                            @roles = ('developer');
                        } elsif ($category_key =~ /user/) {
                            @roles = ('normal', 'editor', 'admin', 'developer');
                        } else {
                            @roles = ('admin', 'developer');  # Safe default
                        }
                    }
                    
                    $self->documentation_categories->{$category_key} = {
                        title => $category->{title} || ucfirst($category_key),
                        description => $category->{description} || "Documentation for $category_key",
                        icon => $category->{icon} || 'fas fa-file-alt',
                        display_order => $category->{display_order} || 999,
                        roles => \@roles,
                        site_filter => $category->{site_filter} || 'all',
                        pages => []
                    };
                }
                
                Comserv::Util::Logging::log_to_file(sprintf("Loaded %d categories from JSON config", 
                    scalar keys %{$self->documentation_categories}));
            }
        };
        
        if ($@) {
            Comserv::Util::Logging::log_to_file("Error loading categories from JSON: $@");
            # Fall back to default categories if JSON loading fails
            $self->_load_default_categories();
        }
    } else {
        Comserv::Util::Logging::log_to_file("JSON config file not found, using default categories");
        $self->_load_default_categories();
    }
}

# Fallback method to load default categories if JSON fails
sub _load_default_categories {
    my ($self) = @_;
    
    %{$self->documentation_categories} = (
        'user_guides' => {
            title => 'User Guides',
            description => 'Documentation for end users of the system',
            icon => 'fas fa-users',
            display_order => 1,
            roles => ['normal', 'editor', 'admin', 'developer'],
            site_filter => 'all',
            pages => []
        },
        'admin_guides' => {
            title => 'Administrator Guides',
            description => 'Documentation for system administrators',
            icon => 'fas fa-shield-alt',
            display_order => 2,
            roles => ['admin', 'developer'],
            site_filter => 'all',
            pages => []
        },
        'developer_guides' => {
            title => 'Developer Documentation',
            description => 'Documentation for developers',
            icon => 'fas fa-code',
            display_order => 3,
            roles => ['developer'],
            site_filter => 'all',
            pages => []
        }
    );
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

    # First check session roles (this works even if user is not fully authenticated)
    if ($c->session->{roles} && ref $c->session->{roles} eq 'ARRAY' && @{$c->session->{roles}}) {
        # Log all roles for debugging
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'index',
            "Session roles: " . join(", ", @{$c->session->{roles}}));
            
        # If user has multiple roles, prioritize admin role
        if (grep { lc($_) eq 'admin' } @{$c->session->{roles}}) {
            $user_role = 'admin';
            $is_admin = 1;
        } else {
            # Otherwise use the first role
            $user_role = $c->session->{roles}->[0];
        }
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'index',
            "User role determined from session: $user_role, is_admin: $is_admin");
    }
    # If no role found in session but user exists, try to get role from user object
    elsif ($c->controller('Root')->user_exists($c)) {
        $user_role = $c->session->{roles} || 'normal';
        $is_admin = 1 if lc($user_role) eq 'admin';
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'index',
            "User role determined from session: $user_role, is_admin: $is_admin");
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
    my $categorized_pages = {};
    
    foreach my $page_name (@sorted_pages) {
        my $metadata = $filtered_pages{$page_name};
        my $path = $metadata->{path};
        my $title = $self->_format_title($page_name);

        # Always use the view action with the page name as parameter
        my $url = $c->uri_for($self->action_for('view'), [$page_name]);

        my $page_data = {
            title => $title,
            path => $path,
            url => $url,
            site => $metadata->{site},
            roles => $metadata->{roles},
        };
        
        $structured_pages->{$page_name} = $page_data;
        
        # Categorize the page based on its name/path
        my $category = $self->_determine_page_category($page_name, $path);
        if (!$categorized_pages->{$category}) {
            $categorized_pages->{$category} = [];
        }
        push @{$categorized_pages->{$category}}, $page_data;
    }
    
    # Filter categories based on user role and site
    my %filtered_categories;
    foreach my $category_key (keys %{$self->documentation_categories}) {
        my $category = $self->documentation_categories->{$category_key};
        
        # Check if user has access to this category based on roles
        my $has_category_access = $is_admin; # Admins can see all categories
        
        unless ($has_category_access) {
            foreach my $role (@{$category->{roles}}) {
                if ($role eq $user_role) {
                    $has_category_access = 1;
                    last;
                } elsif ($c->session->{roles} && ref $c->session->{roles} eq 'ARRAY') {
                    if (grep { $_ eq $role } @{$c->session->{roles}}) {
                        $has_category_access = 1;
                        last;
                    }
                }
            }
        }
        
        # Check site filtering for categories
        if ($has_category_access) {
            my $category_site_filter = $category->{site_filter} || 'all';
            if ($category_site_filter ne 'all' && $category_site_filter ne 'site_specific') {
                # Category is restricted to specific sites
                if ($category_site_filter ne $site_name && !$is_admin) {
                    $has_category_access = 0;
                }
            } elsif ($category_site_filter eq 'site_specific') {
                # Only show site_specific category if we have site-specific content or admin access
                if (!$is_admin && !exists $categorized_pages->{$category_key}) {
                    $has_category_access = 0;
                }
            }
        }
        
        # Only include categories that have pages and the user has access to
        if ($has_category_access && (exists $categorized_pages->{$category_key} || $is_admin)) {
            $filtered_categories{$category_key} = $category;
            
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'index',
                "Category '$category_key' accessible to user with role $user_role");
        } else {
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'index',
                "Category '$category_key' filtered out for user with role $user_role");
        }
    }
    
    # Sort categories by display order
    my @sorted_categories = sort {
        ($filtered_categories{$a}{display_order} || 999) 
        <=> ($filtered_categories{$b}{display_order} || 999)
    } keys %filtered_categories;

    # Set up stash variables for the template
    $c->stash(
        template => 'admin/documentation/index.tt',
        pages => $structured_pages,
        sorted_pages => \@sorted_pages,
        categories => \%filtered_categories,
        categorized_pages => $categorized_pages,
        sorted_categories => \@sorted_categories,
        user_role => $user_role,
        is_admin => $is_admin,
        site_name => $site_name,
        page_count => scalar @sorted_pages,
    );

    # Log successful completion
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
        sprintf("Documentation index loaded with %d pages in %d categories for user role %s on site %s",
            scalar @sorted_pages, scalar @sorted_categories, $user_role, $site_name));
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
    
    # First check if user is authenticated
    if ($c->user_exists) {
        # Check if roles are stored in session
        if ($c->session->{roles} && ref $c->session->{roles} eq 'ARRAY' && @{$c->session->{roles}}) {
            # Log all roles for debugging
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'view', 
                "Session roles: " . join(", ", @{$c->session->{roles}}));
            
            # If user has multiple roles, prioritize admin role
            if (grep { lc($_) eq 'admin' } @{$c->session->{roles}}) {
                $user_role = 'admin';
                $is_admin = 1;
            } else {
                # Otherwise use the first role
                $user_role = $c->session->{roles}->[0];
            }
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'view',
                "User role determined from session: $user_role, is_admin: $is_admin");
        }
        # If no role found in session but user exists, try to get role from user object
        else {
            $user_role = $c->session->{roles} || 'normal';
            $is_admin = 1 if lc($user_role) eq 'admin';
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'view',
                "User role determined from session: $user_role, is_admin: $is_admin");
        }
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
    # Try to find it as a markdown file in the Documentation directory
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

    # Page not found
    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'view',
        "Documentation page not found: $page");
    $c->response->status(404);
    $c->stash(
        error_msg => "Documentation page '$page' not found.",
        template => 'Documentation/error.tt'
    );
}

# Edit roles for a documentation page
sub edit_roles :Path('/Documentation/edit_roles') :Args(1) {
    my ($self, $c, $page_name) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_roles',
        "Accessing edit roles for page: $page_name");
    
    # Check admin permissions
    unless ($self->_check_admin_access($c)) {
        $c->response->status(403);
        $c->stash(
            error_msg => "Access denied. Administrator privileges required.",
            template => 'Documentation/error.tt'
        );
        return;
    }
    
    # Ensure documentation has been scanned
    $self->_ensure_scanned($c);
    
    # Get the page metadata
    my $pages = $self->documentation_pages;
    unless (exists $pages->{$page_name}) {
        $c->response->status(404);
        $c->stash(
            error_msg => "Documentation page '$page_name' not found.",
            template => 'Documentation/error.tt'
        );
        return;
    }
    
    my $page_metadata = $pages->{$page_name};
    
    # Available roles in the system
    my @available_roles = qw(normal user editor admin developer);
    
    $c->stash(
        template => 'admin/documentation/edit_roles.tt',
        page_name => $page_name,
        page_title => $self->_format_title($page_name),
        page_metadata => $page_metadata,
        available_roles => \@available_roles,
        current_roles => $page_metadata->{roles} || [],
    );
}

# Update roles for a documentation page
sub update_roles :Path('/Documentation/update_roles') :Args(1) {
    my ($self, $c, $page_name) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_roles',
        "Updating roles for page: $page_name");
    
    # Check admin permissions
    unless ($self->_check_admin_access($c)) {
        $c->response->status(403);
        $c->stash(
            error_msg => "Access denied. Administrator privileges required.",
            template => 'Documentation/error.tt'
        );
        return;
    }
    
    # Only handle POST requests
    unless ($c->req->method eq 'POST') {
        $c->response->status(405);
        $c->stash(
            error_msg => "Method not allowed. POST required.",
            template => 'Documentation/error.tt'
        );
        return;
    }
    
    # Ensure documentation has been scanned
    $self->_ensure_scanned($c);
    
    # Get the page metadata
    my $pages = $self->documentation_pages;
    unless (exists $pages->{$page_name}) {
        $c->response->status(404);
        $c->stash(
            error_msg => "Documentation page '$page_name' not found.",
            template => 'Documentation/error.tt'
        );
        return;
    }
    
    # Get selected roles from form
    my @selected_roles = $c->req->param('roles');
    
    # Debug logging
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'update_roles',
        "Raw selected roles count: " . scalar(@selected_roles) . ", roles: " . join(', ', @selected_roles));
    
    # Validate roles
    my @valid_roles = qw(normal user editor admin developer);
    my @filtered_roles = grep { my $role = $_; grep { $_ eq $role } @valid_roles } @selected_roles;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_roles',
        "Selected roles for $page_name: " . join(', ', @filtered_roles));
    
    # Update the page metadata in memory - safely
    eval {
        if (ref $pages eq 'HASH' && exists $pages->{$page_name} && ref $pages->{$page_name} eq 'HASH') {
            $pages->{$page_name}->{roles} = \@filtered_roles;
        } else {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'update_roles',
                "Cannot update page metadata - invalid pages structure for $page_name");
        }
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'update_roles',
            "Error updating page metadata: $@");
    }
    
    # Load the documentation configuration
    my $config_path = $c->path_to('root', 'Documentation', 'config', 'documentation_config.json');
    my $role_config = {};  # Using a different variable name to avoid any conflicts
    
    if (-e $config_path) {
        eval {
            open my $fh, '<:encoding(UTF-8)', $config_path or die "Cannot open $config_path: $!";
            my $json_content = do { local $/; <$fh> };
            close $fh;
            if ($json_content && $json_content !~ /^\s*$/) {
                my $decoded_data;
                eval {
                    $decoded_data = JSON->new->utf8->decode($json_content);
                };
                if ($@ || !defined $decoded_data) {
                    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'update_roles',
                        "Failed to decode JSON content: $@");
                    $role_config = {};
                } elsif (ref $decoded_data eq 'HASH') {
                    $role_config = $decoded_data;
                } else {
                    my $ref_type = ref $decoded_data || 'scalar';
                    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'update_roles',
                        "Config file does not contain a hash structure (got: $ref_type), initializing new config");
                    $role_config = {};
                }
            } else {
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_roles',
                    "Config file is empty, initializing new config");
                $role_config = {};
            }
        };
        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'update_roles',
                "Error reading config file: $@, initializing new config");
            $role_config = {};
        }
    } else {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_roles',
            "Config file does not exist, will create new one");
        $role_config = {};
    }
    
    # Ensure role_config is a hash reference with extra debugging
    unless (defined $role_config && ref $role_config eq 'HASH') {
        my $ref_type = defined $role_config ? ref $role_config : 'undefined';
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'update_roles',
            "Role config data is not a proper hash reference (got: $ref_type), reinitializing");
        $role_config = {};
    }
    
    # Additional safety check - Force reinitialization if still not a hash
    if (!defined $role_config || ref $role_config ne 'HASH') {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'update_roles',
            "Critical: role_config is still not a hash reference after reinitialization. Forcing new hash.");
        $role_config = {};
    }
    
    # Ensure role_config is definitely a hash reference before dereferencing
    eval {
        # Update or create entry in config with safer approach
        $role_config = {} unless ref $role_config eq 'HASH';
        $role_config->{pages} = {} unless ref $role_config->{pages} eq 'HASH';
        $role_config->{pages}->{$page_name} = {} unless ref $role_config->{pages}->{$page_name} eq 'HASH';
        $role_config->{pages}->{$page_name}->{roles} = \@filtered_roles;
        $role_config->{pages}->{$page_name}->{last_updated} = scalar localtime;
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'update_roles',
            "Error updating role config structure: $@");
        # Rebuild from scratch if there's still an issue
        $role_config = {
            pages => {
                $page_name => {
                    roles => \@filtered_roles,
                    last_updated => scalar localtime
                }
            }
        };
    }
    
    # Save the updated configuration
    eval {
        # Ensure the config directory exists
        my $config_dir = $c->path_to('root', 'Documentation', 'config');
        unless (-d $config_dir) {
            require File::Path;
            File::Path::make_path($config_dir, { mode => 0755 });
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_roles',
                "Created config directory: $config_dir");
        }
        
        # Clean the role_config structure to remove any blessed objects before JSON encoding
        my $clean_config = $self->_clean_for_json($role_config);
        
        open my $fh, '>:encoding(UTF-8)', $config_path or die "Cannot write to $config_path: $!";
        print $fh JSON->new->utf8->pretty->encode($clean_config);
        close $fh;
    };
    
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'update_roles',
            "Error saving config file: $@");
        $c->stash(
            error_msg => "Error saving role changes: $@",
            template => 'Documentation/error.tt'
        );
        return;
    }
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_roles',
        "Successfully updated roles for $page_name");
    
    # Redirect back to documentation index with success message
    $c->response->redirect($c->uri_for('/Documentation') . '?msg=roles_updated&page=' . $page_name);
}

# Check if user has admin access
sub _check_admin_access {
    my ($self, $c) = @_;
    
    # Check session roles
    if ($c->session->{roles} && ref $c->session->{roles} eq 'ARRAY') {
        return 1 if grep { lc($_) eq 'admin' || lc($_) eq 'developer' } @{$c->session->{roles}};
    }
    
    # Special case for site CSC
    if ($c->stash->{SiteName} && $c->stash->{SiteName} eq 'CSC') {
        if ($c->session->{username} && ($c->session->{username} eq 'Shanta' || $c->session->{username} eq 'admin')) {
            return 1;
        }
    }
    
    return 0;
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

# Determine which category a page belongs to based on its name and path
sub _determine_page_category {
    my ($self, $page_name, $path) = @_;
    
    # Convert to lowercase for pattern matching
    my $name_lower = lc($page_name);
    my $path_lower = lc($path || '');
    
    # Check for specific patterns to categorize pages
    return 'user_guides' if ($name_lower =~ /user|guide|manual|howto|getting.?started/);
    return 'admin_guides' if ($name_lower =~ /admin|administrator|installation|config|setup/);
    return 'developer_guides' if ($name_lower =~ /developer|dev|api|code|programming|development/);
    return 'tutorials' if ($name_lower =~ /tutorial|walkthrough|example|demo|sample/);
    return 'changelog' if ($name_lower =~ /changelog|changes|history|release|version/);
    return 'controllers' if ($name_lower =~ /controller|endpoint|route/);
    return 'models' if ($name_lower =~ /model|database|schema|data/);
    return 'modules' if ($name_lower =~ /module|component|plugin|lib/);
    return 'proxmox' if ($name_lower =~ /proxmox|virtualization|vm|container/);
    return 'site_specific' if ($name_lower =~ /site|specific|local|custom/);
    return 'documentation' if ($name_lower =~ /documentation|doc|help|readme/);
    
    # Check path patterns
    return 'controllers' if ($path_lower =~ /controller/);
    return 'models' if ($path_lower =~ /model/);
    return 'proxmox' if ($path_lower =~ /proxmox/);
    
    # Default to documentation category for uncategorized items
    return 'documentation';
}

# Helper method to clean data structure for JSON encoding
# Converts blessed objects and references to simple values
sub _clean_for_json {
    my ($self, $data) = @_;
    
    return undef unless defined $data;
    
    # Handle different reference types
    my $ref_type = ref $data;
    
    if (!$ref_type) {
        # Scalar value - return as is
        return $data;
    } elsif ($ref_type eq 'HASH') {
        # Hash reference - recursively clean each value
        my $clean_hash = {};
        for my $key (keys %$data) {
            $clean_hash->{$key} = $self->_clean_for_json($data->{$key});
        }
        return $clean_hash;
    } elsif ($ref_type eq 'ARRAY') {
        # Array reference - recursively clean each element
        my $clean_array = [];
        for my $item (@$data) {
            push @$clean_array, $self->_clean_for_json($item);
        }
        return $clean_array;
    } else {
        # Blessed object or other reference type
        # Convert to string representation
        return "$data";
    }
}

__PACKAGE__->meta->make_immutable;

1;