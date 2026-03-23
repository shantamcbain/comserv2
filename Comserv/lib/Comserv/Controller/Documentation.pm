package Comserv::Controller::Documentation;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;
use Comserv::Controller::Documentation::ScanMethods qw(_scan_directories _categorize_pages _parse_meta_block _extract_md_metadata);
use File::Find;
use File::Basename;
use File::Spec;
use Digest::SHA qw(sha256_hex);
use File::Path qw(make_path);
use FindBin;
use Time::Piece;
use JSON;
use File::Slurp;
use DateTime;
use DateTime::Format::ISO8601;

BEGIN { extends 'Catalyst::Controller'; }

# Set the namespace to handle both /Documentation and /documentation routes
__PACKAGE__->config(namespace => 'Documentation');

# In-app helpers for safe, atomic JSON read/write
sub _load_json_file {
    my ($path) = @_;
    return unless defined $path && -e $path;
    local $/;
    open my $fh, '<:encoding(UTF-8)', $path or return;
    my $content = <$fh>;
    close $fh;
    return JSON->new->utf8->decode($content);
}

sub _atomic_write_json {
    my ($path, $data) = @_;
    return 0 unless defined $path;
    my $tmp = $path . '.tmp';
    {
        open my $fh, '>:encoding(UTF-8)', $tmp or return 0;
        print $fh JSON->new->utf8->pretty->encode($data);
        close $fh;
    }
    rename $tmp, $path or return 0;
    return 1;
}

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
    my $config_file = $FindBin::Bin . '/../root/Documentation/config/DocumentationConfig.json';
    
    # Initialize with empty hash
    %{$self->documentation_categories} = ();
    
    if (-f $config_file) {
        eval {
            # Read and parse JSON config via in-module loader
            my $config = _load_json_file($config_file);
            unless (defined $config) { die "Failed to load JSON config"; }
            
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
            Comserv::Util::Logging::log_to_file("Error loading categories from JSON: $@", 
            undef, 'ERROR');
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

# Persistent fingerprinting and auto-scan integration
#
# Automatically re-scan Documentation on access if the on-disk filesystem fingerprint
# differs from the previously stored fingerprint. This reuses the existing _scan_directories
# and _categorize_pages routines and keeps changes localized to this module.

my $SCAN_STATE_REL_PATH = File::Spec->catfile('Documentation', 'config', 'scan_state.json');

sub _fingerprint_fs {
    my ($docs_root) = @_;
    my @entries;
    find(
        {
            no_chdir => 1,
            wanted   => sub {
                return unless -f $_;
                return unless /\.(tt|md)$/i;
                my $mt = (stat($_))[9] // 0;
                push @entries, $File::Find::name . "\t" . $mt;
            }
        },
        $docs_root
    );
    @entries = sort @entries;
    my $flat = join("\n", @entries);
    return sha256_hex($flat);
}

sub _read_stored_fingerprint {
    my ($path) = @_;
    return undef unless defined $path && -e $path;
    local $/;
    open my $fh, '<:encoding(UTF-8)', $path or return undef;
    my $content = <$fh>;
    close $fh;
    if ($content =~ /"fingerprint"\s*:\s*"([^"]+)"/) {
        return $1;
    }
    return undef;
}

sub _store_fingerprint {
    my ($path, $fingerprint) = @_;
    return 0 unless defined $path;
    my $tmp = $path . '.tmp';
    open my $fh, '>:encoding(UTF-8)', $tmp or return 0;
    print $fh qq({"fingerprint":"$fingerprint"} );
    close $fh;
    rename $tmp, $path or return 0;
    return 1;
}

sub _compute_and_get_docs_root {
    my ($c) = @_;
    # Resolve the Documentation root directory on disk
    my $docs_root = $c->path_to('root', 'Documentation');
    return $docs_root;
}

sub _ensure_scanned {
    my ($self, $c) = @_;
    # If we already have pages, we still want to auto-rescan if fingerprint changed
    my $docs_root = _compute_and_get_docs_root($c);
    my $state_path = File::Spec->catfile($docs_root, 'config', 'scan_state.json');

    my $current_fp = $self->_fingerprint_fs($docs_root);
    my $stored_fp  = _read_stored_fingerprint($state_path);

    # Force rescan if documentation_pages is empty, regardless of fingerprint
    my $force_scan = (scalar keys %{$self->documentation_pages} == 0);

    if ($force_scan) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_ensure_scanned',
            "Forcing scan because documentation_pages is empty");
    }

    if (!defined $stored_fp || $current_fp ne $stored_fp || $force_scan) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_ensure_scanned',
            "Auto-scan triggered for Documentation (fingerprint changed).");
        # Run the existing scan routines to refresh in-memory index
        _scan_directories($self, $c);
        _categorize_pages($self, $c);
        # Update JSON config with newly scanned files
        $self->_update_json_config_with_scanned_files($c);
        # Update JSON config with newly scanned files
        $self->_update_json_config_with_scanned_files($c);
        # Persist new fingerprint atomically
        _store_fingerprint($state_path, $current_fp) or do {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, '_ensure_scanned',
                "Failed to persist new documentation fingerprint to $state_path");
        };
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_ensure_scanned',
            "Documentation fingerprint updated to $current_fp");
    } else {
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_ensure_scanned',
            "Documentation fingerprint unchanged; using cached index.");
    }

}

# Main documentation index - handles /Documentation route
sub index :Path('/Documentation') :Args(0) {
    my ($self, $c) = @_;

    # Set proper charset for UTF-8 content (fixes arrow character rendering)
    $c->response->content_type('text/html; charset=utf-8');

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
        # Check if user should have admin privileges on this site using centralized utility
        my $admin_auth = Comserv::Util::AdminAuth->new();
        if ($admin_auth->check_admin_access($c, 'documentation_index')) {
            $user_role = 'admin';
            $is_admin = 1;
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', 
                "Admin role granted for CSC site user (via AdminAuth)");
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

        # TEMPORARY: Show ALL pages for debugging - REMOVE THIS LATER
        $filtered_pages{$page_name} = $metadata;
        next;  # Skip all the filtering logic temporarily

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
            url => $url->as_string,  # Convert to string for template
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

    # Set proper charset for UTF-8 content (fixes arrow character rendering)
    $c->response->content_type('text/html; charset=utf-8');

    # Log the action
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view', "Accessing documentation page: $page");
    
    # Ensure documentation has been scanned
    $self->_ensure_scanned($c);

    # Log the number of pages found after scanning
    my $pages_count = scalar keys %{$self->documentation_pages};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
        "After scanning, found $pages_count pages in documentation_pages hash");

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
        # Check if user should have admin privileges on this site using centralized utility
        my $admin_auth = Comserv::Util::AdminAuth->new();
        if ($admin_auth->check_admin_access($c, 'documentation_view')) {
            $user_role = 'admin';
            $is_admin = 1;
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view', 
                "Admin role granted for CSC site user (via AdminAuth)");
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
                template => 'Documentation/Error.tt'
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
                template => 'Documentation/Error.tt'
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
                    template => 'Documentation/MarkdownViewer.tt'
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
                my $stash_data = {
                    page_name => $page,
                    page_title => $metadata->{title} || $self->_format_title($page),
                    user_role => $user_role,
                    site_name => $site_name,
                    template => $path
                };
                
                # Special handling for DailyPlans pages - fetch todos for that day
                if ($page =~ /DailyPlans-(\d{4})-(\d{2})-(\d{2})/) {
                    my $plan_date = "$1-$2-$3";
                    my ($year, $month, $day) = ($1, $2, $3);
                    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view',
                        "Fetching todos for DailyPlan date: $plan_date");
                    
                    # Calculate date info using Time::Piece
                    eval {
                        use Time::Piece;
                        my $tp = Time::Piece->strptime("$year-$month-$day", "%Y-%m-%d");
                        my $prev_tp = $tp - (24 * 60 * 60);  # subtract 1 day
                        my $next_tp = $tp + (24 * 60 * 60);  # add 1 day
                        
                        # Get current date for "today" link
                        my $now = localtime;
                        my $today_date = $now->strftime('%Y-%m-%d');
                        
                        $stash_data->{plan_date} = $plan_date;
                        $stash_data->{day} = $day;
                        $stash_data->{month} = $month;
                        $stash_data->{year} = $year;
                        $stash_data->{plan_date_year} = $year;
                        $stash_data->{plan_date_month} = $month;
                        $stash_data->{plan_date_day} = $day;
                        $stash_data->{day_name} = $tp->strftime('%A');
                        $stash_data->{month_name} = $tp->strftime('%B');
                        $stash_data->{curr_month_day} = $tp->strftime('%b %d');
                        $stash_data->{prev_date_str} = $prev_tp->strftime('%Y-%m-%d');
                        $stash_data->{next_date_str} = $next_tp->strftime('%Y-%m-%d');
                        $stash_data->{prev_month_day} = $prev_tp->strftime('%b %d');
                        $stash_data->{next_month_day} = $next_tp->strftime('%b %d');
                        $stash_data->{today_date} = $today_date;
                    };
                    if ($@) {
                        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'view',
                            "Error calculating dates for daily plan: $@");
                    }
                    
                    # Fetch todos for the specific date from the database
                    eval {
                        my $todo_rs = $c->model('DBEncy::Todo')->search(
                            [
                                { start_date => $plan_date },
                                { due_date => $plan_date },
                            ],
                            {
                                order_by => { -asc => 'priority' }
                            }
                        );
                        my @todos_for_day = $todo_rs->all;
                        $stash_data->{todos_for_today} = \@todos_for_day;
                        
                        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view',
                            "Found " . scalar(@todos_for_day) . " todos for $plan_date");
                    };
                    if ($@) {
                        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'view',
                            "Error fetching todos for daily plan: $@");
                    }
                }
                
                $c->stash(%$stash_data);
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
            template => 'Documentation/MarkdownViewer.tt'
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

    # Try to find it as a .tt file in the Documentation directory (unregistered)
    my $tt_path = "Documentation/$page.tt";
    my $tt_full_path = $c->path_to('root', $tt_path);

    if (-e $tt_full_path) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view',
            "Found unregistered .tt file: $tt_path");

        # Check admin access for unregistered files
        unless ($is_admin) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'view',
                "Access denied to unregistered page $page: admin required");
            $c->response->status(403);
            $c->stash(
                error_msg => "Access denied: Unregistered documentation requires admin privileges.",
                template => 'Documentation/Error.tt'
            );
            return;
        }

        # Handle template files
        my $stash_data = {
            page_name => $page,
            page_title => $self->_format_title($page),
            user_role => $user_role,
            site_name => $site_name,
            template => $tt_path
        };
        
        # Special handling for DailyPlans pages - fetch todos for that day
        if ($page =~ /DailyPlans-(\d{4})-(\d{2})-(\d{2})/) {
            my $plan_date = "$1-$2-$3";
            my ($year, $month, $day) = ($1, $2, $3);
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view',
                "Fetching todos for unregistered DailyPlan date: $plan_date");
            
            # Calculate date info using Time::Piece
            eval {
                use Time::Piece;
                my $tp = Time::Piece->strptime("$year-$month-$day", "%Y-%m-%d");
                my $prev_tp = $tp - (24 * 60 * 60);  # subtract 1 day
                my $next_tp = $tp + (24 * 60 * 60);  # add 1 day
                
                # Get current date for "today" link
                my $now = localtime;
                my $today_date = $now->strftime('%Y-%m-%d');
                
                $stash_data->{plan_date} = $plan_date;
                $stash_data->{day} = $day;
                $stash_data->{month} = $month;
                $stash_data->{year} = $year;
                $stash_data->{plan_date_year} = $year;
                $stash_data->{plan_date_month} = $month;
                $stash_data->{plan_date_day} = $day;
                $stash_data->{day_name} = $tp->strftime('%A');
                $stash_data->{month_name} = $tp->strftime('%B');
                $stash_data->{curr_month_day} = $tp->strftime('%b %d');
                $stash_data->{prev_date_str} = $prev_tp->strftime('%Y-%m-%d');
                $stash_data->{next_date_str} = $next_tp->strftime('%Y-%m-%d');
                $stash_data->{prev_month_day} = $prev_tp->strftime('%b %d');
                $stash_data->{next_month_day} = $next_tp->strftime('%b %d');
                $stash_data->{today_date} = $today_date;
            };
            if ($@) {
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'view',
                    "Error calculating dates for daily plan: $@");
            }
            
            # Fetch todos for the specific date from the database
            eval {
                my $todo_rs = $c->model('DBEncy::Todo')->search(
                    [
                        { start_date => $plan_date },
                        { due_date => $plan_date },
                    ],
                    {
                        order_by => { -asc => 'priority' }
                    }
                );
                my @todos_for_day = $todo_rs->all;
                $stash_data->{todos_for_today} = \@todos_for_day;
                
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view',
                    "Found " . scalar(@todos_for_day) . " todos for $plan_date");
            };
            if ($@) {
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'view',
                    "Error fetching todos for daily plan: $@");
            }
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
        template => 'Documentation/Error.tt'
    );
}

# Comprehensive config management interface
sub manage_config :Path('/Documentation/manage_config') :Args {
    my ($self, $c, @args) = @_;

    my $page_name;
    if (@args) {
        $page_name = join('/', @args);
        $page_name =~ s/%20/ /g;
        $page_name =~ tr/+/ /;
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'manage_config',
        "Accessing documentation config management" . ($page_name ? " for page: $page_name" : ""));

    # Check admin permissions
    unless ($self->_check_admin_access($c)) {
        $c->response->status(403);
        $c->stash(
            error_msg => "Access denied. Administrator privileges required.",
            template => 'Documentation/Error.tt'
        );
        return;
    }

    # Load the full JSON config
    my $config_file = $c->path_to('root', 'Documentation', 'config', 'DocumentationConfig.json');
    my $config = _load_json_file($config_file) || { categories => {}, pages => {} };

    # Available roles in the system
    my @available_roles = qw(normal user editor admin developer);

    # Get list of all categories
    my @categories = sort keys %{$config->{categories}};

    # Handle search parameters
    my $search_query = $c->req->params->{search_query} || '';
    my $search_docs = $c->req->params->{search_docs} || 0;
    $search_query =~ s/^\s+|\s+$//g;

    # Perform search if query provided
    my @search_results;
    if ($search_query && length($search_query) >= 2) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'manage_config',
            "Performing search for: '$search_query', docs: $search_docs");

        # Search in config JSON
        push @search_results, $self->_search_config_json($config, $search_query);

        # Search in Documentation files if requested
        if ($search_docs) {
            push @search_results, $self->_search_documentation_files($c, $search_query);
        }

        # Sort results by relevance
        @search_results = sort { $b->{relevance} <=> $a->{relevance} || $a->{title} cmp $b->{title} } @search_results;
    }

    # If a specific page was requested, show detail view
    my $selected_page;
    my $show_detail_view = 0;
    if ($page_name && $config->{pages}->{$page_name}) {
        $selected_page = $page_name;
        $show_detail_view = 1;
    }

    $c->stash(
        template => 'admin/documentation/manage_config.tt',
        config => $config,
        available_roles => \@available_roles,
        categories => \@categories,
        selected_page => $selected_page,
        show_detail_view => $show_detail_view,
        search_query => $search_query,
        search_docs => $search_docs,
        search_results => \@search_results,
    );
}

# Search helper methods for manage_config
sub _search_config_json {
    my ($self, $config, $query) = @_;
    my @results;

    # Search in categories
    foreach my $cat_key (keys %{$config->{categories}}) {
        my $category = $config->{categories}->{$cat_key};

        if ($category->{title} =~ /\Q$query\E/i ||
            $category->{description} =~ /\Q$query\E/i ||
            $cat_key =~ /\Q$query\E/i) {

            push @results, {
                type => 'category',
                title => "Category: $category->{title}",
                key => $cat_key,
                content => $category->{description} || '',
                relevance => 8,
                url => "#category-$cat_key"
            };
        }
    }

    # Search in pages
    foreach my $page_key (keys %{$config->{pages}}) {
        my $page = $config->{pages}->{$page_key};

        if ($page_key =~ /\Q$query\E/i ||
            $page->{title} =~ /\Q$query\E/i ||
            $page->{path} =~ /\Q$query\E/i) {

            my $relevance = 6;
            $relevance = 10 if $page_key =~ /\Q$query\E/i;

            push @results, {
                type => 'page',
                title => "Page: " . ($page->{title} || $page_key),
                key => $page_key,
                content => $page->{path} || '',
                relevance => $relevance,
                url => $page_key
            };
        }
    }

    return @results;
}

sub _search_documentation_files {
    my ($self, $c, $query) = @_;
    my @results;

    my $docs_root = $c->path_to('root', 'Documentation');
    my $pages = $self->documentation_pages;

    # Find all .tt and .md files
    find(
        {
            no_chdir => 1,
            wanted   => sub {
                return unless -f $_;
                return unless /\.(tt|md)$/i;

                my $rel_path = File::Spec->abs2rel($_, $docs_root);
                my $file_path = $_;

                # Check if this file is registered as a documentation page
                my $is_registered_page = 0;
                my $page_name;
                foreach my $pn (keys %$pages) {
                    my $page_data = $pages->{$pn};
                    if ($page_data->{path} eq $rel_path) {
                        $is_registered_page = 1;
                        $page_name = $pn;
                        last;
                    }
                }

                eval {
                    open my $fh, '<:encoding(UTF-8)', $file_path or die "Cannot open file: $!";
                    my $content = do { local $/; <$fh> };
                    close $fh;

                    if ($content =~ /\Q$query\E/i) {
                        # Create excerpt
                        my $match_pos = CORE::index(lc($content), lc($query));
                        my $excerpt = '';
                        if ($match_pos >= 0) {
                            my $start = $match_pos > 50 ? $match_pos - 50 : 0;
                            my $end = $match_pos + length($query) + 50;
                            $end = length($content) if $end > length($content);

                            $excerpt = substr($content, $start, $end - $start);
                            $excerpt =~ s/^\S*\s*//; # Remove partial word at start
                            $excerpt =~ s/\s*\S*$//; # Remove partial word at end
                            $excerpt = '...' . $excerpt . '...' if $start > 0 || $end < length($content);

                            # Clean up for display
                            $excerpt =~ s/\[%.*?%\]//g; # Remove TT syntax
                            $excerpt =~ s/<[^>]*>//g; # Remove HTML tags
                            $excerpt =~ s/\s+/ /g; # Normalize whitespace
                            $excerpt = substr($excerpt, 0, 200) . '...' if length($excerpt) > 200;
                        }

                        my $result_type = $is_registered_page ? 'registered_file' : 'unregistered_file';
                        my $title = $is_registered_page ?
                            "Documentation Page: $page_name" :
                            "Unregistered File: $rel_path";
                        my $url = $is_registered_page ? $page_name : undef;
                        my $relevance = $is_registered_page ? 4 : 3; # Lower relevance for unregistered files

                        push @results, {
                            type => $result_type,
                            title => $title,
                            key => $is_registered_page ? $page_name : $rel_path,
                            content => $excerpt,
                            relevance => $relevance,
                            url => $url
                        };
                    }
                };

                if ($@) {
                    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, '_search_documentation_files',
                        "Error reading file $file_path: $@");
                }
            }
        },
        $docs_root
    );

    return @results;
}

# Save config changes
sub save_config :Path('/Documentation/save_config') :Args(0) {
    my ($self, $c) = @_;

    # Check admin permissions
    unless ($self->_check_admin_access($c)) {
        $c->response->status(403);
        $c->body('Access denied');
        return;
    }

    # Only handle POST requests
    unless ($c->req->method eq 'POST') {
        $c->response->status(405);
        $c->body('Method not allowed');
        return;
    }

    my $config_file = $c->path_to('root', 'Documentation', 'config', 'DocumentationConfig.json');
    my $config = _load_json_file($config_file) || { categories => {}, pages => {} };

    # Get the action type
    my $action = $c->req->param('action');

    if ($action eq 'update_page') {
        my $original_page_name = $c->req->param('original_page_name');
        my $page_name = $c->req->param('page_name');
        my @roles = $c->req->param('roles');
        my @categories = $c->req->param('categories');
        my $title = $c->req->param('title');
        my $path = $c->req->param('path');
        my $format = $c->req->param('format');
        my $site = $c->req->param('site');

        if ($config->{pages}->{$original_page_name}) {
            # If page name changed, move the entry
            if ($original_page_name ne $page_name) {
                $config->{pages}->{$page_name} = $config->{pages}->{$original_page_name};
                delete $config->{pages}->{$original_page_name};
            }

            $config->{pages}->{$page_name}->{roles} = \@roles if @roles;
            # Handle categories - always store as array for consistency
            if (@categories) {
                $config->{pages}->{$page_name}->{categories} = \@categories;
                # Remove old single category field if it exists
                delete $config->{pages}->{$page_name}->{category};
            }
            $config->{pages}->{$page_name}->{title} = $title if $title;
            $config->{pages}->{$page_name}->{path} = $path if $path;
            $config->{pages}->{$page_name}->{format} = $format if $format;
            $config->{pages}->{$page_name}->{site} = $site if $site;
            $config->{pages}->{$page_name}->{last_updated} = scalar localtime;
        }
    }
    elsif ($action eq 'delete_page') {
        my $page_name = $c->req->param('page_name');
        delete $config->{pages}->{$page_name};
    }
    elsif ($action eq 'add_category') {
        my $cat_key = $c->req->param('category_key');
        my $cat_title = $c->req->param('category_title');
        my $cat_desc = $c->req->param('category_description');
        my @cat_roles = $c->req->param('category_roles');
        my $cat_icon = $c->req->param('category_icon') || 'fas fa-file-alt';

        $config->{categories}->{$cat_key} = {
            title => $cat_title,
            description => $cat_desc,
            roles => \@cat_roles,
            icon => $cat_icon,
            site_filter => 'all',
            display_order => scalar(keys %{$config->{categories}}) + 1,
        };
    }
    elsif ($action eq 'update_category') {
        my $cat_key = $c->req->param('category_key');
        my $cat_title = $c->req->param('category_title');
        my $cat_desc = $c->req->param('category_description');
        my @cat_roles = $c->req->param('category_roles');

        if ($config->{categories}->{$cat_key}) {
            $config->{categories}->{$cat_key}->{title} = $cat_title;
            $config->{categories}->{$cat_key}->{description} = $cat_desc;
            $config->{categories}->{$cat_key}->{roles} = \@cat_roles;
        }
    }
    elsif ($action eq 'delete_category') {
        my $cat_key = $c->req->param('category_key');
        delete $config->{categories}->{$cat_key};
    }
    elsif ($action eq 'add_page') {
        my $page_name = $c->req->param('page_name');
        my $file_path = $c->req->param('file_path');
        my @roles = $c->req->param('roles');
        my @categories = $c->req->param('categories');
        my $title = $c->req->param('title');

        # Extract metadata from the file if it exists
        my $metadata = {};
        if ($file_path) {
            my $full_path = $c->path_to('root', $file_path);
            if (-e $full_path) {
                eval {
                    open my $fh, '<:encoding(UTF-8)', $full_path or die "Cannot open file: $!";
                    my $content = do { local $/; <$fh> };
                    close $fh;

                    if ($file_path =~ /\.tt$/) {
                        $metadata = _parse_meta_block($content);
                    } elsif ($file_path =~ /\.md$/) {
                        $metadata = _extract_md_metadata($content, $page_name);
                    }
                };
                if ($@) {
                    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'save_config',
                        "Error reading metadata from $full_path: $@");
                }
            }
        }

        # Use provided values or fall back to metadata
        my $final_title = $title || $metadata->{title} || $self->_format_title($page_name);
        my $final_roles = @roles ? \@roles : ($metadata->{roles} ? [split(/\s*,\s*/, $metadata->{roles})] : ['admin', 'developer']);
        my $final_categories = @categories ? \@categories : ($metadata->{category} ? [$metadata->{category}] : ['admin']);
        my $final_format = $file_path =~ /\.md$/i ? 'markdown' : ($file_path =~ /\.tt$/i ? 'template' : 'unknown');

        $config->{pages}->{$page_name} = {
            path => $file_path,
            site => $metadata->{site_specific} && $metadata->{site_specific} eq 'true' ? 'specific' : 'all',
            roles => $final_roles,
            categories => $final_categories,
            title => $final_title,
            description => $metadata->{description},
            format => $final_format,
            last_scanned => scalar localtime
        };
    }

    # Save the updated config
    my $clean_config = $self->_clean_for_json($config);
    if (_atomic_write_json($config_file, $clean_config)) {
        $c->response->redirect($c->uri_for('/Documentation/manage_config') . '?msg=saved');
    } else {
        $c->response->redirect($c->uri_for('/Documentation/manage_config') . '?msg=error');
    }
}

# Edit category form
sub edit_category_form :Path('/Documentation/edit_category') :Args(1) {
    my ($self, $c, $cat_key) = @_;

    # Check admin permissions
    unless ($self->_check_admin_access($c)) {
        $c->response->status(403);
        $c->stash(
            error_msg => "Access denied. Administrator privileges required.",
            template => 'Documentation/Error.tt'
        );
        return;
    }

    # Available roles
    my @available_roles = qw(normal user editor admin developer);

    # Load current categories from config
    my $config_file = $c->path_to('root', 'Documentation', 'config', 'DocumentationConfig.json');
    my $config = _load_json_file($config_file) || { categories => {}, pages => {} };
    my $categories = $config->{categories} || {};

    # Check if category exists
    unless ($categories->{$cat_key}) {
        $c->response->status(404);
        $c->stash(
            error_msg => "Category '$cat_key' not found.",
            template => 'Documentation/Error.tt'
        );
        return;
    }

    $c->stash(
        template => 'admin/documentation/edit_category.tt',
        available_roles => \@available_roles,
        category => $categories->{$cat_key},
        category_key => $cat_key,
    );
}

# Add category form
sub add_category_form :Path('/Documentation/add_category') :Args(0) {
    my ($self, $c) = @_;

    # Check admin permissions
    unless ($self->_check_admin_access($c)) {
        $c->response->status(403);
        $c->stash(
            error_msg => "Access denied. Administrator privileges required.",
            template => 'Documentation/Error.tt'
        );
        return;
    }

    # Available roles
    my @available_roles = qw(normal user editor admin developer);

    # Load current categories from config
    my $config_file = $c->path_to('root', 'Documentation', 'config', 'DocumentationConfig.json');
    my $config = _load_json_file($config_file) || { categories => {}, pages => {} };
    my $existing_categories = $config->{categories} || {};

    $c->stash(
        template => 'admin/documentation/add_category.tt',
        available_roles => \@available_roles,
        existing_categories => $existing_categories,
    );
}

# Reload configuration from file
sub reload_config :Path('/Documentation/Config/reload') :Args(0) {
    my ($self, $c) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'reload_config',
        "Reloading documentation configuration");

    # Check admin permissions
    unless ($self->_check_admin_access($c)) {
        $c->response->status(403);
        $c->body('Access denied');
        return;
    }

    # Clear cached categories to force reload
    %{$self->documentation_categories} = ();

    # Reload categories from config
    $self->_load_categories_from_config();

    $c->response->redirect($c->uri_for('/Documentation/manage_config') . '?msg=reloaded');
}

# Export configuration as JSON
sub export_config :Path('/Documentation/Config/export') :Args(0) {
    my ($self, $c) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'export_config',
        "Exporting documentation configuration");

    # Check admin permissions
    unless ($self->_check_admin_access($c)) {
        $c->response->status(403);
        $c->body('Access denied');
        return;
    }

    # Load the current config
    my $config_file = $c->path_to('root', 'Documentation', 'config', 'DocumentationConfig.json');
    my $config = _load_json_file($config_file) || { categories => {}, pages => {} };

    # Set response headers for JSON download
    $c->response->content_type('application/json');
    $c->response->header('Content-Disposition' => 'attachment; filename=DocumentationConfig.json');

    # Output the JSON
    $c->response->body(JSON->new->utf8->pretty->encode($config));
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
            template => 'Documentation/Error.tt'
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
            template => 'Documentation/Error.tt'
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
            template => 'Documentation/Error.tt'
        );
        return;
    }
    
    # Only handle POST requests
    unless ($c->req->method eq 'POST') {
        $c->response->status(405);
        $c->stash(
            error_msg => "Method not allowed. POST required.",
            template => 'Documentation/Error.tt'
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
            template => 'Documentation/Error.tt'
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
    my $config_path = $c->path_to('root', 'Documentation', 'config', 'DocumentationConfig.json');
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
    
    # Save the updated configuration atomically
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
        my $config_path  = $config_dir . '/DocumentationConfig.json';
        _atomic_write_json($config_path, $clean_config) or die "Atomic write failed";
    };
    
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'update_roles',
            "Error saving config file: $@");
        $c->stash(
            error_msg => "Error saving role changes: $@",
            template => 'Documentation/Error.tt'
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
    
    # Special case for site CSC - using centralized utility
    if ($c->stash->{SiteName} && $c->stash->{SiteName} eq 'CSC') {
        my $admin_auth = Comserv::Util::AdminAuth->new();
        return 1 if $admin_auth->check_admin_access($c, '_check_admin_access');
    }
    
    return 0;
}

# Force a rescan of documentation (clears cache)
sub rescan :Path('/Documentation/rescan') :Args(0) {
    my ($self, $c) = @_;
    
    # Check admin permissions
    unless ($self->_check_admin_access($c)) {
        $c->response->status(403);
        $c->stash(
            error_msg => "Access denied. Administrator privileges required.",
            template => 'Documentation/Error.tt'
        );
        return;
    }
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'rescan',
        "Forcing documentation rescan");

    # Clear the cache
    %{$self->documentation_pages} = ();

    # Force a rescan
    _scan_directories($self, $c);
    _categorize_pages($self, $c);

    # Redirect back to the referring page, or default to manage_config
    my $referer = $c->req->referer || $c->uri_for('/Documentation/manage_config');
    $c->response->redirect($referer);
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

# Search documentation with role-based filtering
sub search :Path('/documentation/search') :Args(0) {
    my ($self, $c) = @_;
    
    # Log the search action
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'search', 
        "Documentation search initiated");
    
    # Get search parameters
    my $query = $c->req->params->{q} || '';
    my $category = $c->req->params->{category} || '';
    
    # Trim whitespace
    $query =~ s/^\s+|\s+$//g;
    
    # Ensure documentation has been scanned
    $self->_ensure_scanned($c);
    
    # Get user role (same logic as index method)
    my $user_role = 'normal';
    my $is_admin = 0;
    
    if ($c->session->{roles} && ref $c->session->{roles} eq 'ARRAY' && @{$c->session->{roles}}) {
        if (grep { lc($_) eq 'admin' } @{$c->session->{roles}}) {
            $user_role = 'admin';
            $is_admin = 1;
        } else {
            $user_role = $c->session->{roles}->[0];
        }
    } elsif ($c->controller('Root')->user_exists($c)) {
        $user_role = $c->session->{roles} || 'normal';
        $is_admin = 1 if lc($user_role) eq 'admin';
    }
    
    # Special case for CSC site using centralized utility
    if ($c->stash->{SiteName} && $c->stash->{SiteName} eq 'CSC') {
        my $admin_auth = Comserv::Util::AdminAuth->new();
        if ($admin_auth->check_admin_access($c, 'documentation_search')) {
            $user_role = 'admin';
            $is_admin = 1;
        }
    }
    
    my $site_name = $c->stash->{SiteName} || 'default';
    
    # Perform search only if query is provided
    my @search_results;
    if ($query && length($query) >= 2) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'search',
            "Performing search for: '$query' in category: '$category'");
        
        # Get all documentation pages
        my $pages = $self->documentation_pages;
        
        foreach my $page_name (keys %$pages) {
            my $metadata = $pages->{$page_name};
            
            # Apply same role and site filtering as index method
            if ($metadata->{site} ne 'all' && $metadata->{site} ne $site_name) {
                next unless $is_admin;
            }
            
            # Check role access
            my $has_role = $is_admin;
            unless ($has_role) {
                foreach my $role (@{$metadata->{roles}}) {
                    if ($role eq $user_role) {
                        $has_role = 1;
                        last;
                    } elsif ($c->session->{roles} && ref $c->session->{roles} eq 'ARRAY') {
                        if (grep { $_ eq $role } @{$c->session->{roles}}) {
                            $has_role = 1;
                            last;
                        }
                    } elsif ($role eq 'normal' && $user_role) {
                        $has_role = 1;
                        last;
                    }
                }
            }
            next unless $has_role;
            
            # Determine category for filtering
            my $page_category = $self->_determine_page_category($page_name, $metadata->{path});
            
            # Skip if specific category is requested and this page doesn't match
            if ($category && $category ne $page_category) {
                next;
            }
            
            # Check if query matches page name, path, or content
            my $title = $self->_format_title($page_name);
            my $matches_title = ($title =~ /\Q$query\E/i);
            my $matches_path = ($metadata->{path} =~ /\Q$query\E/i);
            my $matches_content = 0;
            my $excerpt = '';
            
            # Try to read file content for search
            my $full_path = $c->path_to('root', $metadata->{path});
            if (-f $full_path) {
                eval {
                    open my $fh, '<:encoding(UTF-8)', $full_path or die "Cannot open file: $!";
                    my $content = do { local $/; <$fh> };
                    close $fh;
                    
                    if ($content =~ /\Q$query\E/i) {
                        $matches_content = 1;
                        
                        # Create excerpt around the match
                        my $match_pos = CORE::index(lc($content), lc($query));
                        if ($match_pos >= 0) {
                            my $start = $match_pos > 100 ? $match_pos - 100 : 0;
                            my $end = $match_pos + length($query) + 100;
                            $end = length($content) if $end > length($content);
                            
                            $excerpt = substr($content, $start, $end - $start);
                            $excerpt =~ s/^\S*\s*//; # Remove partial word at start
                            $excerpt =~ s/\s*\S*$//; # Remove partial word at end
                            $excerpt = '...' . $excerpt . '...' if $start > 0 || $end < length($content);
                            
                            # Remove Template Toolkit syntax for cleaner display
                            $excerpt =~ s/\[%.*?%\]//g;
                            $excerpt =~ s/<[^>]*>//g; # Remove HTML tags
                            $excerpt =~ s/\s+/ /g; # Normalize whitespace
                            $excerpt = substr($excerpt, 0, 300) . '...' if length($excerpt) > 300;
                        }
                    }
                };
                
                if ($@) {
                    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'search',
                        "Error reading file for search: $@");
                }
            }
            
            # Add to results if match found
            if ($matches_title || $matches_path || $matches_content) {
                my $relevance = $matches_title ? 10 : ($matches_path ? 8 : 5);
                push @search_results, {
                    title => $title,
                    url => $c->uri_for($self->action_for('view'), [$page_name]),
                    path => $metadata->{path},
                    category => $page_category,
                    site => $metadata->{site},
                    roles => $metadata->{roles},
                    excerpt => $excerpt || $metadata->{path},
                    relevance => $relevance,
                };
            }
        }
        
        # Sort results by relevance
        @search_results = sort { $b->{relevance} <=> $a->{relevance} || $a->{title} cmp $b->{title} } @search_results;
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'search',
            "Search completed. Found " . scalar(@search_results) . " results");
    }
    
    # Forward to index with search results
    $c->forward('index');
    
    # Add search-specific stash variables
    $c->stash(
        search_query => $query,
        search_category => $category,
        search_results => \@search_results,
    );
}


# Update JSON configuration file with newly scanned files
sub _update_json_config_with_scanned_files {
    my ($self, $c) = @_;

    my $config_file = $c->path_to('root', 'Documentation', 'config', 'DocumentationConfig.json');

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_update_json_config_with_scanned_files',
        "Updating JSON config with scanned files at: $config_file");

    # Load existing config
    my $config = {};
    if (-e $config_file) {
        $config = _load_json_file($config_file) || {};
    }

    # Ensure config structure exists
    $config->{categories} = $self->documentation_categories unless ref $config->{categories} eq 'HASH';
    $config->{pages} = {} unless ref $config->{pages} eq 'HASH';

    # Get discovered pages from scan
    my $pages = $self->documentation_pages;
    my $new_count = 0;
    my $update_count = 0;

    foreach my $page_name (keys %$pages) {
        my $metadata = $pages->{$page_name};

        # Check if page is new or needs update
        my $is_new = !exists $config->{pages}->{$page_name};

        # For new pages, force them into admin_guides category with admin role and prefixed title
        my $category;
        my $roles;
        my $title;

        if ($is_new) {
            $category = 'admin_guides';
            $roles = ['admin'];
            my $original_title = $metadata->{title} || $self->_format_title($page_name);
            $title = "UNCATEGORIZED: $original_title";
            $new_count++;
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_update_json_config_with_scanned_files',
                "Added uncategorized page to admin_guides: $page_name");
        } else {
            $category = $metadata->{category} || $self->_determine_page_category($page_name, $metadata->{path});
            $roles = $metadata->{roles};
            $title = $metadata->{title} || $self->_format_title($page_name);
            $update_count++;
        }

        # Always update to keep data fresh
        $config->{pages}->{$page_name} = {
            path => $metadata->{path},
            site => $metadata->{site},
            roles => $roles,
            format => $metadata->{format},
            title => $title,
            description => $metadata->{description},
            category => $category,
            last_scanned => scalar localtime
        };
    }

    # Update timestamp
    $config->{last_updated} = scalar localtime;

    # Save updated config
    my $clean_config = $self->_clean_for_json($config);
    if (_atomic_write_json($config_file, $clean_config)) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_update_json_config_with_scanned_files',
            "Successfully updated JSON config: $new_count new pages, $update_count updated pages");
    } else {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_update_json_config_with_scanned_files',
            "Failed to write JSON config file");
    }
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

# Run documentation sync audit
sub run_audit :Path('/Documentation/run_audit') :Args(0) {
    my ($self, $c) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'run_audit',
        "Running documentation sync audit");

    # Check admin permissions
    unless ($self->_check_admin_access($c)) {
        $c->response->status(403);
        $c->stash(
            error_msg => "Access denied. Administrator privileges required.",
            template => 'Documentation/Error.tt'
        );
        return;
    }

    # Execute documentation_sync_audit.pl script
    # Script is at project root (.zencoder/scripts/), not in Comserv/ directory
    use File::Spec;
    my $app_root = $c->path_to();  # /path/to/Comserv
    my $project_root = File::Spec->catdir($app_root, '..');  # Go up one level to project root
    my $script_path = File::Spec->catfile($project_root, '.zencoder', 'scripts', 'documentation_sync_audit.pl');
    
    unless (-e $script_path) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'run_audit',
            "Script not found at: $script_path");
        $c->response->status(404);
        $c->stash(
            error_msg => "Audit script not found at $script_path",
            template => 'Documentation/Error.tt'
        );
        return;
    }

    # Run the script
    use IPC::Run qw(run);
    my @cmd = ('perl', $script_path, '--verbose');
    my $out = '';
    my $err = '';
    
    eval {
        run \@cmd, \undef, \$out, \$err or die "Script execution failed: $?";
    };

    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'run_audit',
            "Audit script failed: $@");
        $c->stash(
            error_msg => "Audit failed: $@",
            output => $err,
            template => 'Documentation/Error.tt'
        );
        return;
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'run_audit',
        "Audit completed successfully");

    # Read and render the audit report file
    my $audit_file = File::Spec->catfile($project_root, 'Comserv', 'root', 'Documentation', 'AuditReports', 'DocumentationSyncAudit.tt');
    
    if (-e $audit_file) {
        # Set proper encoding
        $c->response->content_type('text/html; charset=utf-8');
        
        # Render the audit report template
        $c->stash(template => 'Documentation/AuditReports/DocumentationSyncAudit.tt');
    } else {
        $c->stash(
            error_msg => "Audit report file not found at $audit_file",
            template => 'Documentation/Error.tt'
        );
    }
}

sub daily_plan :Path('/Documentation/DailyPlan') :Args {
    my ($self, $c, @args) = @_;
    my $requested_date = $args[0] if @args;

    # DailyPlan is accessible to all sites — non-CSC sites see only DB-driven sections.
    # CSC sees text-based planning tabs in addition to the DB-driven sections.
    my $sitename = $c->stash->{SiteName} || $c->session->{SiteName} || 'CSC';
    my $is_csc   = (uc($sitename) eq 'CSC') ? 1 : 0;

    # Role check: all roles above member (admin, developer, devops, editor, user, normal)
    # Also accept stash is_admin set by Root::auto (catches site-specific admins)
    my $user_roles = $c->stash->{user_roles} || $c->session->{roles} || [];
    $user_roles = [$user_roles] unless ref $user_roles eq 'ARRAY';
    my $has_access = $c->stash->{is_admin}
        || grep { lc($_) =~ /^(admin|developer|devops|editor|user|normal)$/ } @$user_roles;
    unless ($has_access) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'daily_plan',
            "Access denied to DailyPlan for user: " . ($c->session->{username} || 'Guest'));
        $c->res->redirect($c->uri_for('/user/login', { return_to => $c->req->uri }));
        $c->detach;
    }

    # Get current date in YYYY-MM-DD format
    my $now = Time::Piece->new();
    my $current_date_str = $now->strftime('%Y-%m-%d');
    my $current_display = $now->strftime('%A, %B %d, %Y');

    # Use requested date or default to today
    my $selected_date = $requested_date || $current_date_str;

    # Parse selected date and calculate navigation dates
    my ($year, $month, $day);
    if ($selected_date =~ /^(\d{4})-(\d{2})-(\d{2})$/) {
        ($year, $month, $day) = ($1, $2, $3);
    } else {
        # Invalid date format, use today
        $selected_date = $current_date_str;
        ($year, $month, $day) = split('-', $current_date_str);
    }

    # Create Time::Piece objects for date navigation
    my $selected_tp;
    eval {
        $selected_tp = Time::Piece->strptime("$year-$month-$day", "%Y-%m-%d");
    };
    if ($@ || !$selected_tp) {
        # Fallback if strptime fails on an invalid date
        $selected_tp = $now;
        $selected_date = $current_date_str;
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'daily_plan',
            "Invalid date requested: $year-$month-$day. Falling back to today.");
    }

    my $prev_tp = $selected_tp - (24 * 60 * 60);  # Subtract 1 day
    my $next_tp = $selected_tp + (24 * 60 * 60);  # Add 1 day

    my $prev_date = $prev_tp->strftime('%Y-%m-%d');
    my $next_date = $next_tp->strftime('%Y-%m-%d');
    my $display_date = $selected_tp->strftime('%A, %B %d, %Y');

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'daily_plan',
        "Accessing DailyPlan view for date: $selected_date");

    # --- Prepare data for week.tt and month.tt ---
    my $dt = DateTime::Format::ISO8601->parse_datetime($selected_date);
    
    # Week data
    my $start_of_week = $dt->clone->subtract(days => $dt->day_of_week - 1)->strftime('%Y-%m-%d');
    my $end_of_week = $dt->clone->add(days => 7 - $dt->day_of_week)->strftime('%Y-%m-%d');
    my $prev_week_date = $dt->clone->subtract(days => 7)->strftime('%Y-%m-%d');
    my $next_week_date = $dt->clone->add(days => 7)->strftime('%Y-%m-%d');
    
    my $start_dt = DateTime::Format::ISO8601->parse_datetime($start_of_week);
    $start_dt = $start_dt->subtract(days => 1); # Start on Sunday for week view
    
    my @week_dates = ();
    for my $day_offset (0..6) {
        my $current_date_dt = $start_dt->clone->add(days => $day_offset);
        push @week_dates, {
            date_str => $current_date_dt->strftime('%Y-%m-%d'),
            day_num => $current_date_dt->day,
            is_today => ($current_date_dt->strftime('%Y-%m-%d') eq $current_date_str),
        };
    }

    # Month data
    my $start_of_month = $dt->clone->set_day(1)->strftime('%Y-%m-%d');
    my $end_of_month = $dt->clone->set_day($dt->month_length)->strftime('%Y-%m-%d');
    my $prev_month_date = $dt->clone->subtract(months => 1)->set_day(1)->strftime('%Y-%m-%d');
    my $next_month_date = $dt->clone->add(months => 1)->set_day(1)->strftime('%Y-%m-%d');

    # Fetch todos for the selected date and for week/month views
    my $todos_for_today = [];
    my $all_todos_calendar = [];
    my %todos_by_day;

    if (my $todo_model = $c->model('Todo')) {
        eval {
            my $sitename = $c->session->{SiteName} || 'CSC';
            $all_todos_calendar = $todo_model->get_all_todos_for_calendar($c, $sitename);
            
            if ($all_todos_calendar && ref($all_todos_calendar) eq 'ARRAY') {
                # Filter todos for today
                foreach my $todo (@$all_todos_calendar) {
                    my $start = $todo->start_date || '';
                    my $due = $todo->due_date || '';
                    
                    # Normalize dates
                    $start = $start->ymd if ref $start && eval { $start->can('ymd') };
                    $due = $due->ymd if ref $due && eval { $due->can('ymd') };
                    
                    if ($start eq $selected_date || $due eq $selected_date) {
                        push @$todos_for_today, $todo;
                    }

                    # Organize for month calendar
                    my $display_date = $due || $start;
                    if ($display_date =~ /^(\d{4})-(\d{2})-(\d{2})$/) {
                        my ($y, $m, $d) = ($1, $2, $3);
                        if (int($y) == $dt->year && int($m) == $dt->month) {
                            push @{$todos_by_day{int($d)}}, $todo;
                        }
                    }
                }
            }
        };
        if ($@) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'daily_plan',
                "Error fetching todos: $@");
        }
    }

    # Generate calendar structure for month.tt
    my @calendar;
    my $first_day_of_month = DateTime->new(year => $dt->year, month => $dt->month, day => 1);
    my $day_of_week_start = $first_day_of_month->day_of_week % 7; # 0 for Sunday
    for (my $i = 0; $i < $day_of_week_start; $i++) {
        push @calendar, { day => '', todos => [] };
    }
    for (my $day_idx = 1; $day_idx <= $dt->month_length; $day_idx++) {
        push @calendar, {
            day => $day_idx,
            date => sprintf("%04d-%02d-%02d", $dt->year, $dt->month, $day_idx),
            todos => $todos_by_day{$day_idx} || []
        };
    }

    # Set proper charset for UTF-8 content
    $c->response->content_type('text/html; charset=utf-8');

    # Fetch DB plans for this site (used in PLANNING tab for all sites)
    my @db_plans;
    eval {
        my %search_cond = $is_csc ? () : (sitename => $sitename);
        my $rs = $c->model('DBEncy')->resultset('DailyPlan');
        my @plan_rows = $rs->search(\%search_cond, { order_by => { -asc => 'priority' } });
        for my $plan (@plan_rows) {
            my %h = $plan->get_columns;
            $h{progress_percentage}     = $plan->get_progress_percentage;
            $h{todo_count}              = $plan->get_todo_count;
            $h{completed_todo_count}    = $plan->get_completed_todo_count;
            $h{is_overdue}              = $plan->is_overdue;
            push @db_plans, \%h;
        }
    };
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'daily_plan',
            "Could not fetch DB plans: $@");
    }

    # Fetch projects from DB for PLANNING tab (with their linked plans)
    # CSC sees all sites; others see only their own sitename
    my @planning_projects;
    my @orphan_plans;       # plans not linked to any project
    my @plan_sitenames;     # distinct sitenames for filter toggle (CSC only)

    # --- Fetch top-level projects (separate eval so orphan-plan failure can't block this) ---
    eval {
        my %proj_cond = (parent_id => undef);   # top-level only — filter in SQL, not Perl
        $proj_cond{sitename} = $sitename unless $is_csc;

        my @proj_rows = $c->model('DBEncy')->resultset('Project')->search(
            \%proj_cond,
            { order_by => ['sitename', 'name'] }
        )->all;

        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'daily_plan',
            "planning_projects: fetched " . scalar(@proj_rows) . " top-level projects (is_csc=$is_csc)");

        for my $proj (@proj_rows) {
            my $sn = $proj->sitename || '';
            my %p = $proj->get_columns;

            # Linked plans via many_to_many (inner eval — failure just means no linked plans shown)
            my @linked_plans;
            eval {
                for my $pln ($proj->dailyplans->all) {
                    my %ph = $pln->get_columns;
                    push @linked_plans, \%ph;
                }
            };
            if ($@) {
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'daily_plan',
                    "Could not fetch linked plans for project $p{id}: $@");
            }
            $p{linked_plans} = \@linked_plans;
            push @planning_projects, \%p;

            # Collect sitenames for filter toggle (skip blank)
            push @plan_sitenames, $sn if $sn;
        }

        # Deduplicate sitenames
        my %seen_site;
        @plan_sitenames = grep { !$seen_site{$_}++ } sort @plan_sitenames;
    };
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'daily_plan',
            "Could not fetch planning projects: $@");
    }

    # --- Standalone plans (not linked to any project) — separate eval ---
    eval {
        my %plan_cond = $is_csc ? () : (sitename => $sitename);
        for my $pln ($c->model('DBEncy')->resultset('DailyPlan')->search(
            \%plan_cond, { order_by => { -desc => 'created_at' } }
        )->all) {
            eval {
                push @orphan_plans, { $pln->get_columns }
                    if $pln->dailyplan_projects->count == 0;
            };
        }
    };
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'daily_plan',
            "Could not fetch orphan plans: $@");
    }

    # Filter projects by filter_site param (CSC admin only)
    my $filter_site = $c->req->param('filter_site') || '';
    if ($is_csc && $filter_site) {
        @planning_projects = grep { ($_->{sitename} || '') eq $filter_site } @planning_projects;
        @orphan_plans      = grep { ($_->{sitename} || '') eq $filter_site } @orphan_plans;
    }

    # --- Active Priorities: DB-driven, role/site/user scoped, dependency-ordered ---
    my @active_priorities;
    eval {
        my $user_id  = $c->session->{user_id};
        my $roles    = $c->stash->{user_roles} || [];
        my $can_see_all = $c->stash->{is_admin}
            || grep { lc($_) =~ /^(developer|devops|editor)$/ } @$roles;

        my %ap_cond = (status => { '!=' => 3 });   # exclude DONE
        $ap_cond{sitename} = $sitename unless $is_csc;  # non-CSC: own site only
        $ap_cond{user_id}  = $user_id  unless $can_see_all;  # members: own todos only

        my @rows = $c->model('DBEncy')->resultset('Todo')->search(
            \%ap_cond,
            {
                order_by => [
                    { -asc  => 'priority'    },
                    { -desc => 'is_blocking' },
                    { -asc  => 'start_date'  },
                ],
                rows => 20,
            }
        )->all;

        # Pre-fetch all returned IDs for fast blocker lookup
        my %row_by_id = map { $_->record_id => $_ } @rows;

        # Cache for project names
        my %proj_cache;

        for my $todo (@rows) {
            my %h = $todo->get_columns;

            # Blocker info
            if ($h{blocked_by_todo_id}) {
                my $blocker = $row_by_id{$h{blocked_by_todo_id}}
                    || eval { $c->model('DBEncy')->resultset('Todo')->find($h{blocked_by_todo_id}) };
                if ($blocker) {
                    $h{blocker_subject} = $blocker->subject;
                    $h{blocker_done}    = ($blocker->status == 3) ? 1 : 0;
                }
            }

            # Project name (cached)
            if ($h{project_id}) {
                unless (exists $proj_cache{$h{project_id}}) {
                    my $p = eval { $c->model('DBEncy')->resultset('Project')->find($h{project_id}) };
                    $proj_cache{$h{project_id}} = $p ? $p->name : '';
                }
                $h{project_name} = $proj_cache{$h{project_id}};
            }

            push @active_priorities, \%h;
        }
    };
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'daily_plan',
            "Could not fetch active priorities: $@");
    }

    # Pass all date information and todos to template
    $c->stash(
        # Site context
        is_csc         => $is_csc,
        plan_sitename  => $sitename,
        db_plans       => \@db_plans,
        planning_projects => \@planning_projects,
        orphan_plans   => \@orphan_plans,
        plan_sitenames => \@plan_sitenames,
        filter_site    => $filter_site,
        is_admin       => $c->stash->{is_admin},

        # Date strings
        current_date_str => $current_date_str,
        current_display => $current_display,
        selected_date => $selected_date,
        display_date => $display_date,
        prev_date => $prev_date,
        next_date => $next_date,
        
        # Week data
        week_dates => \@week_dates,
        start_of_week => $start_of_week,
        end_of_week => $end_of_week,
        prev_week_date => $prev_week_date,
        next_week_date => $next_week_date,
        
        # Month data
        calendar => \@calendar,
        month_name => $dt->month_name,
        year => $dt->year,
        start_of_month => $start_of_month,
        end_of_month => $end_of_month,
        prev_month_date => $prev_month_date,
        next_month_date => $next_month_date,
        today => $current_date_str,
        
        # Todos
        todos           => $all_todos_calendar,    # For week.tt
        todos_for_today => $todos_for_today,       # For day view
        active_priorities => \@active_priorities,  # DB-driven priority list for TODAY'S FOCUS

        template => 'admin/documentation/DailyPlan.tt'
    );
}

__PACKAGE__->meta->make_immutable;

1;
