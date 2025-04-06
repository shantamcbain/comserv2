package Comserv::Controller::Documentation;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;
use File::Find;
use File::Basename;
use Comserv::Controller::Documentation::ScanMethods qw(_scan_directories _categorize_pages);

BEGIN { extends 'Catalyst::Controller'; }

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
# Updated to include all necessary categories and ensure proper organization
has 'documentation_categories' => (
    is => 'ro',
    default => sub {
        {
            'user_guides' => {
                title => 'User Guides',
                description => 'Documentation for end users of the system',
                pages => [],
                roles => ['normal', 'editor', 'admin', 'developer'],
                site_specific => 0,
            },
            'admin_guides' => {
                title => 'Administrator Guides',
                description => 'Documentation for system administrators',
                pages => [],
                roles => ['admin'],
                site_specific => 0,
            },
            'developer_guides' => {
                title => 'Developer Documentation',
                description => 'Documentation for developers',
                pages => [],
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
            'proxmox' => {
                title => 'Proxmox Documentation',
                description => 'Documentation for Proxmox virtualization environment',
                pages => [],
                roles => ['admin'],
                site_specific => 0,
            },
            'controllers' => {
                title => 'Controller Documentation',
                description => 'Documentation for system controllers',
                pages => [],
                roles => ['admin', 'developer'],
                site_specific => 0,
            },
            'changelog' => {
                title => 'Changelog',
                description => 'System changes and updates',
                pages => [],
                roles => ['admin', 'developer'],
                site_specific => 0,
            },
            'general' => {
                title => 'All Documentation',
                description => 'Complete list of all documentation files',
                pages => [],
                roles => ['admin', 'developer'],
                site_specific => 0,
            },
        }
    },
    lazy => 1,
);

# Initialize - scan for documentation files
sub BUILD {
    my ($self) = @_;
    my $logger = $self->logging;

    $logger->log_to_file("Starting Documentation controller initialization", undef, 'INFO');

    # Helper function to generate safe keys
    my $generate_key = sub {
        my ($path, $filename) = @_;

        # Remove problematic characters
        $filename =~ s/[^a-zA-Z0-9\-_\.]//g;

        # Split filename and extension
        my ($name, $dir, $ext) = fileparse($filename, qr/\.[^.]*/);

        # Handle special file types
        return $name if $ext =~ /\.tt$/;
        return $name if $ext =~ /\.md$/;
        return $name if $ext =~ /\.html$/;
        return $name if $ext =~ /\.txt$/;
        return $filename if $ext eq '';

        # For other extensions, keep both name and extension in key
        return "${name}${ext}";
    };

    # Scan documentation directories
    # Modified to ensure all documentation is accessible to admin group and properly categorized
    my $scan_dirs = sub {
        my ($base_dir, $category_handler, $metadata_handler) = @_;

        return unless -d $base_dir;

        # Log the start of scanning
        $logger->log_to_file("Scanning directory: $base_dir", undef, 'INFO');

        find({
            wanted => sub {
                return if -d $_;

                # Only process .md, .tt, .html, and .txt files
                return unless /\.(md|tt|html|txt)$/i;

                my $full_path = $File::Find::name;
                my $rel_path = $full_path =~ s/^root\///r;
                my $filename = basename($full_path);

                # Log file found
                $logger->log_to_file("Found documentation file: $rel_path", undef, 'DEBUG');

                # Generate safe key
                my $key = $generate_key->($rel_path, $filename);

                unless ($key) {
                    $logger->log_to_file("Failed to generate key for: $full_path", undef, 'ERROR');
                    return;
                }

                # Process metadata
                my $title = $self->_format_title($filename);
                my %meta = (
                    path => $rel_path,
                    site => 'all',
                    roles => ['normal', 'editor', 'admin', 'developer'],
                    file_type => ($filename =~ /\.tt$/i) ? 'template' :
                                 ($filename =~ /\.md$/i) ? 'markdown' : 'other',
                    title => $title,
                    description => "Documentation for $title"
                );

                # Custom metadata handling
                $metadata_handler->(\%meta, $full_path) if $metadata_handler;

                # Ensure admin role is always included for all documentation
                push @{$meta{roles}}, 'admin' unless grep { $_ eq 'admin' } @{$meta{roles}};

                # Store in documentation pages
                $self->documentation_pages->{$key} = \%meta;

                # Categorize
                $category_handler->($key, \%meta) if $category_handler;

                # Log the found documentation
                $logger->log_to_file("Found documentation: $key (type: $meta{file_type}, path: $rel_path)", undef, 'DEBUG');
            },
            no_chdir => 1
        }, $base_dir);
    };

    # Using the standalone _format_title method defined below

    # Initialize category pages as empty arrays to avoid duplicates
    foreach my $category (keys %{$self->documentation_categories}) {
        $self->documentation_categories->{$category}{pages} = [];
    }

    # Create a hash to track which files have been categorized
    my %categorized_files;

    # Scan main documentation directory
    # Modified to properly categorize all documentation files and avoid duplicates
    $scan_dirs->(
        "root/Documentation",
        sub {
            my ($key, $meta) = @_;

            # Always add to general category first for the complete list
            push @{$self->documentation_categories->{general}{pages}}, $key;

            # Skip if already categorized in a specific section
            return if $categorized_files{$key};

            # Set a default category for uncategorized files
            my $category = 'general';

            # Categorize based on path and filename
            if ($meta->{path} =~ m{/tutorials/}) {
                $category = 'tutorials';
            }
            elsif ($meta->{path} =~ m{/modules/}) {
                $category = 'modules';
            }
            elsif ($meta->{path} =~ m{/proxmox/}) {
                $category = 'proxmox';
            }
            elsif ($meta->{path} =~ m{/developer/}) {
                $category = 'developer_guides';
            }
            elsif ($meta->{path} =~ m{/changelog/}) {
                $category = 'changelog';
            }
            elsif ($meta->{path} =~ m{/controllers/} || $key =~ /controller/i) {
                $category = 'controllers';
            }
            elsif ($meta->{path} =~ m{/roles/admin/}) {
                $category = 'admin_guides';
            }
            elsif ($meta->{path} =~ m{/roles/normal/}) {
                $category = 'user_guides';
            }
            elsif ($meta->{path} =~ m{/roles/developer/}) {
                $category = 'developer_guides';
            }
            # Categorize by filename patterns
            elsif ($key =~ /^(installation|configuration|system|admin|user_management)/i) {
                $category = 'admin_guides';
            }
            elsif ($key =~ /^(getting_started|account_management|user_guide|faq)/i) {
                $category = 'user_guides';
            }
            elsif ($key =~ /^(todo|project|task)/i) {
                $category = 'modules';
            }
            elsif ($key =~ /^(proxmox)/i) {
                $category = 'proxmox';
            }

            # Add to appropriate category if it exists
            if (exists $self->documentation_categories->{$category} && $category ne 'general') {
                push @{$self->documentation_categories->{$category}{pages}}, $key;
                $categorized_files{$key} = 1;
                $logger->log_to_file("Added $key to $category category", undef, 'DEBUG');
            }
        }
    );

    # Scan role-specific documentation
    # Modified to ensure proper categorization and admin access, avoiding duplicates
    $scan_dirs->(
        "root/Documentation/roles",
        sub {
            my ($key, $meta) = @_;

            # Skip if already categorized
            return if $categorized_files{$key};

            # Fixed variable declaration - removed redundant assignments
            my @roles;
            my $category = 'user_guides'; # Default category

            if ($meta->{path} =~ m{/admin/}) {
                @roles = ('admin');
                $category = 'admin_guides';
            }
            elsif ($meta->{path} =~ m{/developer/}) {
                @roles = ('developer');
                $category = 'developer_guides';
            }
            else {
                @roles = ('normal', 'editor');
            }

            # Always add admin role to ensure admin access
            push @roles, 'admin' unless grep { $_ eq 'admin' } @roles;
            $meta->{roles} = \@roles;

            # Add to appropriate category
            push @{$self->documentation_categories->{$category}{pages}}, $key;
            $categorized_files{$key} = 1;

            # Add to general category
            push @{$self->documentation_categories->{general}{pages}}, $key;

            # Log categorization
            $logger->log_to_file("Categorized $key in $category category", undef, 'DEBUG');
        },
        sub {
            my ($meta, $path) = @_;
            $meta->{site} = 'all';

            # Add file type detection
            my $filename = basename($path);
            $meta->{file_type} = ($filename =~ /\.tt$/i) ? 'template' :
                               ($filename =~ /\.md$/i) ? 'markdown' : 'other';

            # Format title from filename
            $meta->{title} = $self->_format_title(basename($path));

            # Add description
            $meta->{description} = "Documentation for " . $meta->{title};
        }
    );

    # Scan site-specific documentation
    # Modified to ensure proper categorization and admin access, avoiding duplicates
    $scan_dirs->(
        "root/Documentation/sites",
        sub {
            my ($key, $meta) = @_;

            # Skip if already categorized
            return if $categorized_files{$key};

            # Add to site-specific category
            push @{$self->documentation_categories->{site_specific}{pages}}, $key;
            $categorized_files{$key} = 1;

            # Add to general category
            push @{$self->documentation_categories->{general}{pages}}, $key;

            # Ensure admin role is included
            push @{$meta->{roles}}, 'admin' unless grep { $_ eq 'admin' } @{$meta->{roles}};

            # Log categorization
            $logger->log_to_file("Added $key to site-specific category for site: $meta->{site}", undef, 'DEBUG');
        },
        sub {
            my ($meta, $path) = @_;
            if ($path =~ m{/sites/([^/]+)/}) {
                $meta->{site} = $1;
            }

            # Add file type detection
            my $filename = basename($path);
            $meta->{file_type} = ($filename =~ /\.tt$/i) ? 'template' :
                               ($filename =~ /\.md$/i) ? 'markdown' : 'other';

            # Format title from filename
            $meta->{title} = $self->_format_title(basename($path));

            # Add description
            $meta->{description} = "Site-specific documentation for " . ($meta->{site} || 'all sites');
        }
    );

    # Post-process categories
    foreach my $category (values %{$self->documentation_categories}) {
        # Remove duplicates
        my %seen;
        my @unique = grep { !$seen{$_}++ } @{$category->{pages}};

        # Sort alphabetically by title
        $category->{pages} = [ sort {
            lc($self->_format_title($a)) cmp lc($self->_format_title($b))
        } @unique ];

        # Log the count
        $logger->log_to_file("Category " . ($category->{title} || 'unknown') . " has " . scalar(@{$category->{pages}}) . " pages", undef, 'DEBUG');
    }

    $logger->log_to_file(sprintf("Documentation system initialized with %d pages",
        scalar keys %{$self->documentation_pages}), undef, 'INFO');
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

    # Get all documentation pages
    my $pages = $self->documentation_pages;

    # Filter pages based on user role and site
    # Modified to ensure admins can see all documentation and pages are properly categorized
    my %filtered_pages;
    foreach my $page_name (keys %$pages) {
        my $metadata = $pages->{$page_name};

        # Skip if this is site-specific documentation for a different site
        # But allow admins to see all site-specific documentation
        if ($metadata->{site} ne 'all' && $metadata->{site} ne $site_name) {
            # Only skip for non-admins
            next unless $user_role eq 'admin';
        }

        # Skip if the user doesn't have the required role
        # But always include for admins
        my $has_role = ($user_role eq 'admin'); # Admins can see everything

        unless ($has_role) {
            foreach my $role (@{$metadata->{roles}}) {
                if ($role eq $user_role || ($role eq 'normal' && $user_role)) {
                    $has_role = 1;
                    last;
                }
            }
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

    # Get categories filtered by user role
    my %filtered_categories;
    foreach my $category_key (keys %{$self->documentation_categories}) {
        my $category = $self->documentation_categories->{$category_key};

        # Skip if the user doesn't have the required role
        # But always include for admins
        my $has_role = ($user_role eq 'admin'); # Admins can see everything

        unless ($has_role) {
            foreach my $role (@{$category->{roles}}) {
                if ($role eq $user_role || ($role eq 'normal' && $user_role)) {
                    $has_role = 1;
                    last;
                }
            }
        }
        next unless $has_role;

        # Skip site-specific categories if not relevant to this site
        next if $category->{site_specific} && !$self->_has_site_specific_docs($site_name, \%filtered_pages);

        # Add to filtered categories
        $filtered_categories{$category_key} = $category;

        # If this is the site-specific category, populate it with site-specific pages
        if ($category_key eq 'site_specific') {
            my @site_pages;
            foreach my $page_name (keys %filtered_pages) {
                if ($filtered_pages{$page_name}->{site} eq $site_name) {
                    push @site_pages, $page_name;
                }
            }
            $filtered_categories{$category_key}->{pages} = \@site_pages;
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
        };
        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'index', "Error loading completed items JSON: $@");
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
        template => 'Documentation/index.tt'
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

# Helper method to format page names into readable titles
sub _format_title {
    my ($self, $page_name) = @_;

    # Log the input for debugging
    $self->logging->log_to_file("Formatting title from: $page_name", undef, 'DEBUG');

    # Convert underscores and hyphens to spaces
    my $title = $page_name;
    $title =~ s/_/ /g;
    $title =~ s/-/ /g;

    # Remove file extensions if present
    $title =~ s/\.(md|tt|html|txt)$//i;

    # Capitalize each word
    $title = join(' ', map { ucfirst $_ } split(/\s+/, $title));

    # Special case handling for acronyms
    $title =~ s/\bAi\b/AI/g;
    $title =~ s/\bApi\b/API/g;
    $title =~ s/\bKvm\b/KVM/g;
    $title =~ s/\bIso\b/ISO/g;
    $title =~ s/\bCd\b/CD/g;
    $title =~ s/\bDbi\b/DBI/g;
    $title =~ s/\bEncy\b/ENCY/g;

    # Log the output for debugging
    $self->logging->log_to_file("Formatted title result: $title", undef, 'DEBUG');

    return $title;
}

# Display specific documentation page
sub view :Path :Args(1) {
    my ($self, $c, $page) = @_;

    # Log the action
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view', "Accessing documentation page: $page");

    # Get the current user's role
    my $user_role = 'normal';  # Default to normal user
    if ($c->user_exists) {
        $user_role = $c->user->role || 'normal';
    }
   # Add admin check for Proxmox docs
    if ($page =~ /^Proxmox/ && !$c->check_user_roles('admin')) {
        $c->response->redirect($c->uri_for('/access_denied'));
        return;
    }

    # Get the current site name
    my $site_name = $c->stash->{SiteName} || 'default';

    # Sanitize the page name to prevent directory traversal
    $page =~ s/[^a-zA-Z0-9_\.]//g;

    # Check if the user has permission to view this page
    # Modified to ensure admins can access all documentation
    my $pages = $self->documentation_pages;
    if (exists $pages->{$page}) {
        my $metadata = $pages->{$page};

        # Admins can access all documentation regardless of site or role restrictions
        if ($user_role ne 'admin') {
            # Check site-specific access for non-admins
            if ($metadata->{site} ne 'all' && $metadata->{site} ne $site_name) {
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'view',
                    "Access denied to site-specific documentation: $page (user site: $site_name, doc site: $metadata->{site})");

                $c->stash(
                    error_msg => "You don't have permission to view this documentation page. It's specific to the '$metadata->{site}' site.",
                    template => 'Documentation/error.tt'
                );
                return $c->forward($c->view('TT'));
            }

            # Check role-based access for non-admins
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
        } else {
            # Log admin access to documentation
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view',
                "Admin access granted to documentation: $page");
        }
    }

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

    # Check if it's a markdown file
    my $md_path = "Documentation/$page.md";
    my $md_full_path = $c->path_to('root', $md_path);

    if (-e $md_full_path) {
        # Read the markdown file
        open my $fh, '<:encoding(UTF-8)', $md_full_path or die "Cannot open $md_full_path: $!";
        my $content = do { local $/; <$fh> };
        close $fh;

        # Get file modification time
        my $mtime = (stat($md_full_path))[9];
        my $last_updated = localtime($mtime)->strftime('%Y-%m-%d %H:%M:%S');

        # Pass the content to the markdown viewer template
        $c->stash(
            page_name => $page,
            page_title => $self->_format_title($page),
            markdown_content => $content,
            last_updated => $last_updated,
            user_role => $user_role,
            site_name => $site_name,
            template => 'Documentation/markdown_viewer.tt'
        );
        return;
    }

    # If not a markdown file, try as a template
    my $template_path = "Documentation/$page.tt";
    my $full_path = $c->path_to('root', $template_path);

    if (-e $full_path) {
        # Set the template and additional context
        $c->stash(
            template => $template_path,
            user_role => $user_role,
            site_name => $site_name
        );
    } else {
        # Check for site-specific paths
        my $site_path = "Documentation/sites/$site_name/$page.tt";
        my $site_full_path = $c->path_to('root', $site_path);

        if (-e $site_full_path) {
            # Set the template for site-specific documentation
            $c->stash(
                template => $site_path,
                user_role => $user_role,
                site_name => $site_name
            );
        } else {
            # Check for role-specific paths
            my $role_path = "Documentation/roles/$user_role/$page.tt";
            my $role_full_path = $c->path_to('root', $role_path);

            if (-e $role_full_path) {
                # Set the template for role-specific documentation
                $c->stash(
                    template => $role_path,
                    user_role => $user_role,
                    site_name => $site_name
                );
            } else {
                # Log the error
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'view',
                    "Documentation page not found: $page (user role: $user_role, site: $site_name)");

                # Set error message
                $c->stash(
                    error_msg => "Documentation page '$page' not found",
                    template => 'Documentation/error.tt'
                );
            }
        }
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

# KVM ISO Transfer documentation
sub kvm_iso_transfer :Path('KVM_ISO_Transfer') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'kvm_iso_transfer', "Accessing KVM ISO Transfer documentation");
    $c->stash(template => 'Documentation/KVM_ISO_Transfer.tt');
    $c->forward($c->view('TT'));
}
# KVM CD Visibility documentation
sub kvm_cd_visibility :Path('KVM_CD_Visibility') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'kvm_cd_visibility',
        "Accessing KVM CD Visibility documentation");
    $c->stash(template => 'Documentation/KVM_CD_Visibility.tt');
    $c->forward($c->view('TT'));
}

# Proxmox CD Visibility documentation
sub proxmox_cd_visibility :Path('Proxmox_CD_Visibility') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'proxmox_cd_visibility',
        "Accessing Proxmox CD Visibility documentation");
    $c->stash(template => 'Documentation/Proxmox_CD_Visibility.tt');
    $c->forward($c->view('TT'));
}

# Virtualmin Integration documentation
sub virtualmin_integration :Path('Virtualmin_Integration') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'virtualmin_integration',
        "Accessing Virtualmin Integration documentation");
    $c->stash(template => 'Documentation/Virtualmin_Integration.tt');
    $c->forward($c->view('TT'));
}

# Starman Updated documentation
sub starman_updated :Path('Starman') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'starman_updated',
        "Accessing updated Starman documentation");
    $c->stash(template => 'Documentation/Starman.tt');
    $c->forward($c->view('TT'));
}
__PACKAGE__->meta->make_immutable;

1;