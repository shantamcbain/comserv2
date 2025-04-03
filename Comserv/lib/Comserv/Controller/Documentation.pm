package Comserv::Controller::Documentation;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;
use File::Find;
use File::Basename;
use DateTime;
use Try::Tiny;
use Template::Stash;
use JSON;
use Text::Markdown;

BEGIN { extends 'Catalyst::Controller'; }

# Set up Template::Stash to allow raw HTML output
$Template::Stash::SCALAR_OPS->{raw} = sub {
    return Template::Stash::SCALAR_OPS->{html} ? $_[0] : $_[0];
};

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

# Store documentation pages with metadata
has 'documentation_pages' => (
    is => 'ro',
    default => sub { {} },
    lazy => 1,
);

# Store documentation categories
has 'documentation_categories' => (
    is => 'ro',
    default => sub {
        my $self = shift;
        return $self->_load_documentation_config()->{categories} || {
            'user_guides' => {
                title => 'User Guides',
                description => 'Documentation for end users of the system',
                pages => ['user_guide', 'getting_started', 'faq'],
                roles => ['normal', 'editor', 'admin', 'developer'],
                site_specific => 0,
            },
            'admin_guides' => {
                title => 'Administrator Guides',
                description => 'Documentation for system administrators',
                pages => ['admin_guide', 'installation', 'configuration'],
                roles => ['admin'],
                site_specific => 0,
            },
            'developer_guides' => {
                title => 'Developer Documentation',
                description => 'Documentation for developers',
                pages => ['api_reference', 'database_schema', 'coding_standards'],
                roles => ['developer'],
                site_specific => 0,
            },
            'tutorials' => {
                title => 'Tutorials',
                description => 'Step-by-step guides for common tasks',
                pages => [],
                roles => ['normal', 'editor', 'admin', 'developer'],
                site_specific => 0,
            },
            'site_specific' => {
                title => 'Site-Specific Documentation',
                description => 'Documentation specific to this site',
                pages => [],
                roles => ['normal', 'editor', 'admin', 'developer'],
                site_specific => 1,
            },
            'modules' => {
                title => 'Module Documentation',
                description => 'Documentation for specific system modules',
                pages => [],
                roles => ['admin', 'developer'],
                site_specific => 0,
            },
        };
    },
    lazy => 1,
);

# Store default paths for documentation pages
has 'default_paths' => (
    is => 'ro',
    default => sub {
        my $self = shift;
        return $self->_load_documentation_config()->{default_paths} || {};
    },
    lazy => 1,
);

# Initialize - scan for documentation files
sub BUILD {
    my ($self) = @_;

    # Log the start of BUILD
    my $file = __FILE__;
    my $line = __LINE__;
    Comserv::Util::Logging::log_to_file("[$file:$line] Starting BUILD method for Documentation controller", undef, 'INFO');

    # Call scan_documentation_files to populate documentation pages from JSON configuration
    $self->scan_documentation_files();

    # Log completion of BUILD
    Comserv::Util::Logging::log_to_file("[$file:$line] Completed BUILD method for Documentation controller", undef, 'INFO');
}

# Scan for documentation files and populate documentation_pages
sub scan_documentation_files {
    my ($self) = @_;

    # Clear existing documentation pages
    %{$self->documentation_pages} = ();

    # Log the start of scan
    my $file = __FILE__;
    my $line = __LINE__;
    Comserv::Util::Logging::log_to_file("[$file:$line] Starting scan_documentation_files method", undef, 'INFO');

    # Load configuration from JSON file
    my $config = $self->_load_documentation_config();

    # If we have categories in the config, use them
    if ($config && $config->{categories}) {
        $self->{documentation_categories} = $config->{categories};
        Comserv::Util::Logging::log_to_file(
            "Loaded " . scalar(keys %{$config->{categories}}) . " categories from configuration",
            undef, 'INFO'
        );
    }

    # If we have default paths in the config, use them to populate documentation_pages
    if ($config && $config->{default_paths}) {
        my $default_paths = $config->{default_paths};
        Comserv::Util::Logging::log_to_file(
            "Loading " . scalar(keys %$default_paths) . " pages from configuration",
            undef, 'INFO'
        );

        # Process each page in the configuration
        foreach my $page_id (keys %$default_paths) {
            my $path = $default_paths->{$page_id};

            # Skip if path doesn't exist in the filesystem
            unless (-e "root/$path") {
                Comserv::Util::Logging::log_to_file(
                    "Warning: File not found for page '$page_id': root/$path",
                    undef, 'WARN'
                );
                next;
            }

            # Determine site and role requirements based on path
            my $site = 'all';
            my @roles = ('normal', 'editor', 'admin', 'developer');

            # Check if this is site-specific documentation
            if ($path =~ m{Documentation/sites/([^/]+)/}) {
                $site = uc($1); # Convert site name to uppercase to match SiteName format
            }

            # Check if this is role-specific documentation
            if ($path =~ m{Documentation/roles/([^/]+)/}) {
                my $role = $1;
                if ($role eq 'admin') {
                    @roles = ('admin', 'developer');
                } elsif ($role eq 'developer') {
                    @roles = ('developer');
                } elsif ($role eq 'editor') {
                    @roles = ('editor', 'admin', 'developer');
                }
            }

            # Determine file format
            my $format = 'unknown';
            if ($path =~ /\.md$/i) {
                $format = 'markdown';
            } elsif ($path =~ /\.tt$/i) {
                $format = 'template';
            }

            # Store the page with metadata
            $self->documentation_pages->{$page_id} = {
                path => $path,
                site => $site,
                roles => \@roles,
                format => $format,
                original_name => $page_id,
                display_name => $self->_format_title($page_id)
            };

            Comserv::Util::Logging::log_to_file(
                "Added page '$page_id' from configuration: path=$path, site=$site, format=$format",
                undef, 'INFO'
            );
        }
    } else {
        # If no configuration found, log an error - we no longer scan directories
        Comserv::Util::Logging::log_to_file(
            "No configuration found or empty configuration. Please create a valid documentation_config.json file.",
            undef, 'ERROR'
        );
    }

    # Ensure all pages are properly categorized
    $self->_categorize_pages();

    # Log completion
    Comserv::Util::Logging::log_to_file(
        "Completed scan_documentation_files. Found " . scalar(keys %{$self->documentation_pages}) . " pages.",
        undef, 'INFO'
    );
}

# This method has been removed as part of the migration to JSON-only configuration
# Documentation files are now managed exclusively through the documentation_config.json file

# Categorize pages based on their paths
sub _categorize_pages {
    my ($self) = @_;

    Comserv::Util::Logging::log_to_file("Categorizing documentation pages", undef, 'INFO');

    # Clear existing category pages
    foreach my $category_key (keys %{$self->documentation_categories}) {
        $self->documentation_categories->{$category_key}->{pages} = [];
    }

    # Categorize each page
    foreach my $page_id (keys %{$self->documentation_pages}) {
        my $page = $self->documentation_pages->{$page_id};
        my $path = $page->{path};
        my $site = $page->{site};

        # Add to appropriate categories
        foreach my $category_key (keys %{$self->documentation_categories}) {
            my $category = $self->documentation_categories->{$category_key};

            # Add to site-specific category if applicable
            if ($category_key eq 'site_specific' && $site ne 'all') {
                push @{$category->{pages}}, $page_id unless grep { $_ eq $page_id } @{$category->{pages}};
                Comserv::Util::Logging::log_to_file(
                    "Added '$page_id' to site-specific category (site: $site)", undef, 'INFO');
            }

            # Add to module category if it's in a module directory
            if ($category_key eq 'modules' && $path =~ m{Documentation/modules/}) {
                push @{$category->{pages}}, $page_id unless grep { $_ eq $page_id } @{$category->{pages}};
                Comserv::Util::Logging::log_to_file(
                    "Added '$page_id' to modules category", undef, 'INFO');
            }

            # Add to tutorials if it's in the tutorials directory
            if ($category_key eq 'tutorials' && $path =~ m{Documentation/tutorials/}) {
                push @{$category->{pages}}, $page_id unless grep { $_ eq $page_id } @{$category->{pages}};
                Comserv::Util::Logging::log_to_file(
                    "Added '$page_id' to tutorials category", undef, 'INFO');
            }

            # Add to user guides if it's in the normal roles directory
            if ($category_key eq 'user_guides' && $path =~ m{Documentation/roles/normal/}) {
                push @{$category->{pages}}, $page_id unless grep { $_ eq $page_id } @{$category->{pages}};
                Comserv::Util::Logging::log_to_file(
                    "Added '$page_id' to user_guides category", undef, 'INFO');
            }

            # Add to admin guides if it's in the admin roles directory
            if ($category_key eq 'admin_guides' && $path =~ m{Documentation/roles/admin/}) {
                push @{$category->{pages}}, $page_id unless grep { $_ eq $page_id } @{$category->{pages}};
                Comserv::Util::Logging::log_to_file(
                    "Added '$page_id' to admin_guides category", undef, 'INFO');
            }

            # Add to developer guides if it's in the developer roles directory
            if ($category_key eq 'developer_guides' && $path =~ m{Documentation/roles/developer/}) {
                push @{$category->{pages}}, $page_id unless grep { $_ eq $page_id } @{$category->{pages}};
                Comserv::Util::Logging::log_to_file(
                    "Added '$page_id' to developer_guides category", undef, 'INFO');
            }

            # Also add to changelog category if it's in the changelog directory
            if ($category_key eq 'changelog' && $path =~ m{Documentation/changelog/}) {
                # Create the changelog category if it doesn't exist
                unless (exists $self->documentation_categories->{changelog}) {
                    $self->documentation_categories->{changelog} = {
                        title => 'Changelog',
                        description => 'System changes and updates',
                        pages => [],
                        roles => ['normal', 'editor', 'admin', 'developer'],
                        site_specific => 0,
                    };
                }

                push @{$self->documentation_categories->{changelog}->{pages}}, $page_id
                    unless grep { $_ eq $page_id } @{$self->documentation_categories->{changelog}->{pages}};

                Comserv::Util::Logging::log_to_file(
                    "Added '$page_id' to changelog category", undef, 'INFO');
            }
        }
    }

    # Add any files in the root Documentation directory to a "General" category
    my $general_category_exists = 0;
    foreach my $page_id (keys %{$self->documentation_pages}) {
        my $page = $self->documentation_pages->{$page_id};
        my $path = $page->{path};

        # Check if the file is directly in the Documentation directory (not in a subdirectory)
        if ($path =~ m{^Documentation/[^/]+\.(md|tt)$}) {
            # Create the general category if it doesn't exist
            unless (exists $self->documentation_categories->{general}) {
                $self->documentation_categories->{general} = {
                    title => 'General Documentation',
                    description => 'General system documentation',
                    pages => [],
                    roles => ['normal', 'editor', 'admin', 'developer'],
                    site_specific => 0,
                };
                $general_category_exists = 1;
            }

            push @{$self->documentation_categories->{general}->{pages}}, $page_id
                unless grep { $_ eq $page_id } @{$self->documentation_categories->{general}->{pages}};

            Comserv::Util::Logging::log_to_file(
                "Added '$page_id' to general category", undef, 'INFO');
        }
    }

    # Log the number of pages in each category
    foreach my $category_key (keys %{$self->documentation_categories}) {
        my $category = $self->documentation_categories->{$category_key};
        my $page_count = scalar(@{$category->{pages}});

        Comserv::Util::Logging::log_to_file(
            "Category '$category_key' has $page_count pages", undef, 'INFO');
    }

    Comserv::Util::Logging::log_to_file("Page categorization completed", undef, 'INFO');
}

# Debug documentation index
sub debug :Local :Args(0) {
    my ($self, $c) = @_;

    # Log the action
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'debug', "Debugging documentation index");

    # Get all documentation pages
    my $pages = $self->documentation_pages;

    # Create a debug output
    my $debug_output = "Documentation Pages (" . scalar(keys %$pages) . " total):\n\n";

    # Count file types
    my $md_count = 0;
    my $tt_count = 0;
    my $other_count = 0;

    foreach my $page_name (sort keys %$pages) {
        my $metadata = $pages->{$page_name};
        $debug_output .= "Page: $page_name\n";
        $debug_output .= "  Path: $metadata->{path}\n";
        $debug_output .= "  Site: $metadata->{site}\n";
        $debug_output .= "  Format: $metadata->{format}\n";
        $debug_output .= "  Original Name: $metadata->{original_name}\n";
        $debug_output .= "  Display Name: $metadata->{display_name}\n";
        $debug_output .= "  Roles: " . join(", ", @{$metadata->{roles}}) . "\n\n";

        # Count by format
        if ($metadata->{format} eq 'markdown') {
            $md_count++;
        } elsif ($metadata->{format} eq 'template') {
            $tt_count++;
        } else {
            $other_count++;
        }
    }

    # Add file type summary
    $debug_output .= "\nFile Type Summary:\n";
    $debug_output .= "  Markdown (.md) files: $md_count\n";
    $debug_output .= "  Template (.tt) files: $tt_count\n";
    $debug_output .= "  Other file types: $other_count\n\n";

    # Add categories debug info
    $debug_output .= "\nDocumentation Categories:\n\n";

    foreach my $category_key (sort keys %{$self->documentation_categories}) {
        my $category = $self->documentation_categories->{$category_key};
        $debug_output .= "Category: $category_key\n";
        $debug_output .= "  Title: $category->{title}\n";
        $debug_output .= "  Description: $category->{description}\n";
        $debug_output .= "  Pages (" . scalar(@{$category->{pages}}) . " total): " . join(", ", @{$category->{pages}}) . "\n";
        $debug_output .= "  Roles: " . join(", ", @{$category->{roles}}) . "\n";
        $debug_output .= "  Site Specific: " . ($category->{site_specific} ? "Yes" : "No") . "\n\n";
    }

    # Add JSON configuration info
    my $config = $self->_load_documentation_config();
    $debug_output .= "\nJSON Configuration:\n\n";

    if ($config && $config->{default_paths}) {
        $debug_output .= "Default Paths in JSON (" . scalar(keys %{$config->{default_paths}}) . " total):\n";
        foreach my $page_id (sort keys %{$config->{default_paths}}) {
            $debug_output .= "  $page_id: " . $config->{default_paths}->{$page_id} . "\n";

            # Check if this path exists in the filesystem
            my $full_path = "root/" . $config->{default_paths}->{$page_id};
            if (-e $full_path) {
                $debug_output .= "    [EXISTS]\n";
            } else {
                $debug_output .= "    [MISSING]\n";
            }
        }
    } else {
        $debug_output .= "No default paths found in JSON configuration.\n";
    }

    # Add directory structure info
    $debug_output .= "\nDocumentation Directory Structure:\n\n";

    # Check for key directories
    my @key_dirs = (
        "root/Documentation/roles/normal",
        "root/Documentation/roles/admin",
        "root/Documentation/roles/developer",
        "root/Documentation/sites",
        "root/Documentation/tutorials",
        "root/Documentation/modules",
        "root/Documentation/changelog"
    );

    foreach my $dir (@key_dirs) {
        $debug_output .= "$dir: ";
        if (-d $dir) {
            $debug_output .= "[EXISTS]\n";

            # Count files in this directory
            my $md_files = 0;
            my $tt_files = 0;
            my $other_files = 0;

            if (opendir(my $dh, $dir)) {
                while (my $file = readdir($dh)) {
                    next if $file =~ /^\.\.?$/;  # Skip . and ..
                    next if -d "$dir/$file";     # Skip subdirectories

                    if ($file =~ /\.md$/i) {
                        $md_files++;
                    } elsif ($file =~ /\.tt$/i) {
                        $tt_files++;
                    } else {
                        $other_files++;
                    }
                }
                closedir($dh);

                $debug_output .= "    Files: $md_files .md, $tt_files .tt, $other_files other\n";
            } else {
                $debug_output .= "    [ERROR: Could not open directory]\n";
            }
        } else {
            $debug_output .= "[MISSING]\n";
        }
    }

    # Log the debug output
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'debug', $debug_output);

    # Add debug info to stash
    if ($c->session->{debug_mode}) {
        $c->stash->{debug_msg} = [] unless defined $c->stash->{debug_msg};
        push @{$c->stash->{debug_msg}}, "Generated debug output for documentation system";
    }

    # Display the debug output
    $c->response->content_type('text/plain');
    $c->response->body($debug_output);
}

# Configuration management page
sub config :Local :Args(0) {
    my ($self, $c) = @_;

    # Check if user has admin or developer role
    unless ($c->user_exists && ($c->user->role eq 'admin' || $c->user->role eq 'developer')) {
        $c->stash(error_msg => "You don't have permission to access this page");
        $c->detach('/error/access_denied');
        return;
    }

    # Log the action
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'config', "Accessing documentation configuration");

    # Add debug message to stash
    if ($c->session->{debug_mode}) {
        $c->stash->{debug_msg} = [] unless defined $c->stash->{debug_msg};
        push @{$c->stash->{debug_msg}}, "Accessing documentation configuration page";
    }

    # Get all documentation pages
    my $pages = $self->documentation_pages;

    # Get all categories
    my $categories = $self->documentation_categories;

    # Add to stash
    $c->stash(
        pages => $pages,
        categories => $categories,
        template => 'Documentation/config.tt'
    );
}

# Main documentation index
sub index :Path :Args(0) {
    my ($self, $c) = @_;

    # Log the action
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Accessing documentation index");

    # Get the current user's role
    my $user_role = 'normal';  # Default to normal user
    if ($c->user_exists) {
        $user_role = $c->user->role || 'normal';
    }

    # Get the current site name
    my $site_name = $c->stash->{SiteName} || 'default';

    # Log user role and site for debugging
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
        "User role: $user_role, Site: $site_name");

    # Initialize debug messages array if debug mode is enabled
    if ($c->session->{debug_mode}) {
        $c->stash->{debug_msg} = [] unless defined $c->stash->{debug_msg};
        push @{$c->stash->{debug_msg}}, "Documentation index - User role: $user_role, Site: $site_name";
    }

    # Get all documentation pages
    my $pages = $self->documentation_pages;

    # Add debug info about total pages
    if ($c->session->{debug_mode}) {
        push @{$c->stash->{debug_msg}}, "Total documentation pages: " . scalar(keys %$pages);
    }

    # Filter pages based on user role and site
    my %filtered_pages;
    foreach my $page_name (keys %$pages) {
        my $metadata = $pages->{$page_name};

        # Special case: CSC site admins can see all documentation
        if ($site_name eq 'CSC' && $user_role eq 'admin') {
            $filtered_pages{$page_name} = $metadata;
            next;
        }

        # For other users, apply normal filtering rules:

        # 1. Site-specific documentation is only visible to its respective site
        if ($metadata->{site} ne 'all' && $metadata->{site} ne $site_name) {
            if ($c->session->{debug_mode}) {
                push @{$c->stash->{debug_msg}}, "Skipping page '$page_name' - site mismatch (page site: $metadata->{site}, current site: $site_name)";
            }
            next;
        }

        # 2. Role-specific documentation is filtered by user role
        my $has_role = 0;
        foreach my $role (@{$metadata->{roles}}) {
            if ($role eq $user_role || ($role eq 'normal' && $user_role)) {
                $has_role = 1;
                last;
            }
        }

        unless ($has_role) {
            if ($c->session->{debug_mode}) {
                push @{$c->stash->{debug_msg}}, "Skipping page '$page_name' - role mismatch (page roles: " .
                    join(", ", @{$metadata->{roles}}) . ", user role: $user_role)";
            }
            next;
        }

        # Add to filtered pages
        $filtered_pages{$page_name} = $metadata;

        if ($c->session->{debug_mode}) {
            push @{$c->stash->{debug_msg}}, "Including page '$page_name' - site: $metadata->{site}, path: $metadata->{path}";
        }
    }

    # Log the number of filtered pages
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
        "Filtered documentation pages: " . scalar(keys %filtered_pages) .
        " (Site: $site_name, Role: $user_role)");

    # Sort pages alphabetically for better presentation
    my @sorted_pages = sort keys %filtered_pages;

    # Create a structured list of documentation pages with metadata
    my $structured_pages = {};
    foreach my $page_name (@sorted_pages) {
        my $metadata = $filtered_pages{$page_name};
        my $path = $metadata->{path};
        my $title = $self->_format_title($page_name);

        # Use the full path to ensure we're linking to the correct document
        # This ensures each category links to its own specific document
        my $url;

        # Log the path for debugging
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
            "Processing page: $page_name, Path: $path");

        if ($path =~ /\.md$/) {
            # For markdown files, use the view action with the full path
            $url = $c->uri_for($self->action_for('view'), [$path]);
        } else {
            # For other files, use the view action with just the page name
            $url = $c->uri_for($self->action_for('view'), [$page_name]);
        }

        $structured_pages->{$page_name} = {
            title => $title,
            path => $path,
            url => $url,
            site => $metadata->{site},
            roles => $metadata->{roles},
        };
    }

    # Get categories filtered by user role
    my %filtered_categories;
    foreach my $category_key (keys %{$self->documentation_categories}) {
        my $category = $self->documentation_categories->{$category_key};

        # Skip if the user doesn't have the required role
        my $has_role = 0;
        foreach my $role (@{$category->{roles}}) {
            if ($role eq $user_role || ($role eq 'normal' && $user_role)) {
                $has_role = 1;
                last;
            }
        }

        unless ($has_role) {
            if ($c->session->{debug_mode}) {
                push @{$c->stash->{debug_msg}}, "Skipping category '$category_key' - role mismatch (category roles: " .
                    join(", ", @{$category->{roles}}) . ", user role: $user_role)";
            }
            next;
        }

        # Skip site-specific categories if not relevant to this site
        if ($category->{site_specific} && !$self->_has_site_specific_docs($site_name, \%filtered_pages)) {
            if ($c->session->{debug_mode}) {
                push @{$c->stash->{debug_msg}}, "Skipping site-specific category '$category_key' - no relevant docs for site: $site_name";
            }
            next;
        }

        # Add to filtered categories
        $filtered_categories{$category_key} = $category;

        if ($c->session->{debug_mode}) {
            push @{$c->stash->{debug_msg}}, "Including category '$category_key' - title: $category->{title}";
        }

        # If this is the site-specific category, populate it with site-specific pages
        if ($category_key eq 'site_specific') {
            my @site_pages;
            foreach my $page_name (keys %filtered_pages) {
                if ($filtered_pages{$page_name}->{site} eq $site_name) {
                    push @site_pages, $page_name;
                    if ($c->session->{debug_mode}) {
                        push @{$c->stash->{debug_msg}}, "Adding page '$page_name' to site-specific category for site: $site_name";
                    }
                }
            }
            $filtered_categories{$category_key}->{pages} = \@site_pages;

            if ($c->session->{debug_mode}) {
                push @{$c->stash->{debug_msg}}, "Site-specific category has " . scalar(@site_pages) . " pages for site: $site_name";
            }
        }
    }

    # Load the completed items JSON file
    my $json_file = $c->path_to('root', 'Documentation', 'completed_items.json');
    my $completed_items = [];

    if (-e $json_file) {
        # Read the JSON file
        eval {
            open my $fh, '<:encoding(UTF-8)', $json_file or die "Cannot open $json_file: $!";
            my $json_content = do { local $/; <$fh> };
            close $fh;

            # Parse the JSON content
            require JSON;
            my $data = JSON::decode_json($json_content);

            # Sort items by date_created in descending order (newest first)
            $completed_items = [
                sort { $b->{date_created} cmp $a->{date_created} }
                @{$data->{completed_items}}
            ];

            if ($c->session->{debug_mode}) {
                push @{$c->stash->{debug_msg}}, "Loaded " . scalar(@$completed_items) . " completed items from JSON";
            }
        };
        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'index', "Error loading completed items JSON: $@");
            if ($c->session->{debug_mode}) {
                push @{$c->stash->{debug_msg}}, "Error loading completed items JSON: $@";
            }
        }
    } else {
        if ($c->session->{debug_mode}) {
            push @{$c->stash->{debug_msg}}, "Completed items JSON file not found: $json_file";
        }
    }

    # Add pages and completed items to stash
    $c->stash(
        documentation_pages => \%filtered_pages,
        structured_pages => $structured_pages,
        sorted_page_names => \@sorted_pages,
        completed_items => $completed_items,
        categories => \%filtered_categories,
        user_role => $user_role,
        site_name => $site_name,
        template => 'Documentation/index.tt',
        debug_mode => $c->session->{debug_mode} || 0
    );

    $c->forward($c->view('TT'));
}

# Helper method to check if there are site-specific docs for a site
sub _has_site_specific_docs {
    my ($self, $site_name, $filtered_pages) = @_;

    foreach my $page_name (keys %$filtered_pages) {
        if ($filtered_pages->{$page_name}->{site} eq $site_name) {
            return 1;
        }
    }

    return 0;
}

# Helper method to format page titles
sub _format_title {
    my ($self, $page_name) = @_;

    # Convert underscores to spaces
    my $title = $page_name;
    $title =~ s/_/ /g;

    # Capitalize each word
    $title = join(' ', map { ucfirst } split(/\s+/, $title));

    # Special case for API to be all caps
    $title =~ s/\bApi\b/API/g;

    return $title;
}

# View a documentation page
sub view :Local {
    my ($self, $c) = @_;

    # Log the action
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view', "Viewing documentation page");

    # Get the path or page_id from the query parameters
    my $path = $c->request->query_parameters->{path};
    my $page_id = $c->request->query_parameters->{page_id};

    # If no path or page_id is provided, check if it's in the path_info
    unless ($path || $page_id) {
        my $path_info = $c->request->path_info;
        if ($path_info =~ m{/documentation/view/(.+)}) {
            $path = $1;
        }
    }

    # If still no path or page_id, redirect to the index
    unless ($path || $page_id) {
        $c->flash->{error_msg} = "No documentation page specified";
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }

    # Log the requested path or page_id
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view',
        "Requested documentation: " . ($path ? "path=$path" : "page_id=$page_id"));

    # If we have a page_id but no path, look up the path
    if ($page_id && !$path) {
        if (exists $self->documentation_pages->{$page_id}) {
            $path = $self->documentation_pages->{$page_id}->{path};
        } else {
            # Try to find the page by its original name
            foreach my $key (keys %{$self->documentation_pages}) {
                if ($self->documentation_pages->{$key}->{original_name} eq $page_id) {
                    $path = $self->documentation_pages->{$key}->{path};
                    last;
                }
            }
        }
    }

    # If we still don't have a path, redirect to the index
    unless ($path) {
        $c->flash->{error_msg} = "Documentation page not found: $page_id";
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }

    # Check if the file exists
    my $full_path = "root/$path";
    unless (-e $full_path) {
        $c->flash->{error_msg} = "Documentation file not found: $path";
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }

    # Determine the file format
    my $format = 'unknown';
    if ($path =~ /\.md$/i) {
        $format = 'markdown';
    } elsif ($path =~ /\.tt$/i) {
        $format = 'template';
    }

    # Read the file content
    my $content = '';
    eval {
        open my $fh, '<:encoding(UTF-8)', $full_path or die "Cannot open $full_path: $!";
        $content = do { local $/; <$fh> };
        close $fh;
    };

    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'view', "Error reading file: $@");
        $c->flash->{error_msg} = "Error reading documentation file: $@";
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }

    # Get the page name from the path
    my $page_name = $path;
    $page_name =~ s/.*\///; # Remove directory part
    $page_name =~ s/\.[^.]+$//; # Remove extension

    # Format the title
    my $title = $self->_format_title($page_name);

    # Process the content based on format
    if ($format eq 'markdown') {
        # Convert markdown to HTML
        my $markdown = Text::Markdown->new;
        $content = $markdown->markdown($content);
    }

    # Add to stash
    $c->stash(
        template => $format eq 'markdown' ? 'Documentation/view.tt' : 'Documentation/view_template.tt',
        page_title => $title,
        page_content => $content,
        page_path => $path,
        format => $format
    );
}

# View a template file
sub view_template :Local :Args(0) {
    my ($self, $c) = @_;

    # Log the action
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view_template', "Viewing template file");

    # Get the path from the query parameters
    my $path = $c->request->query_parameters->{path};

    # If no path is provided, redirect to the index
    unless ($path) {
        $c->flash->{error_msg} = "No template path specified";
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }

    # Log the requested path
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view_template', "Requested template path: $path");

    # Check if the file exists
    my $full_path = "root/$path";
    unless (-e $full_path) {
        $c->flash->{error_msg} = "Template file not found: $path";
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }

    # Read the template file content
    my $content = '';
    eval {
        open my $fh, '<:encoding(UTF-8)', $full_path or die "Cannot open $full_path: $!";
        $content = do { local $/; <$fh> };
        close $fh;
    };

    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'view_template', "Error reading template file: $@");
        $c->flash->{error_msg} = "Error reading template file: $@";
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }

    # Get the page name from the path
    my $page_name = $path;
    $page_name =~ s/.*\///; # Remove directory part
    $page_name =~ s/\.[^.]+$//; # Remove extension

    # Format the title
    my $title = $self->_format_title($page_name);

    # Add to stash
    $c->stash(
        template => 'Documentation/view_template.tt',
        page_title => $title,
        page_content => $content,
        page_path => $path,
        format => 'template'
    );
}

# Refresh documentation index
sub refresh :Local :Args(0) {
    my ($self, $c) = @_;

    # Log the action
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'refresh', "Refreshing documentation index");

    # Add debug message to stash
    if ($c->session->{debug_mode}) {
        $c->stash->{debug_msg} = [] unless defined $c->stash->{debug_msg};
        push @{$c->stash->{debug_msg}}, "Starting documentation refresh...";
    }

    # First, update the configuration with any new files
    $self->_update_documentation_config();

    # Then rescan documentation files from the updated JSON configuration
    $self->scan_documentation_files();

    # Save the current configuration back to JSON
    $self->_save_documentation_config();

    # Get the count of documentation pages
    my $page_count = scalar(keys %{$self->documentation_pages});

    # Log completion with detailed information
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'refresh',
        "Documentation index refreshed. Found $page_count documentation pages");

    # Add debug message with page count
    if ($c->session->{debug_mode}) {
        push @{$c->stash->{debug_msg}}, "Documentation refresh completed. Found $page_count pages.";
    }

    # Add a success message to the stash
    $c->stash->{status_msg} = "Documentation index refreshed successfully. Found $page_count documentation pages.";

    # Redirect back to the documentation index
    $c->response->redirect($c->uri_for($self->action_for('index')));
    $c->detach();
}

# Update documentation configuration with any new files found
sub _update_documentation_config {
    my ($self) = @_;

    Comserv::Util::Logging::log_to_file("Updating documentation configuration with new files", undef, 'INFO');

    # Load the current configuration
    my $config = $self->_load_documentation_config();

    # Initialize default_paths if it doesn't exist
    $config->{default_paths} ||= {};

    # Scan for .tt and .md files
    my $doc_dir = "root/Documentation";
    if (-d $doc_dir) {
        my @found_files;

        # Use File::Find to locate all .tt and .md files
        find(
            {
                wanted => sub {
                    my $file = $_;
                    # Skip directories
                    return if -d $file;

                    # Only process .tt and .md files
                    return unless $file =~ /\.(tt|md)$/i;

                    my $path = $File::Find::name;
                    $path =~ s/^root\///; # Remove 'root/' prefix

                    # Skip configuration files
                    return if $path =~ m{Documentation/.*_config\.json$};
                    # Skip completed_items.json
                    return if $path =~ m{Documentation/completed_items\.json$};
                    # Skip specific directories that don't contain documentation
                    return if $path =~ m{Documentation/config/};

                    push @found_files, {
                        path => $path,
                        basename => basename($file)
                    };
                },
                no_chdir => 1,
            },
            $doc_dir
        );

        # Check if each found file is already in the configuration
        foreach my $file_info (@found_files) {
            my $path = $file_info->{path};
            my $basename = $file_info->{basename};

            # Check if this path is already in the configuration
            my $exists = 0;
            foreach my $page_id (keys %{$config->{default_paths}}) {
                if ($config->{default_paths}->{$page_id} eq $path) {
                    $exists = 1;
                    last;
                }
            }

            # If not in configuration, add it
            if (!$exists) {
                # Create a unique key for this file
                my $key;

                # Handle .tt files and .md files
                if ($basename =~ /\.tt$/) {
                    $key = basename($basename, '.tt');
                } elsif ($basename =~ /\.md$/) {
                    $key = basename($basename, '.md');
                } else {
                    # Handle other file types (shouldn't happen with our filter)
                    my ($name, $ext) = split(/\./, $basename, 2);
                    $key = $name;
                }

                # Make the key unique by adding a prefix based on the path
                my $path_prefix = '';
                if ($path =~ m{Documentation/roles/([^/]+)/}) {
                    $path_prefix = $1 . '_';
                } elsif ($path =~ m{Documentation/sites/([^/]+)/}) {
                    $path_prefix = 'site_' . $1 . '_';
                } elsif ($path =~ m{Documentation/tutorials/}) {
                    $path_prefix = 'tutorial_';
                } elsif ($path =~ m{Documentation/modules/}) {
                    $path_prefix = 'module_';
                } elsif ($path =~ m{Documentation/changelog/}) {
                    $path_prefix = 'changelog_';
                }

                # Add file extension suffix for .tt files to distinguish them
                my $suffix = '';
                if ($basename =~ /\.tt$/) {
                    $suffix = '_tt';
                }

                # Create a unique key with the path prefix and suffix
                my $unique_key = $path_prefix . $key . $suffix;

                # Ensure the key is unique by adding a number if needed
                my $original_key = $unique_key;
                my $counter = 1;
                while (exists $config->{default_paths}->{$unique_key}) {
                    $unique_key = $original_key . "_" . $counter;
                    $counter++;
                }

                # Add to configuration
                $config->{default_paths}->{$unique_key} = $path;

                # Also add to appropriate category if we can determine it
                if ($path =~ m{Documentation/roles/normal/}) {
                    push @{$config->{categories}->{user_guides}->{pages}}, $unique_key
                        unless grep { $_ eq $unique_key } @{$config->{categories}->{user_guides}->{pages}};
                } elsif ($path =~ m{Documentation/roles/admin/}) {
                    push @{$config->{categories}->{admin_guides}->{pages}}, $unique_key
                        unless grep { $_ eq $unique_key } @{$config->{categories}->{admin_guides}->{pages}};
                } elsif ($path =~ m{Documentation/roles/developer/}) {
                    push @{$config->{categories}->{developer_guides}->{pages}}, $unique_key
                        unless grep { $_ eq $unique_key } @{$config->{categories}->{developer_guides}->{pages}};
                } elsif ($path =~ m{Documentation/sites/}) {
                    push @{$config->{categories}->{site_specific}->{pages}}, $unique_key
                        unless grep { $_ eq $unique_key } @{$config->{categories}->{site_specific}->{pages}};
                } elsif ($path =~ m{Documentation/tutorials/}) {
                    push @{$config->{categories}->{tutorials}->{pages}}, $unique_key
                        unless grep { $_ eq $unique_key } @{$config->{categories}->{tutorials}->{pages}};
                } elsif ($path =~ m{Documentation/modules/}) {
                    push @{$config->{categories}->{modules}->{pages}}, $unique_key
                        unless grep { $_ eq $unique_key } @{$config->{categories}->{modules}->{pages}};
                }

                # If it's a .tt file, also add to templates category
                if ($basename =~ /\.tt$/) {
                    # Create templates category if it doesn't exist
                    unless (exists $config->{categories}->{templates}) {
                        $config->{categories}->{templates} = {
                            title => 'Template Documentation',
                            description => 'Documentation in template format',
                            roles => ['normal', 'editor', 'admin', 'developer'],
                            site_specific => 0,
                            pages => []
                        };
                    }

                    push @{$config->{categories}->{templates}->{pages}}, $unique_key
                        unless grep { $_ eq $unique_key } @{$config->{categories}->{templates}->{pages}};
                }

                Comserv::Util::Logging::log_to_file(
                    "Added new file to configuration: $unique_key => $path",
                    undef, 'INFO'
                );
            }
        }

        # Save the updated configuration
        my $config_file = "root/Documentation/documentation_config.json";
        try {
            # Convert to JSON
            require JSON;
            my $json = JSON->new->pretty->encode($config);

            # Write to file
            open my $fh, '>:encoding(UTF-8)', $config_file or die "Cannot open $config_file for writing: $!";
            print $fh $json;
            close $fh;

            Comserv::Util::Logging::log_to_file(
                "Updated documentation configuration saved to $config_file",
                undef, 'INFO'
            );
        } catch {
            Comserv::Util::Logging::log_to_file(
                "Error saving updated documentation configuration to $config_file: $_",
                undef, 'ERROR'
            );
        };
    }
}

# Save documentation configuration to JSON file
sub _save_documentation_config {
    my ($self) = @_;

    my $config_file = "root/Documentation/documentation_config.json";

    # Create configuration object
    my $config = {
        categories => $self->documentation_categories,
        default_paths => {}
    };

    # Add default paths for all pages
    foreach my $page_id (keys %{$self->documentation_pages}) {
        $config->{default_paths}->{$page_id} = $self->documentation_pages->{$page_id}->{path};
    }

    try {
        # Convert to JSON
        require JSON;
        my $json = JSON->new->pretty->encode($config);

        # Write to file
        open my $fh, '>:encoding(UTF-8)', $config_file or die "Cannot open $config_file for writing: $!";
        print $fh $json;
        close $fh;

        Comserv::Util::Logging::log_to_file(
            "Saved documentation configuration to $config_file",
            undef, 'INFO'
        );
    } catch {
        Comserv::Util::Logging::log_to_file(
            "Error saving documentation configuration to $config_file: $_",
            undef, 'ERROR'
        );
    };
}

# Debug documentation index
sub debug :Local :Args(0) {
    my ($self, $c) = @_;

    # Log the action
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'debug', "Debugging documentation index");

    # Get all documentation pages
    my $pages = $self->documentation_pages;

    # Create a debug output
    my $debug_output = "Documentation Pages (" . scalar(keys %$pages) . " total):\n\n";

    foreach my $page_name (sort keys %$pages) {
        my $metadata = $pages->{$page_name};
        $debug_output .= "Page: $page_name\n";
        $debug_output .= "  Path: $metadata->{path}\n";
        $debug_output .= "  Site: $metadata->{site}\n";
        $debug_output .= "  Roles: " . join(", ", @{$metadata->{roles}}) . "\n\n";
    }

    # Add categories debug info
    $debug_output .= "\nDocumentation Categories:\n\n";

    foreach my $category_key (sort keys %{$self->documentation_categories}) {
        my $category = $self->documentation_categories->{$category_key};
        $debug_output .= "Category: $category_key\n";
        $debug_output .= "  Title: $category->{title}\n";
        $debug_output .= "  Description: $category->{description}\n";
        $debug_output .= "  Pages: " . join(", ", @{$category->{pages}}) . "\n";
        $debug_output .= "  Roles: " . join(", ", @{$category->{roles}}) . "\n";
        $debug_output .= "  Site Specific: " . ($category->{site_specific} ? "Yes" : "No") . "\n\n";
    }

    # Log the debug output
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'debug', $debug_output);

    # Display the debug output
    $c->response->content_type('text/plain');
    $c->response->body($debug_output);
}

# Configuration management page
sub config :Local :Args(0) {
    my ($self, $c) = @_;

    # Check if user has admin or developer role
    unless ($c->user_exists && ($c->user->role eq 'admin' || $c->user->role eq 'developer')) {
        $c->stash(error_msg => "You don't have permission to access this page");
        $c->detach('/error/access_denied');
        return;
    }

    # Log the action
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'config', "Accessing documentation configuration");

    # Get all documentation pages
    my $pages = $self->documentation_pages;

    # Get all categories
    my $categories = $self->documentation_categories;

    # Add to stash
    $c->stash(
        pages => $pages,
        categories => $categories,
        template => 'Documentation/config.tt'
    );
}

# Main documentation index
sub index :Path :Args(0) {
    my ($self, $c) = @_;

    # Log the action
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Accessing documentation index");

    # Get the current user's role
    my $user_role = 'normal';  # Default to normal user
    if ($c->user_exists) {
        $user_role = $c->user->role || 'normal';
    }

    # Get the current site name
    my $site_name = $c->stash->{SiteName} || 'default';

    # Log user role and site for debugging
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
        "User role: $user_role, Site: $site_name");

    # Initialize debug messages array if debug mode is enabled
    if ($c->session->{debug_mode}) {
        $c->stash->{debug_msg} = [] unless defined $c->stash->{debug_msg};
        push @{$c->stash->{debug_msg}}, "Documentation index - User role: $user_role, Site: $site_name";
    }

    # Get all documentation pages
    my $pages = $self->documentation_pages;

    # Add debug info about total pages
    if ($c->session->{debug_mode}) {
        push @{$c->stash->{debug_msg}}, "Total documentation pages: " . scalar(keys %$pages);
    }

    # Filter pages based on user role and site
    my %filtered_pages;
    foreach my $page_name (keys %$pages) {
        my $metadata = $pages->{$page_name};

        # Special case: CSC site admins can see all documentation
        if ($site_name eq 'CSC' && $user_role eq 'admin') {
            $filtered_pages{$page_name} = $metadata;
            next;
        }

        # For other users, apply normal filtering rules:

        # 1. Site-specific documentation is only visible to its respective site
        if ($metadata->{site} ne 'all' && $metadata->{site} ne $site_name) {
            if ($c->session->{debug_mode}) {
                push @{$c->stash->{debug_msg}}, "Skipping page '$page_name' - site mismatch (page site: $metadata->{site}, current site: $site_name)";
            }
            next;
        }

        # 2. Role-specific documentation is filtered by user role
        my $has_role = 0;
        foreach my $role (@{$metadata->{roles}}) {
            if ($role eq $user_role || ($role eq 'normal' && $user_role)) {
                $has_role = 1;
                last;
            }
        }

        unless ($has_role) {
            if ($c->session->{debug_mode}) {
                push @{$c->stash->{debug_msg}}, "Skipping page '$page_name' - role mismatch (page roles: " .
                    join(", ", @{$metadata->{roles}}) . ", user role: $user_role)";
            }
            next;
        }

        # Add to filtered pages
        $filtered_pages{$page_name} = $metadata;

        if ($c->session->{debug_mode}) {
            push @{$c->stash->{debug_msg}}, "Including page '$page_name' - site: $metadata->{site}, path: $metadata->{path}";
        }
    }

    # Log the number of filtered pages
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
        "Filtered documentation pages: " . scalar(keys %filtered_pages) .
        " (Site: $site_name, Role: $user_role)");

    # Sort pages alphabetically for better presentation
    my @sorted_pages = sort keys %filtered_pages;

    # Create a structured list of documentation pages with metadata
    my $structured_pages = {};
    foreach my $page_name (@sorted_pages) {
        my $metadata = $filtered_pages{$page_name};
        my $path = $metadata->{path};
        my $title = $self->_format_title($page_name);

        # Use the full path to ensure we're linking to the correct document
        # This ensures each category links to its own specific document
        my $url;

        # Log the path for debugging
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
            "Processing page: $page_name, Path: $path");

        if ($path =~ /\.md$/) {
            # For markdown files, use the view action with the full path
            $url = $c->uri_for($self->action_for('view'), [$path]);
        } else {
            # For other files, use the view action with just the page name
            $url = $c->uri_for($self->action_for('view'), [$page_name]);
        }

        $structured_pages->{$page_name} = {
            title => $title,
            path => $path,
            url => $url,
            site => $metadata->{site},
            roles => $metadata->{roles},
        };
    }

    # Get categories filtered by user role
    my %filtered_categories;
    foreach my $category_key (keys %{$self->documentation_categories}) {
        my $category = $self->documentation_categories->{$category_key};

        # Skip if the user doesn't have the required role
        my $has_role = 0;
        foreach my $role (@{$category->{roles}}) {
            if ($role eq $user_role || ($role eq 'normal' && $user_role)) {
                $has_role = 1;
                last;
            }
        }

        unless ($has_role) {
            if ($c->session->{debug_mode}) {
                push @{$c->stash->{debug_msg}}, "Skipping category '$category_key' - role mismatch (category roles: " .
                    join(", ", @{$category->{roles}}) . ", user role: $user_role)";
            }
            next;
        }

        # Skip site-specific categories if not relevant to this site
        if ($category->{site_specific} && !$self->_has_site_specific_docs($site_name, \%filtered_pages)) {
            if ($c->session->{debug_mode}) {
                push @{$c->stash->{debug_msg}}, "Skipping site-specific category '$category_key' - no relevant docs for site: $site_name";
            }
            next;
        }

        # Add to filtered categories
        $filtered_categories{$category_key} = $category;

        if ($c->session->{debug_mode}) {
            push @{$c->stash->{debug_msg}}, "Including category '$category_key' - title: $category->{title}";
        }

        # If this is the site-specific category, populate it with site-specific pages
        if ($category_key eq 'site_specific') {
            my @site_pages;
            foreach my $page_name (keys %filtered_pages) {
                if ($filtered_pages{$page_name}->{site} eq $site_name) {
                    push @site_pages, $page_name;
                    if ($c->session->{debug_mode}) {
                        push @{$c->stash->{debug_msg}}, "Adding page '$page_name' to site-specific category for site: $site_name";
                    }
                }
            }
            $filtered_categories{$category_key}->{pages} = \@site_pages;

            if ($c->session->{debug_mode}) {
                push @{$c->stash->{debug_msg}}, "Site-specific category has " . scalar(@site_pages) . " pages for site: $site_name";
            }
        }
    }

    # Load the completed items JSON file
    my $json_file = $c->path_to('root', 'Documentation', 'completed_items.json');
    my $completed_items = [];

    if (-e $json_file) {
        # Read the JSON file
        eval {
            open my $fh, '<:encoding(UTF-8)', $json_file or die "Cannot open $json_file: $!";
            my $json_content = do { local $/; <$fh> };
            close $fh;

            # Parse the JSON content
            require JSON;
            my $data = JSON::decode_json($json_content);

            # Sort items by date_created in descending order (newest first)
            $completed_items = [
                sort { $b->{date_created} cmp $a->{date_created} }
                @{$data->{completed_items}}
            ];

            if ($c->session->{debug_mode}) {
                push @{$c->stash->{debug_msg}}, "Loaded " . scalar(@$completed_items) . " completed items from JSON";
            }
        };
        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'index', "Error loading completed items JSON: $@");
            if ($c->session->{debug_mode}) {
                push @{$c->stash->{debug_msg}}, "Error loading completed items JSON: $@";
            }
        }
    } else {
        if ($c->session->{debug_mode}) {
            push @{$c->stash->{debug_msg}}, "Completed items JSON file not found: $json_file";
        }
    }

    # Add pages and completed items to stash
    $c->stash(
        documentation_pages => \%filtered_pages,
        structured_pages => $structured_pages,
        sorted_page_names => \@sorted_pages,
        completed_items => $completed_items,
        categories => \%filtered_categories,
        user_role => $user_role,
        site_name => $site_name,
        template => 'Documentation/index.tt',
        debug_mode => $c->session->{debug_mode} || 0
    );

    $c->forward($c->view('TT'));
}

# Helper method to check if there are site-specific docs for a site
sub _has_site_specific_docs {
    my ($self, $site_name, $filtered_pages) = @_;

    foreach my $page_name (keys %$filtered_pages) {
        if ($filtered_pages->{$page_name}->{site} eq $site_name) {
            return 1;
        }
    }

    return 0;
}

# Load documentation configuration from JSON file
sub _load_documentation_config {
    my ($self) = @_;

    my $config_file = "root/Documentation/documentation_config.json";
    my $config = {};

    if (-e $config_file) {
        try {
            # Read the JSON file
            open my $fh, '<:encoding(UTF-8)', $config_file or die "Cannot open $config_file: $!";
            my $json_content = do { local $/; <$fh> };
            close $fh;

            # Parse the JSON content
            require JSON;
            $config = JSON::decode_json($json_content);

            Comserv::Util::Logging::log_to_file(
                "Loaded documentation configuration from $config_file",
                undef, 'INFO'
            );
        } catch {
            Comserv::Util::Logging::log_to_file(
                "Error loading documentation configuration from $config_file: $_",
                undef, 'ERROR'
            );
        };
    } else {
        Comserv::Util::Logging::log_to_file(
            "Documentation configuration file not found: $config_file",
            undef, 'WARN'
        );
    }

    return $config;
}

# Add default pages from configuration
sub _add_default_pages {
    my ($self) = @_;

    # Get default paths from configuration
    my $default_paths = $self->default_paths;

    # Log the number of default paths
    Comserv::Util::Logging::log_to_file(
        "Adding " . scalar(keys %$default_paths) . " default pages from configuration",
        undef, 'INFO'
    );

    # Add each default page
    foreach my $page_id (keys %$default_paths) {
        my $path = $default_paths->{$page_id};

        # Skip if path doesn't exist
        next unless -e "root/$path";

        # Determine site and role requirements
        my $site = 'all';
        my @roles = ('normal', 'editor', 'admin', 'developer');

        # Check if this is site-specific documentation
        if ($path =~ m{Documentation/sites/([^/]+)/}) {
            $site = uc($1); # Convert site name to uppercase to match SiteName format
        }

        # Check if this is role-specific documentation
        if ($path =~ m{Documentation/roles/([^/]+)/}) {
            my $role = $1;
            if ($role eq 'admin') {
                @roles = ('admin', 'developer');
            } elsif ($role eq 'developer') {
                @roles = ('developer');
            } elsif ($role eq 'editor') {
                @roles = ('editor', 'admin', 'developer');
            }
        }

        # Store the path with metadata
        $self->documentation_pages->{$page_id} = {
            path => $path,
            site => $site,
            roles => \@roles,
        };

        # Log the added page
        Comserv::Util::Logging::log_to_file(
            "Added default page: $page_id, path: $path, site: $site",
            undef, 'INFO'
        );
    }
}

# Helper method to format page names into readable titles
sub _format_title {
    my ($self, $page_name) = @_;

    # Convert underscores to spaces and capitalize each word
    my $title = $page_name;
    $title =~ s/_/ /g;
    $title = join(' ', map { ucfirst $_ } split(/\s+/, $title));

    return $title;
}

# Display specific documentation page
sub view :Path :Args(1) {
    my ($self, $c, $page_or_path) = @_;

    # Log the action
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view', "Accessing documentation page: $page_or_path");

    # Get the current user's role
    my $user_role = 'normal';  # Default to normal user
    if ($c->user_exists) {
        $user_role = $c->user->role || 'normal';
    }

    # Get the current site name
    my $site_name = $c->stash->{SiteName} || 'default';

    # Check if we're dealing with a full path or just a page name
    my $is_full_path = ($page_or_path =~ m{^Documentation/});
    my $page = $page_or_path;

    # If it's a full path, extract the page name for permission checking
    if ($is_full_path) {
        # Extract the filename without extension
        if ($page_or_path =~ m{/([^/]+)(?:\.\w+)?$}) {
            $page = $1;
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view',
                "Extracted page name '$page' from path: $page_or_path");
        }
    } else {
        # Sanitize the page name to prevent directory traversal
        $page =~ s/[^a-zA-Z0-9_\.]//g;
    }

    # Check if the user has permission to view this page
    my $pages = $self->documentation_pages;
    if (exists $pages->{$page}) {
        my $metadata = $pages->{$page};

        # Special case: CSC site admins can see all documentation
        if ($site_name eq 'CSC' && $user_role eq 'admin') {
            # Allow access to all documentation
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view',
                "CSC admin accessing documentation: $page (has full access)");
        }
        else {
            # For other users, apply normal access rules:

            # 1. Check site-specific access
            if ($metadata->{site} ne 'all' && $metadata->{site} ne $site_name) {
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'view',
                    "Access denied to site-specific documentation: $page (user site: $site_name, doc site: $metadata->{site})");

                $c->stash(
                    error_msg => "You don't have permission to view this documentation page. It's specific to the '$metadata->{site}' site.",
                    template => 'Documentation/error.tt'
                );
                return $c->forward($c->view('TT'));
            }

            # 2. Check role-based access
            my $has_role = 0;
            foreach my $role (@{$metadata->{roles}}) {
                if ($role eq $user_role || ($role eq 'normal' && $user_role)) {
                    $has_role = 1;
                    last;
                }
            }

            unless ($has_role) {
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'view',
                    "Access denied to role-protected documentation: $page (user role: $user_role)");

                $c->stash(
                    error_msg => "You don't have permission to view this documentation page. It requires higher privileges.",
                    template => 'Documentation/error.tt'
                );
                return $c->forward($c->view('TT'));
            }
        }
    }

    # Handle the file path differently based on whether we have a full path or just a page name
    my $md_full_path;
    my $found_path;

    if ($is_full_path) {
        # We have a full path, so use it directly
        $found_path = $page_or_path;
        $md_full_path = $c->path_to('root', $found_path);

        # Log the direct path access
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view',
            "Using direct path: $found_path");

        # Check if the file exists
        unless (-e $md_full_path && !-d $md_full_path) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'view',
                "File not found at direct path: $found_path");
            $md_full_path = undef;
            $found_path = undef;
        }
    } else {
        # First check if it's a direct file request (with extension)
        if ($page =~ /\./) {
            my $file_path = "Documentation/$page";
            my $full_path = $c->path_to('root', $file_path);

            if (-e $full_path && !-d $full_path) {
                # Determine content type based on file extension
                my $content_type = 'text/plain';  # Default
                if ($page =~ /\.json$/i) {
                    $content_type = 'application/json';
                } elsif ($page =~ /\.html?$/i) {
                    $content_type = 'text/html';
                } elsif ($page =~ /\.css$/i) {
                    $content_type = 'text/css';
                } elsif ($page =~ /\.js$/i) {
                    $content_type = 'application/javascript';
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

        # Check if it's a markdown file - try multiple locations
        my @possible_paths = (
            "Documentation/$page.md",                      # Direct in Documentation
            "Documentation/roles/normal/$page.md",         # Normal user docs
            "Documentation/roles/admin/$page.md",          # Admin docs
            "Documentation/roles/developer/$page.md",      # Developer docs
            "Documentation/tutorials/$page.md",            # Tutorials
            "Documentation/sites/$site_name/$page.md"      # Site-specific docs
        );

        foreach my $path (@possible_paths) {
            my $test_path = $c->path_to('root', $path);
            if (-e $test_path) {
                $md_full_path = $test_path;
                $found_path = $path;
                last;
            }
        }
    }

    if ($md_full_path) {
        # Log which path was found
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view',
            "Found markdown file at: $found_path");

        # Read the markdown file
        open my $fh, '<:encoding(UTF-8)', $md_full_path or die "Cannot open $md_full_path: $!";
        my $content = do { local $/; <$fh> };
        close $fh;

        # Get file modification time
        my $mtime = (stat($md_full_path))[9];
        my $dt = DateTime->from_epoch(epoch => $mtime);
        my $last_updated = $dt->ymd('-') . ' ' . $dt->hms(':');

        # We'll let the template handle markdown rendering

        # Format the page title
        my $page_title = $self->_format_title($page);

        # Pass the content to the markdown viewer template
        $c->stash(
            page_name => $page,
            page_title => $page_title,
            title => "Documentation: $page_title", # Set the page title for the HTML <title> tag
            markdown_content => $content,
            last_updated => $last_updated,
            user_role => $user_role,
            site_name => $site_name,
            template => 'Documentation/markdown_viewer.tt'
        );
        return;
    }

    # If not a markdown file, try as a template
    my $template_path;

    if ($is_full_path && $page_or_path =~ /\.tt$/) {
        # If we have a full path to a template file, use it directly
        $template_path = $page_or_path;
        my $test_path = $c->path_to('root', $template_path);

        # Verify the template exists
        unless (-e $test_path && !-d $test_path) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'view',
                "Template file not found at direct path: $template_path");
            $template_path = undef;
        } else {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view',
                "Using direct template path: $template_path");
        }
    } else {
        # Check multiple locations for the template
        my @possible_template_paths = (
            "Documentation/$page.tt",                      # Direct in Documentation
            "Documentation/roles/normal/$page.tt",         # Normal user docs
            "Documentation/roles/admin/$page.tt",          # Admin docs
            "Documentation/roles/developer/$page.tt",      # Developer docs
            "Documentation/tutorials/$page.tt",            # Tutorials
            "Documentation/sites/$site_name/$page.tt"      # Site-specific docs
        );

        foreach my $path (@possible_template_paths) {
            my $test_path = $c->path_to('root', $path);
            if (-e $test_path) {
                $template_path = $path;
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view',
                    "Found template file at: $path");
                last;
            }
        }
    }

    if ($template_path) {
        # Set the template and additional context
        $c->stash(
            template => $template_path,
            user_role => $user_role,
            site_name => $site_name
        );
    } else {
        # Log the error
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'view',
            "Documentation page not found: $page (user role: $user_role, site: $site_name)");

        # Log all the paths we checked
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'view',
            "Checked paths: " . join(", ", @possible_paths, @possible_template_paths));

        # Set error message
        $c->stash(
            error_msg => "Documentation page '$page' not found",
            template => 'Documentation/error.tt'
        );
    }

    $c->forward($c->view('TT'));
}

# Auto method for all documentation requests
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

# IMPORTANT: We're completely disabling dynamic route registration
# to avoid the "Can't locate object method 'attributes'" errors
sub register_actions {
    my ($self, $app) = @_;

    # Call the parent method first to register the explicitly defined actions
    $self->next::method($app);

    # Log that we're skipping dynamic route registration
    Comserv::Util::Logging::log_to_file(
        "Skipping dynamic route registration for documentation pages to avoid package conflicts",
        undef, 'INFO'
    );

    # We're intentionally NOT registering dynamic routes for documentation pages
    # This prevents the "Can't locate object method 'attributes'" errors
    # Instead, we'll handle all documentation page requests through the 'view' action
}

# Theme system documentation
sub theme_system :Path('theme_system') :Args(0) {
    my ($self, $c) = @_;

    # Log the action
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'theme_system', "Accessing theme system documentation");

    # Set the template
    $c->stash(template => 'Documentation/theme_system.tt');
    $c->forward($c->view('TT'));
}

# Theme system implementation documentation
sub theme_system_implementation :Path('theme_system_implementation') :Args(0) {
    my ($self, $c) = @_;

    # Log the action
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'theme_system_implementation',
        "Accessing theme system implementation documentation");

    # Check if the markdown file exists
    my $md_file = $c->path_to('root', 'Documentation', 'theme_system_implementation.md');

    if (-e $md_file) {
        # Read the markdown file
        open my $fh, '<:encoding(UTF-8)', $md_file or die "Cannot open $md_file: $!";
        my $content = do { local $/; <$fh> };
        close $fh;

        # Pass the content to the template
        $c->stash(
            markdown_content => $content,
            template => 'Documentation/markdown_viewer.tt'
        );
    } else {
        # If the file doesn't exist, show an error
        $c->stash(
            error_msg => "Documentation file 'theme_system_implementation.md' not found",
            template => 'Documentation/error.tt'
        );
    }

    $c->forward($c->view('TT'));
}

# Explicitly define routes for common documentation pages
# This allows for better URL structure and SEO

# Document management documentation
sub document_management :Path('document_management') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'document_management', "Accessing document management documentation");
    $c->stash(template => 'Documentation/document_management.tt');
    $c->forward($c->view('TT'));
}

# Recent updates
sub recent_updates :Path('recent_updates') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'recent_updates', "Accessing recent updates documentation");
    $c->stash(template => 'Documentation/recent_updates.tt');
    $c->forward($c->view('TT'));
}

# Admin documentation
sub admin :Path('admin') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'admin', "Accessing admin documentation");
    $c->stash(template => 'Documentation/admin.tt');
    $c->forward($c->view('TT'));
}

# System overview
sub system_overview :Path('system_overview') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'system_overview', "Accessing system overview documentation");
    $c->stash(template => 'Documentation/system_overview.tt');
    $c->forward($c->view('TT'));
}

# Architecture
sub architecture :Path('architecture') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'architecture', "Accessing architecture documentation");
    $c->stash(template => 'Documentation/architecture.tt');
    $c->forward($c->view('TT'));
}

# Installation guide
sub installation :Path('installation') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'installation', "Accessing installation documentation");
    $c->stash(template => 'Documentation/installation.tt');
    $c->forward($c->view('TT'));
}

# Completed items JSON
sub completed_items_json :Path('completed_items.json') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'completed_items_json', "Accessing completed items JSON");

    # Read the JSON file
    my $json_file = $c->path_to('root', 'Documentation', 'completed_items.json');
    my $json_content = '';

    if (-e $json_file) {
        open my $fh, '<:raw', $json_file or die "Cannot open $json_file: $!";
        $json_content = do { local $/; <$fh> };
        close $fh;
    }

    # Set the response
    $c->response->content_type('application/json');
    $c->response->body($json_content);
}

# Configuration
sub configuration :Path('configuration') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'configuration', "Accessing configuration documentation");
    $c->stash(template => 'Documentation/configuration.tt');
    $c->forward($c->view('TT'));
}

# User guide
sub user_guide :Path('user_guide') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'user_guide', "Accessing user guide documentation");
    $c->stash(template => 'Documentation/user_guide.tt');
    $c->forward($c->view('TT'));
}

# Admin guide
sub admin_guide :Path('admin_guide') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'admin_guide', "Accessing admin guide documentation");
    $c->stash(template => 'Documentation/admin_guide.tt');
    $c->forward($c->view('TT'));
}

# API reference
sub api_reference :Path('api_reference') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'api_reference', "Accessing API reference documentation");
    $c->stash(template => 'Documentation/api_reference.tt');
    $c->forward($c->view('TT'));
}

# Database schema
sub database_schema :Path('database_schema') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'database_schema', "Accessing database schema documentation");
    $c->stash(template => 'Documentation/database_schema.tt');
    $c->forward($c->view('TT'));
}

__PACKAGE__->meta->make_immutable;

1;