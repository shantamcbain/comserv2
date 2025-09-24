package Comserv::Util::DocumentationConfig;

use strict;
use warnings;
use Moose;
use namespace::autoclean;
use JSON;
use Try::Tiny;
use Comserv::Util::Logging;
use File::Spec;

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

    my $config_file = File::Spec->catfile('config', 'documentation_config.json');

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

# Save configuration to JSON file
sub save_config {
    my ($self) = @_;
    
    my $config_file = File::Spec->catfile('config', 'documentation_config.json');
    
    try {
        # Prepare data structure for JSON
        my $config_data = {
            categories => $self->{categories},
            pages => $self->{pages}
        };
        
        # Encode to JSON with pretty formatting
        my $json_text = JSON->new->pretty->canonical->encode($config_data);
        
        # Write to file
        open my $fh, '>:encoding(UTF-8)', $config_file or die "Cannot write to $config_file: $!";
        print $fh $json_text;
        close $fh;
        
        # Clear the singleton instance to force fresh reload
        $instance = undef;
        
        # Force reload of the current instance data from the file we just wrote
        $self->reload_config();
        
        Comserv::Util::Logging::log_to_file(
            "Saved documentation configuration: " .
                scalar(keys %{$self->{categories}}) . " categories, " .
                scalar(@{$self->{pages}}) . " pages",
            undef, 'INFO'
        );
        
        return 1;
    } catch {
        Comserv::Util::Logging::log_to_file(
            "Error saving documentation configuration: $_",
            undef, 'ERROR'
        );
        return 0;
    };
}

# Update a page's roles and save to file
sub update_page_roles {
    my ($self, $page_id, $new_roles) = @_;
    
    # Find the page in the pages array
    foreach my $page (@{$self->{pages}}) {
        if ($page->{id} eq $page_id) {
            # Update roles
            $page->{roles} = $new_roles;
            
            # Update the indexed version
            $self->{pages_by_id}->{$page_id} = $page;
            
            # Save to file
            my $success = $self->save_config();
            
            if ($success) {
                # Note: save_config() now handles clearing singleton and reloading
                
                Comserv::Util::Logging::log_to_file(
                    "Updated roles for page '$page_id': " . join(', ', @$new_roles),
                    undef, 'INFO'
                );
            }
            
            return $success;
        }
    }
    
    # Page not found
    Comserv::Util::Logging::log_to_file(
        "Page '$page_id' not found for role update",
        undef, 'WARN'
    );
    return 0;
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