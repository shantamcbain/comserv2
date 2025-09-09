package Comserv::Controller::Documentation;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;
use Comserv::Util::DocumentationConfig;
use File::Find;
use File::Basename;
use File::Spec;
use FindBin;
use Time::Piece;

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

# Initialize - load configuration from JSON
sub BUILD {
    my ($self) = @_;
    my $logger = $self->logging;

    $logger->log_to_file("Starting Documentation controller initialization", undef, 'INFO');

    # Load categories from config
    my $config_categories = $self->documentation_config->get_categories();
    %{$self->documentation_categories} = %$config_categories;

    # Load pages from config and convert to the format expected by the controller
    my $config_pages = $self->documentation_config->get_pages();
    
    foreach my $page (@$config_pages) {
        my $page_id = $page->{id};
        
        # Convert config format to controller format
        my %page_meta = (
            path => $page->{path},
            site => $page->{site} || 'all',
            roles => $page->{roles} || ['normal'],
            file_type => $page->{format} || 'markdown',
            title => $page->{title},
            description => $page->{description}
        );
        
        # Store in documentation pages
        $self->documentation_pages->{$page_id} = \%page_meta;
        
        # Log the loaded page
        $logger->log_to_file("Loaded documentation page: $page_id (path: $page->{path})", undef, 'DEBUG');
    }

    $logger->log_to_file(sprintf("Documentation system initialized with %d categories and %d pages",
        scalar keys %{$self->documentation_categories},
        scalar keys %{$self->documentation_pages}), undef, 'INFO');
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

__PACKAGE__->meta->make_immutable;

1;