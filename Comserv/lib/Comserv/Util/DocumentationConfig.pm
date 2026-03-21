package Comserv::Util::DocumentationConfig;

use strict;
use warnings;
use Moose;
use namespace::autoclean;
use JSON;
use Try::Tiny;
use Comserv::Util::Logging;
use File::Spec;
use FindBin;

# Singleton instance
my $instance;

# Categories of documentation
has 'categories' => (
    is      => 'ro',
    isa     => 'HashRef',
    default => sub { {} },
);

# Pages of documentation
has 'pages' => (
    is      => 'ro',
    isa     => 'ArrayRef',
    default => sub { [] },
);

# Pages indexed by ID for quick lookup
has 'pages_by_id' => (
    is      => 'ro',
    isa     => 'HashRef',
    default => sub { {} },
);

# Pages indexed by category for quick lookup
has 'pages_by_category' => (
    is      => 'ro',
    isa     => 'HashRef',
    default => sub { {} },
);

# Pages indexed by site for quick lookup
has 'pages_by_site' => (
    is      => 'ro',
    isa     => 'HashRef',
    default => sub { {} },
);

# Constructor - load configuration from JSON file
sub BUILD {
    my ($self) = @_;
    $self->load_config();
}

# Get singleton instance
sub instance {
    my ($class) = @_;

    unless (defined $instance) {
        $instance = $class->new();
    }

    return $instance;
}

# Load configuration from JSON file
sub load_config {
    my ($self) = @_;

    # Use FindBin to get absolute path to config file
    my $config_file = File::Spec->catfile($FindBin::Bin, '..', 'root', 'Documentation', 'config', 'documentation_config.json');
    
    # Log the config file path for debugging
    Comserv::Util::Logging::log_to_file(
        "Attempting to load documentation config from: $config_file",
        undef, 'DEBUG'
    );
    
    # Check if file exists
    unless (-f $config_file) {
        Comserv::Util::Logging::log_to_file(
            "Documentation config file not found at: $config_file",
            undef, 'ERROR'
        );
        return;
    }

    try {
        # Read the JSON file
        open my $fh, '<:encoding(UTF-8)', $config_file or die "Cannot open $config_file: $!";
        my $json_content = do { local $/; <$fh> };
        close $fh;

        # Parse the JSON content
        my $config = decode_json($json_content);

        # Store categories
        $self->{categories} = $config->{categories} || {};

        # Store pages
        $self->{pages} = $config->{pages} || [];

        # Index pages by ID
        foreach my $page (@{$self->{pages}}) {
            $self->{pages_by_id}->{$page->{id}} = $page;

            # Index pages by category
            foreach my $category (@{$page->{categories}}) {
                $self->{pages_by_category}->{$category} ||= [];
                push @{$self->{pages_by_category}->{$category}}, $page;
            }

            # Index pages by site
            my $site = $page->{site} || 'all';
            $self->{pages_by_site}->{$site} ||= [];
            push @{$self->{pages_by_site}->{$site}}, $page;
        }

        Comserv::Util::Logging::log_to_file(
            "Loaded documentation configuration: " .
                scalar(keys %{$self->{categories}}) . " categories, " .
                scalar(@{$self->{pages}}) . " pages",
            undef, 'INFO'
        );
        
        # Debug log category keys
        Comserv::Util::Logging::log_to_file(
            "Category keys loaded: " . join(", ", keys %{$self->{categories}}),
            undef, 'DEBUG'
        );
    } catch {
        Comserv::Util::Logging::log_to_file(
            "Error loading documentation configuration: $_",
            undef, 'ERROR'
        );
    };
}

# Get all categories
sub get_categories {
    my ($self) = @_;
    return $self->{categories};
}

# Get a specific category by key
sub get_category {
    my ($self, $category_key) = @_;
    return $self->{categories}->{$category_key};
}

# Get all pages
sub get_pages {
    my ($self) = @_;
    return $self->{pages};
}

# Get a specific page by ID
sub get_page {
    my ($self, $page_id) = @_;
    return $self->{pages_by_id}->{$page_id};
}

# Alias for get_page for compatibility
sub get_page_by_id {
    my ($self, $page_id) = @_;
    return $self->get_page($page_id);
}

# Check if user has access to a specific page
sub user_has_access {
    my ($self, $page_data, $user_role, $current_site) = @_;
    
    # Check if page data exists
    return 0 unless $page_data;
    
    # Check site access
    my $page_site = $page_data->{site} || 'all';
    if ($page_site ne 'all' && $page_site ne $current_site) {
        return 0;
    }
    
    # Check role access
    if ($page_data->{roles} && ref $page_data->{roles} eq 'ARRAY') {
        my $has_role = 0;
        foreach my $page_role (@{$page_data->{roles}}) {
            if ($page_role eq $user_role || ($page_role eq 'normal' && $user_role)) {
                $has_role = 1;
                last;
            }
        }
        return $has_role;
    }
    
    # Default to allow access if no roles specified
    return 1;
}

# Get pages by category
sub get_pages_by_category {
    my ($self, $category) = @_;
    return $self->{pages_by_category}->{$category} || [];
}

# Get pages by site
sub get_pages_by_site {
    my ($self, $site) = @_;

    # If site is not specified, return all pages
    return $self->{pages} unless $site;

    # Return pages for the specified site and pages for all sites
    my @pages = ();

    # Add pages for all sites
    if (exists $self->{pages_by_site}->{all}) {
        push @pages, @{$self->{pages_by_site}->{all}};
    }

    # Add pages for the specified site
    if (exists $self->{pages_by_site}->{$site}) {
        push @pages, @{$self->{pages_by_site}->{$site}};
    }

    return \@pages;
}

# Filter pages by role
sub filter_pages_by_role {
    my ($self, $pages, $role) = @_;

    # If role is not specified, return all pages
    return $pages unless $role;

    # Filter pages by role
    my @filtered_pages = ();

    foreach my $page (@$pages) {
        # Check if the user has the required role
        my $has_role = 0;
        foreach my $page_role (@{$page->{roles}}) {
            if ($page_role eq $role || ($page_role eq 'normal' && $role)) {
                $has_role = 1;
                last;
            }
        }

        # Add page if user has the required role
        push @filtered_pages, $page if $has_role;
    }

    return \@filtered_pages;
}

# Get filtered pages by site and role
sub get_filtered_pages {
    my ($self, $site, $role) = @_;

    # Get pages for the site
    my $pages = $self->get_pages_by_site($site);

    # Filter pages by role
    return $self->filter_pages_by_role($pages, $role);
}

# Get filtered categories by role
sub get_filtered_categories {
    my ($self, $role) = @_;

    # If role is not specified, return all categories
    return $self->{categories} unless $role;

    # Filter categories by role
    my %filtered_categories = ();

    foreach my $category_key (keys %{$self->{categories}}) {
        my $category = $self->{categories}->{$category_key};

        # Check if the user has the required role
        my $has_role = 0;
        foreach my $category_role (@{$category->{roles}}) {
            if ($category_role eq $role || ($category_role eq 'normal' && $role)) {
                $has_role = 1;
                last;
            }
        }

        # Add category if user has the required role
        $filtered_categories{$category_key} = $category if $has_role;
    }

    return \%filtered_categories;
}

# Add a new page to the configuration
sub add_page {
    my ($self, $page_data) = @_;
    
    # Validate required fields
    die "Page data is required" unless $page_data;
    die "Page ID is required" unless $page_data->{id};
    die "Page path is required" unless $page_data->{path};
    die "Page title is required" unless $page_data->{title};
    
    # Check if page already exists
    if (exists $self->{pages_by_id}->{$page_data->{id}}) {
        die "Page with ID '$page_data->{id}' already exists";
    }
    
    # Add to pages array
    push @{$self->{pages}}, $page_data;
    
    # Add to ID index
    $self->{pages_by_id}->{$page_data->{id}} = $page_data;
    
    # Add to category index
    if ($page_data->{categories}) {
        foreach my $category (@{$page_data->{categories}}) {
            $self->{pages_by_category}->{$category} ||= [];
            push @{$self->{pages_by_category}->{$category}}, $page_data;
        }
    }
    
    # Add to site index
    my $site = $page_data->{site} || 'all';
    $self->{pages_by_site}->{$site} ||= [];
    push @{$self->{pages_by_site}->{$site}}, $page_data;
    
    return 1;
}

# Save configuration to JSON file
sub save_config {
    my ($self) = @_;
    
    use FindBin;
    my $config_file = File::Spec->catfile($FindBin::Bin, '..', 'root', 'Documentation', 'config', 'documentation_config.json');
    
    try {
        # Prepare configuration data
        my $config_data = {
            categories => $self->{categories},
            pages => $self->{pages}
        };
        
        # Write to file
        open my $fh, '>:encoding(UTF-8)', $config_file or die "Cannot write to $config_file: $!";
        print $fh JSON->new->pretty->encode($config_data);
        close $fh;
        
        Comserv::Util::Logging::log_to_file(
            "Documentation configuration saved successfully to $config_file",
            undef, 'INFO'
        );
        
        return 1;
    } catch {
        my $error = $_;
        Comserv::Util::Logging::log_to_file(
            "Error saving documentation configuration: $error",
            undef, 'ERROR'
        );
        die $error;
    };
}

# Reload configuration from JSON file
sub reload_config {
    my ($self) = @_;

    # Clear existing data
    $self->{categories} = {};
    $self->{pages} = [];
    $self->{pages_by_id} = {};
    $self->{pages_by_category} = {};
    $self->{pages_by_site} = {};

    # Load configuration
    $self->load_config();

    return 1;
}

__PACKAGE__->meta->make_immutable;

1;