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
use Comserv::Controller::Documentation::ScanMethods qw(_scan_directories _categorize_pages);

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

# Store documentation pages with metadata
has 'documentation_pages' => (
    is => 'rw',
    default => sub { {} },
    lazy => 1,
);

# Documentation configuration instance
has 'doc_config' => (
    is => 'ro',
    default => sub { Comserv::Util::DocumentationConfig->instance },
    lazy => 1,
);

# Store documentation categories (now loaded from config)
has 'documentation_categories' => (
    is => 'rw',
    default => sub { {} },
    lazy => 1,
);

# Helper method for logging
sub _log {
    my ($self, $level, $message) = @_;
    my $logger = $self->logging;
    if ($logger && $logger->can('log_to_file')) {
        $logger->log_to_file($message, undef, $level);
    }
    return 1;
}

# Initialize - scan for documentation files
sub BUILD {
    my ($self) = @_;
    # Get logger instance
    my $logger = $self->logging;

    # Log initialization start
    $self->_log('INFO', "Starting Documentation controller initialization with DocumentationConfig");

    # Load categories from configuration
    my $config_categories = $self->doc_config->get_categories();
    $self->documentation_categories($config_categories);

    # Load pages from configuration
    my $config_pages = $self->doc_config->get_pages();
    
    # Convert pages to the format expected by the controller
    my %pages_hash = ();
    foreach my $page (@$config_pages) {
        # Generate a key from the page ID
        my $key = $page->{id};
        
        # Convert to the format expected by the controller
        $pages_hash{$key} = {
            path => $page->{path},
            site => $page->{site} || 'all',
            roles => $page->{roles} || ['normal', 'editor', 'admin', 'developer'],
            file_type => $page->{format} eq 'template' ? 'template' : 'other',
            title => $page->{title},
            description => $page->{description}
        };
    }
    
    $self->documentation_pages(\%pages_hash);

    # Build category pages arrays for compatibility with existing code
    foreach my $category_key (keys %$config_categories) {
        $self->documentation_categories->{$category_key}{pages} = [];
    }

    # Populate category pages arrays
    foreach my $page (@$config_pages) {
        my $key = $page->{id};
        
        # Add to each category the page belongs to
        if ($page->{categories}) {
            foreach my $category (@{$page->{categories}}) {
                if (exists $self->documentation_categories->{$category}) {
                    push @{$self->documentation_categories->{$category}{pages}}, $key;
                }
            }
        }
    }

    # Sort pages in each category
    foreach my $category (values %{$self->documentation_categories}) {
        if ($category->{pages}) {
            # Remove duplicates and sort
            my %seen;
            my @unique = grep { !$seen{$_}++ } @{$category->{pages}};
            
            $category->{pages} = [ sort {
                my $title_a = $self->documentation_pages->{$a}{title} || $a;
                my $title_b = $self->documentation_pages->{$b}{title} || $b;
                lc($title_a) cmp lc($title_b)
            } @unique ];
        }
    }

    $self->_log('INFO', sprintf("Documentation system initialized from config with %d pages across %d categories",
        scalar(@$config_pages), scalar(keys %$config_categories)));
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

    # Get current site
    my $current_site = $c->session->{site} || 'all';

    # Get filtered categories based on user role
    my $filtered_categories = $self->doc_config->get_filtered_categories($user_role);

    # Get filtered pages based on site and role
    my $filtered_pages = $self->doc_config->get_filtered_pages($current_site, $user_role);

    # Create structured_pages hash for template compatibility
    my %structured_pages = ();
    foreach my $page (@$filtered_pages) {
        # Add URL field for template compatibility
        $page->{url} = $c->uri_for('/Documentation/view/' . $page->{id});
        $structured_pages{$page->{id}} = $page;
    }

    # Update categories with pages arrays for template compatibility
    my %template_categories = %$filtered_categories;
    foreach my $category_key (keys %template_categories) {
        $template_categories{$category_key}{pages} = [];
    }

    # Add pages to their categories
    foreach my $page (@$filtered_pages) {
        if ($page->{categories}) {
            foreach my $category (@{$page->{categories}}) {
                if (exists $template_categories{$category}) {
                    push @{$template_categories{$category}{pages}}, $page->{id};
                }
            }
        }
    }

    # Set template variables
    $c->stash(
        template => 'Documentation/index.tt',
        categories => \%template_categories,
        structured_pages => \%structured_pages,
        user_role => $user_role,
        is_admin => $is_admin,
        current_site => $current_site,
        total_pages => scalar(@$filtered_pages)
    );

    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'index',
        "Documentation index loaded with " . scalar(@$filtered_pages) . " pages for role: $user_role");
}

# Handle view for both uppercase and lowercase routes
sub view :Path('/Documentation/view') :Args(1) {
    my ($self, $c, $page) = @_;

    # Log the action with detailed information
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view', 
        "Accessing documentation page: $page, Username: " . ($c->session->{username} || 'unknown') . 
        ", Site: " . ($c->stash->{SiteName} || 'default') . 
        ", Session roles: " . (ref $c->session->{roles} eq 'ARRAY' ? join(', ', @{$c->session->{roles}}) : 'none'));

    # Get user role for filtering
    my $user_role = 'normal';
    if ($c->session->{roles} && ref $c->session->{roles} eq 'ARRAY' && @{$c->session->{roles}}) {
        if (grep { lc($_) eq 'admin' } @{$c->session->{roles}}) {
            $user_role = 'admin';
        } elsif (grep { lc($_) eq 'developer' } @{$c->session->{roles}}) {
            $user_role = 'developer';
        } else {
            $user_role = $c->session->{roles}->[0];
        }
    }

    # Get current site
    my $current_site = $c->session->{site} || 'all';

    # Get the page from configuration
    my $page_data = $self->doc_config->get_page_by_id($page);
    
    if (!$page_data) {
        $c->stash(
            error_msg => "Documentation page '$page' not found",
            template => 'Documentation/error.tt'
        );
        return;
    }

    # Check if user has access to this page
    if (!$self->doc_config->user_has_access($page_data, $user_role, $current_site)) {
        $c->stash(
            error_msg => "Access denied to documentation page '$page'",
            template => 'Documentation/error.tt'
        );
        return;
    }

    # Set up template path
    my $template_path = $page_data->{path};
    
    $c->stash(
        template => $template_path,
        page_title => $page_data->{title},
        page_description => $page_data->{description}
    );

    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'view',
        "Displaying documentation page: $page (template: $template_path) for role: $user_role");
    
}

# Helper method to format titles from filenames
sub _format_title {
    my ($self, $filename) = @_;
    
    # Remove file extension
    $filename =~ s/\.[^.]+$//;
    
    # Replace underscores and hyphens with spaces
    $filename =~ s/[_-]/ /g;
    
    # Capitalize first letter of each word
    $filename = join(' ', map { ucfirst(lc($_)) } split(/\s+/, $filename));
    
    return $filename;
}

__PACKAGE__->meta->make_immutable;

1;
