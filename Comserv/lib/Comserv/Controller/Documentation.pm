package Comserv::Controller::Documentation;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;
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

# Store documentation categories
# Updated to include all necessary categories and ensure proper organization
has 'documentation_categories' => (
    is => 'rw',
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
            'models' => {
                title => 'Model Documentation',
                description => 'Documentation for system models',
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

        # Remove problematic characters (preserve dashes)
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
                # Calculate relative path from the application root
                # The full_path will be something like: /absolute/path/to/root/Documentation/file.tt
                # We want to store: Documentation/file.tt
                my $rel_path = $full_path;
                if ($rel_path =~ m{/root/(.+)$}) {
                    $rel_path = $1;  # Extract everything after /root/
                } else {
                    # Fallback - this shouldn't happen but just in case
                    $rel_path = basename($full_path);
                }
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
                
                # Determine appropriate roles based on path
                my @roles = ('normal', 'editor', 'admin', 'developer'); # Default - accessible to all
                
                # Restrict access for admin-specific paths
                if ($rel_path =~ m{/roles/admin/} || 
                    $rel_path =~ m{/proxmox/} ||
                    $rel_path =~ m{/controllers/} ||
                    $rel_path =~ m{/models/}) {
                    @roles = ('admin', 'developer');
                }
                # Restrict access for developer-specific paths
                elsif ($rel_path =~ m{/roles/developer/}) {
                    @roles = ('developer', 'admin');
                }
                
                my %meta = (
                    path => $rel_path,
                    site => 'all',
                    roles => \@roles,
                    file_type => ($filename =~ /\.tt$/i) ? 'template' : 'other',
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
        File::Spec->catdir($FindBin::Bin, "..", "root", "Documentation"),
        sub {
            my ($key, $meta) = @_;

            # Always add to general category first for the complete list
            push @{$self->documentation_categories->{general}{pages}}, $key;

            # Skip if already categorized in a specific section
            return if $categorized_files{$key};

            # Set a default category for uncategorized files
            my $category = 'general';

            # Log the key and path for debugging
            $logger->log_to_file("Categorizing file: $key, path: $meta->{path}", undef, 'DEBUG');

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
            elsif ($meta->{path} =~ m{/controllers/} || $key =~ /controller/i || $key =~ /^(root|user|site|admin|documentation|proxmox|todo|project|file|mail|log|themeadmin|themeeditor|csc|ency|usbm|apiary|bmaster|forager|ve7tit|workshop)$/i) {
                $category = 'controllers';
                $logger->log_to_file("Categorized as controller: $key", undef, 'DEBUG');
            }
            elsif ($meta->{path} =~ m{/models/} || $key =~ /model/i || $key =~ /^(user|site|theme|themeconfig|todo|project|proxmox|calendar|file|mail|log|dbschemamanager|dbency|dbforager|encymodel|bmaster|bmastermodel|apiarymodel|workshop)$/i) {
                $category = 'models';
                $logger->log_to_file("Categorized as model: $key", undef, 'DEBUG');
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
            elsif ($key =~ /^(proxmox)/i || $key =~ /^(proxmox_commands)$/i) {
                $category = 'proxmox';
                $logger->log_to_file("Categorized as proxmox: $key", undef, 'DEBUG');
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
        File::Spec->catdir($FindBin::Bin, "..", "root", "Documentation", "roles"),
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

    # Scan controller documentation
    # Added to ensure controller documentation is properly categorized
    $scan_dirs->(
        "root/Documentation/controllers",
        sub {
            my ($key, $meta) = @_;

            # Skip if already categorized
            return if $categorized_files{$key};

            # Add to controllers category
            push @{$self->documentation_categories->{controllers}{pages}}, $key;
            $categorized_files{$key} = 1;

            # Add to general category
            push @{$self->documentation_categories->{general}{pages}}, $key;

            # Ensure admin role is included
            push @{$meta->{roles}}, 'admin' unless grep { $_ eq 'admin' } @{$meta->{roles}};

            # Log categorization
            $logger->log_to_file("Added $key to controllers category", undef, 'DEBUG');
        },
        sub {
            my ($meta, $path) = @_;

            # Add file type detection
            my $filename = basename($path);
            $meta->{file_type} = ($filename =~ /\.tt$/i) ? 'template' :
                               ($filename =~ /\.md$/i) ? 'markdown' : 'other';

            # Format title from filename
            $meta->{title} = $self->_format_title(basename($path));

            # Add description
            $meta->{description} = "Controller documentation for " . $meta->{title};

            # Set roles to admin and developer
            $meta->{roles} = ['admin', 'developer'];
        }
    );

    # Scan model documentation
    # Added to ensure model documentation is properly categorized
    $scan_dirs->(
        "root/Documentation/models",
        sub {
            my ($key, $meta) = @_;

            # Skip if already categorized
            return if $categorized_files{$key};

            # Add to models category
            push @{$self->documentation_categories->{models}{pages}}, $key;
            $categorized_files{$key} = 1;

            # Add to general category
            push @{$self->documentation_categories->{general}{pages}}, $key;

            # Ensure admin role is included
            push @{$meta->{roles}}, 'admin' unless grep { $_ eq 'admin' } @{$meta->{roles}};

            # Log categorization
            $logger->log_to_file("Added $key to models category", undef, 'DEBUG');
        },
        sub {
            my ($meta, $path) = @_;

            # Add file type detection
            my $filename = basename($path);
            $meta->{file_type} = ($filename =~ /\.tt$/i) ? 'template' :
                               ($filename =~ /\.md$/i) ? 'markdown' : 'other';

            # Format title from filename
            $meta->{title} = $self->_format_title(basename($path));

            # Add description
            $meta->{description} = "Model documentation for " . $meta->{title};

            # Set roles to admin and developer
            $meta->{roles} = ['admin', 'developer'];
        }
    );

    # Scan additional documentation directories that were missing
    my @additional_dirs = qw(general features docs migration system cloudflare themes tutorials changelog scripts admin proxmox);
    
    foreach my $dir_name (@additional_dirs) {
        my $dir_path = File::Spec->catdir($FindBin::Bin, "..", "root", "Documentation", $dir_name);
        next unless -d $dir_path;
        
        $scan_dirs->(
            $dir_path,
            sub {
                my ($key, $meta) = @_;

                # Skip if already categorized
                return if $categorized_files{$key};

                # Determine category based on directory name
                my $category = 'general'; # default
                
                if ($dir_name eq 'tutorials') {
                    $category = 'tutorials';
                } elsif ($dir_name eq 'changelog') {
                    $category = 'changelog';
                } elsif ($dir_name eq 'admin') {
                    $category = 'admin_guides';
                } elsif ($dir_name eq 'proxmox') {
                    $category = 'proxmox';
                } elsif ($dir_name eq 'features' || $dir_name eq 'system') {
                    $category = 'developer_guides';
                } elsif ($dir_name eq 'themes') {
                    $category = 'developer_guides';
                } elsif ($dir_name eq 'migration' || $dir_name eq 'scripts') {
                    $category = 'admin_guides';
                }
                
                # Add to appropriate category
                if (exists $self->documentation_categories->{$category}) {
                    push @{$self->documentation_categories->{$category}{pages}}, $key;
                    $categorized_files{$key} = 1;
                }

                # Always add to general category for complete list
                push @{$self->documentation_categories->{general}{pages}}, $key;

                # Log categorization
                $logger->log_to_file("Added $key from $dir_name directory to $category category", undef, 'DEBUG');
            },
            sub {
                my ($meta, $path) = @_;

                # Add file type detection
                my $filename = basename($path);
                $meta->{file_type} = ($filename =~ /\.tt$/i) ? 'template' :
                                   ($filename =~ /\.md$/i) ? 'markdown' : 'other';

                # Format title from filename
                $meta->{title} = $self->_format_title(basename($path));

                # Add description based on directory
                $meta->{description} = "Documentation from $dir_name: " . $meta->{title};

                # Set appropriate roles based on directory
                if ($dir_name eq 'admin' || $dir_name eq 'migration' || $dir_name eq 'scripts' || $dir_name eq 'proxmox') {
                    $meta->{roles} = ['admin', 'developer'];
                } elsif ($dir_name eq 'features' || $dir_name eq 'system' || $dir_name eq 'themes') {
                    $meta->{roles} = ['developer', 'admin'];
                } else {
                    $meta->{roles} = ['normal', 'editor', 'admin', 'developer'];
                }
            }
        );
    }

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

        # Log all pages in this category for debugging
        if ($category->{title} eq 'Controller Documentation' || $category->{title} eq 'Model Documentation') {
            $logger->log_to_file("Pages in " . $category->{title} . ": " . join(", ", @{$category->{pages}}), undef, 'DEBUG');
        }
    }

    $logger->log_to_file(sprintf("Documentation system initialized with %d pages",
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
    # If no role found in session but user exists, try to get roles from user object
    elsif ($c->user_exists) {
        if ($c->user && $c->user->can('roles') && $c->user->roles) {
            my @user_roles = ref($c->user->roles) eq 'ARRAY' ? @{$c->user->roles} : ($c->user->roles);
            if (grep { lc($_) eq 'admin' } @user_roles) {
                $user_role = 'admin';
                $is_admin = 1;
            } else {
                # Otherwise use the first role
                $user_role = $user_roles[0] || 'normal';
            }
        } else {
            $user_role = 'normal';
        }
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'index',
            "User role determined from user object: $user_role, is_admin: $is_admin");
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
    # Modified to ensure admins can see all documentation and pages are properly categorized
    my %filtered_pages;
    foreach my $page_name (keys %$pages) {
        my $metadata = $pages->{$page_name};

        # Use the is_admin flag we set earlier
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

        # Generate URL that matches the routing pattern: /Documentation/view/page_name
        # The view action is configured as :Path('/Documentation/view') :Args(1)
        # So we need to create URLs in the format /Documentation/view/page_name
        my $url = $c->uri_for('/Documentation/view', $page_name);

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
        # But always include for admins (check both user_role and session roles)
        # Use the is_admin flag we set earlier
        my $has_role = $is_admin; # Admins can see everything

        # Log category access check
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'index',
            "Category access check for $category_key: is_admin=$is_admin, user_role=$user_role");

        # If still not admin, check for other matching roles
        unless ($has_role) {
            foreach my $role (@{$category->{roles}}) {
                # Check if role matches user_role or is in session roles
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
                        "Normal role access granted to category $category_key for user with role $user_role");
                    last;
                }
            }
        }

        # Log role access decision
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'index',
            "Category $category_key access: " . ($has_role ? "granted" : "denied") . " for user with role $user_role");
        
        if (!$has_role) {
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'index',
                "Access denied to category $category_key for user with role $user_role");
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

    # Add debug message to stash
    my $admin_categories = join(', ', grep { exists $filtered_categories{$_} } qw(admin_guides proxmox controllers changelog));
    my $debug_msg = sprintf(
        "User role: %s, Display role: %s, Session roles: %s, Admin categories: %s, Has admin in session: %s",
        $user_role,
        ($user_role eq 'admin' ? 'Administrator' : $user_role),
        ($c->session->{roles} ? join(', ', @{$c->session->{roles}}) : 'none'),
        $admin_categories || 'none',
        ($c->session->{roles} && ref $c->session->{roles} eq 'ARRAY' && grep { $_ eq 'admin' } @{$c->session->{roles}}) ? 'Yes' : 'No'
    );

    # Add pages and completed items to stash
    $c->stash(
        documentation_pages => \%filtered_pages,
        structured_pages => $structured_pages,
        sorted_page_names => \@sorted_pages,
        completed_items => $completed_items,
        categories => \%filtered_categories,
        user_role => $user_role,
        is_admin => $is_admin,
        site_name => $site_name,
        debug_msg => $debug_msg,
        additional_css => ['/static/css/themes/documentation.css'],
        template => 'Documentation/index.tt'
    );

    # Log debug information
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'index', $debug_msg);

    $c->forward($c->view('TT'));
}
# Admin documentation
# Legacy documentation route - serves the original ComservDocumentation.tt template
sub comserv_documentation :Path('ComservDocumentation') :Args(0) {
    my ($self, $c) = @_;
    
    # Log access to legacy documentation
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'comserv_documentation', 
        "Accessing legacy ComservDocumentation template");
    
    # Set template to the legacy documentation file
    $c->stash(template => 'Documentation/ComservDocumentation.tt');
    
    # Forward to the TT view
    $c->forward($c->view('TT'));
}

sub admin :Path('admin') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'admin', "Accessing admin documentation");
    $c->stash(template => 'Documentation/admin.tt');
    $c->forward($c->view('TT'));
}
# Admin guide
sub admin_guide :Path('admin_guide') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'admin_guide', "Accessing admin guide documentation");
    $c->stash(template => 'Documentation/admin_guides.tt');
    $c->forward($c->view('TT'));
}
# API reference
sub api_reference :Path('api_reference') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'api_reference', "Accessing API reference documentation");
    $c->stash(template => 'Documentation/api_reference.tt');
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

    # ENHANCED LOGGING: Reduced debug verbosity for frequently called method
    # Only log if page_name is unusual or contains special characters that need processing
    my $needs_debug = ($page_name =~ /[_\-]/ || $page_name =~ /\.(md|tt|html|txt)$/i);
    
    if ($needs_debug) {
        $self->logging->log_with_details(undef, 'debug', __FILE__, __LINE__, '_format_title',
            "Formatting complex title from: $page_name");
    }

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

    # Only log the result if we logged the input (for complex titles)
    if ($needs_debug) {
        $self->logging->log_with_details(undef, 'debug', __FILE__, __LINE__, '_format_title',
            "Formatted title result: $title");
    }

    return $title;
}

# Generate proper URL for documentation files
sub _generate_doc_url {
    my ($self, $c, $page_name, $path) = @_;
    
    # Default to using the view action with page name
    my $url = $c->uri_for($self->action_for('view'), [$page_name]);
    
    # If path ends with .tt, append .tt to URL to ensure consistency
    if ($path =~ /\.tt$/) {
        $url = $c->uri_for('/Documentation/' . $page_name . '.tt');
    }
    
    return $url;
}

# Search API endpoint
sub search :Path('/Documentation/search') :Args(0) {
    my ($self, $c) = @_;
    
    # Get search query from parameters
    my $query = $c->request->param('q') || '';
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'search', 
        "Documentation search requested: $query");
    
    # Return empty results if no query (allow single character searches for debugging)
    if (!$query || length($query) < 1) {
        $c->response->content_type('application/json');
        $c->response->body('{"results": [], "message": "Query too short"}');
        return;
    }
    
    # Get all documentation pages
    my $pages = $self->documentation_pages;
    my @results;
    
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'search', 
        "Total pages available for search: " . scalar(keys %$pages));
    
    # If no pages found, try to reinitialize
    if (scalar(keys %$pages) == 0) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'search', 
            "No documentation pages found - attempting to reinitialize");
        
        # Force rebuild of documentation pages
        $self->BUILD();
        $pages = $self->documentation_pages;
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'search', 
            "After reinitialize: " . scalar(keys %$pages) . " pages available");
    }
    

    
    # Search through pages
    foreach my $page_name (keys %$pages) {
        my $metadata = $pages->{$page_name};
        my $title = $self->_format_title($page_name);
        
        # Initialize match tracking
        my $title_match = $title =~ /\Q$query\E/i;
        my $path_match = $metadata->{path} =~ /\Q$query\E/i;
        my $name_match = $page_name =~ /\Q$query\E/i;
        my $content_match = 0;
        my $match_context = '';
        
        # Always search file content for comprehensive results
        my $file_content = $self->_read_file_content($c, $metadata->{path});
        

        
        if ($file_content && $file_content =~ /\Q$query\E/i) {
            $content_match = 1;
            # Extract context around the match (up to 150 characters)
            $match_context = $self->_extract_match_context($file_content, $query, 150);
            
        }
        
        # Include if any match found
        if ($title_match || $path_match || $name_match || $content_match) {
            my $result = {
                name => $page_name,
                title => $title,
                path => $metadata->{path},
                url => $c->uri_for('/Documentation/view', $page_name)->as_string,
                site => $metadata->{site} || 'all',
                match_type => $title_match ? 'title' : 
                             $path_match ? 'path' : 
                             $name_match ? 'name' : 'content'
            };
            
            # Add context for content matches
            if ($content_match && $match_context) {
                $result->{context} = $match_context;
            }
            
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'search', 
                "MATCH FOUND: $page_name (type: $result->{match_type}) -> URL: $result->{url}");
            
            push @results, $result;
        } else {
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'search', 
                "NO MATCH: $page_name (title:$title_match, path:$path_match, name:$name_match, content:$content_match)");
        }
    }
    
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'search', 
        "Search results found: " . scalar(@results));
    
    # Sort results by relevance (title matches first, then path, then name, then content)
    @results = sort {
        my %match_priority = (title => 4, path => 3, name => 2, content => 1);
        my $a_priority = $match_priority{$a->{match_type}} || 0;
        my $b_priority = $match_priority{$b->{match_type}} || 0;
        $b_priority <=> $a_priority || $a->{title} cmp $b->{title};
    } @results;
    
    # Limit results to 100 for comprehensive search
    @results = splice(@results, 0, 100);
    
    # Return JSON response
    eval {
        require JSON;
        my $json_response = JSON::encode_json({
            results => \@results,
            query => $query,
            count => scalar(@results)
        });
        
        $c->response->content_type('application/json');
        $c->response->body($json_response);
        
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'search', 
            "JSON response sent successfully");
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'search', 
            "Error encoding JSON response: $@");
        $c->response->content_type('application/json');
        $c->response->body('{"results": [], "error": "JSON encoding failed"}');
    }
}

# Force rebuild endpoint for testing
sub force_rebuild :Path('force_rebuild') :Args(0) {
    my ($self, $c) = @_;
    
    # Clear existing pages and categories
    $self->documentation_pages({});
    $self->documentation_categories({
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
        'models' => {
            title => 'Model Documentation',
            description => 'Documentation for system models',
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
    });
    
    # Force rebuild
    $self->BUILD();
    
    my $pages = $self->documentation_pages;
    my $total_count = scalar(keys %$pages);
    
    # Get sample of pages from different directories
    my %dir_samples;
    foreach my $page_name (keys %$pages) {
        my $path = $pages->{$page_name}->{path};
        if ($path =~ m{Documentation/([^/]+)/}) {
            my $dir = $1;
            $dir_samples{$dir} ||= [];
            push @{$dir_samples{$dir}}, $page_name if @{$dir_samples{$dir}} < 3;
        }
    }
    
    $c->response->content_type('application/json');
    eval {
        require JSON;
        my $json_response = JSON::encode_json({
            total_pages => $total_count,
            directory_samples => \%dir_samples,
            message => "Rebuild completed"
        });
        $c->response->body($json_response);
    };
    if ($@) {
        $c->response->body('{"error": "JSON encoding failed"}');
    }
}

# Debug endpoint to test file reading
sub debug_search :Path('debug_search') :Args(0) {
    my ($self, $c) = @_;
    
    my $query = $c->request->param('q') || 'account';
    
    # Get all documentation pages
    my $pages = $self->documentation_pages;
    my @debug_results;
    
    # Test reading a few files
    my $count = 0;
    foreach my $page_name (keys %$pages) {
        last if $count >= 3;
        
        my $metadata = $pages->{$page_name};
        my $file_content = $self->_read_file_content($c, $metadata->{path});
        
        push @debug_results, {
            page_name => $page_name,
            path => $metadata->{path},
            content_length => defined $file_content ? length($file_content) : 0,
            has_query => defined $file_content ? ($file_content =~ /\Q$query\E/i ? 1 : 0) : 0,
            sample_content => defined $file_content ? substr($file_content, 0, 100) : 'No content'
        };
        
        $count++;
    }
    
    $c->response->content_type('application/json');
    eval {
        require JSON;
        my $json_response = JSON::encode_json({
            query => $query,
            total_pages => scalar(keys %$pages),
            debug_results => \@debug_results
        });
        $c->response->body($json_response);
    };
    if ($@) {
        $c->response->body('{"error": "JSON encoding failed"}');
    }
}

# Display specific documentation page

# Database schema
sub database_schema :Path('database_schema') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'database_schema', "Accessing database schema documentation");
    $c->stash(template => 'Documentation/database_schema.tt');
    $c->forward($c->view('TT'));
}


# Auto method for all documentation requests
sub document_management :Path('document_management') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'document_management', "Accessing document management documentation");
    $c->stash(template => 'Documentation/document_management.tt');
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
    $c->stash(template => 'Documentation/proxmox/Proxmox_CD_Visibility.tt');
    $c->forward($c->view('TT'));
}

# Recent updates
sub recent_updates :Path('recent_updates') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'recent_updates', "Accessing recent updates documentation");
    $c->stash(template => 'Documentation/recent_updates.tt');
    $c->forward($c->view('TT'));
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
# Starman Updated documentation
sub starman_updated :Path('Starman') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'starman_updated',
        "Accessing updated Starman documentation");
    $c->stash(template => 'Documentation/Starman.tt');
    $c->forward($c->view('TT'));
}

# Explicitly define routes for common documentation pages
# This allows for better URL structure and SEO

# Document management documentation

# System overview
sub system_overview :Path('system_overview') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'system_overview', "Accessing system overview documentation");
    $c->stash(template => 'Documentation/system_overview.tt');
    $c->forward($c->view('TT'));
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
    my $md_file = $c->path_to('root', 'Documentation', 'theme_system_implementation.tt');

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
            error_msg => "Documentation file 'theme_system_implementation.tt' not found",
            template => 'Documentation/error.tt'
        );
    }

    $c->forward($c->view('TT'));
}



# User guide
sub user_guide :Path('user_guide') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'user_guide', "Accessing user guide documentation");
    $c->stash(template => 'Documentation/user_guide.tt');
    $c->forward($c->view('TT'));
}

# Documentation system overview
sub documentation_system_overview :Path('documentation_system_overview') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'documentation_system_overview', 
        "Accessing documentation system overview");
    
    # Check if the markdown file exists
    my $md_file = $c->path_to('root', 'Documentation', 'documentation_system_overview.tt');
    
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
            error_msg => "Documentation file 'documentation_system_overview.tt' not found",
            template => 'Documentation/error.tt'
        );
    }
    
    $c->forward($c->view('TT'));
}

# Documentation filename issue
sub documentation_filename_issue :Path('documentation_filename_issue') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'documentation_filename_issue', 
        "Accessing documentation filename issue documentation");
    
    # Check if the markdown file exists
    my $md_file = $c->path_to('root', 'Documentation', 'documentation_filename_issue.tt');
    
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
            error_msg => "Documentation file 'documentation_filename_issue.tt' not found",
            template => 'Documentation/error.tt'
        );
    }
    
    $c->forward($c->view('TT'));
}

# Logging best practices
sub logging_best_practices :Path('logging_best_practices') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'logging_best_practices', 
        "Accessing logging best practices documentation");
    
    # Check if the markdown file exists
    my $md_file = $c->path_to('root', 'Documentation', 'logging_best_practices.tt');
    
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
            error_msg => "Documentation file 'logging_best_practices.md' not found",
            template => 'Documentation/error.tt'
        );
    }
    
    $c->forward($c->view('TT'));
}

# AI Assistants guidelines
sub ai_assistants :Path('ai_assistants') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'ai_assistants', 
        "Accessing AI Assistants guidelines documentation");
    
    # Set the template
    $c->stash(template => 'Documentation/AIAssistants.tt');
    $c->forward($c->view('TT'));
}

# Documentation update summary
sub documentation_update_summary :Path('documentation_update_summary') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'documentation_update_summary', 
        "Accessing documentation update summary");
    
    # Check if the markdown file exists
    my $md_file = $c->path_to('root', 'Documentation', 'documentation_update_summary.md');
    
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
            error_msg => "Documentation file 'documentation_update_summary.md' not found",
            template => 'Documentation/error.tt'
        );
    }
    
    $c->forward($c->view('TT'));
}


# Handle view for both uppercase and lowercase routes
sub view :Path('/Documentation/view') :Args(1) {
    my ($self, $c, $page) = @_;

    # Log the action with detailed information
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view', 
        "Accessing documentation page: $page, Username: " . ($c->session->{username} || 'unknown') . 
        ", Site: " . ($c->stash->{SiteName} || 'default') . 
        ", Session roles: " . (ref $c->session->{roles} eq 'ARRAY' ? join(', ', @{$c->session->{roles}}) : 'none'));
    


    # Get all user roles and determine admin status
    # IMPORTANT: The $is_admin flag determines if a user has admin privileges
    # This is based on checking if 'admin' is in the user's roles array
    # DO NOT modify this to use a primary/display role - we need to check ALL roles
    # WARNING: Always use session roles rather than a hardcoded role value
    # to prevent permissions issues with admin users
    my $user_role = '';  # Will be set based on actual roles, not hardcoded
    my $is_admin = 0;  # Flag to track if user has admin role
    my @user_roles = (); # Array to store all user roles
    
    # First check if user is authenticated
    if ($c->user_exists) {
        # Check if roles are stored in session
        if ($c->session->{roles} && ref $c->session->{roles} eq 'ARRAY' && @{$c->session->{roles}}) {
            # Store all roles from session
            @user_roles = @{$c->session->{roles}};
            
            # Log all roles for debugging
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'view', 
                "Session roles: " . join(", ", @user_roles));
            
            # Check if admin is one of the roles
            if (grep { lc($_) eq 'admin' } @user_roles) {
                $user_role = 'admin';
                $is_admin = 1;
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'view',
                    "Admin role found in session roles");
            } else {
                # Set display role to first role if available
                $user_role = $user_roles[0] || '';
            }
        } else {
            # Fallback to user's roles if available
            if ($c->user && $c->user->can('roles') && $c->user->roles) {
                @user_roles = ref($c->user->roles) eq 'ARRAY' ? @{$c->user->roles} : ($c->user->roles);
                
                if (grep { lc($_) eq 'admin' } @user_roles) {
                    $user_role = 'admin';
                    $is_admin = 1;
                    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'view',
                        "Admin role found in user object roles");
                } else {
                    # Set display role to first role if available
                    $user_role = $user_roles[0] || '';
                }
            } else {
                # If no roles are found, leave the user roles array empty
                # rather than assigning a fictitious 'user' role
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'view',
                    "No roles found in user object or session");
            }
        }
        
        # Special case for site CSC - ensure admin role is recognized
        if ($c->stash->{SiteName} && $c->stash->{SiteName} eq 'CSC') {
            # Check if user should have admin privileges on this site
            if ($c->session->{username} && ($c->session->{username} eq 'Shanta' || $c->session->{username} eq 'admin')) {
                $user_role = 'admin';
                $is_admin = 1;
                # Add admin to roles array if not already present
                push @user_roles, 'admin' unless grep { lc($_) eq 'admin' } @user_roles;
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view', 
                    "Admin role granted for CSC site user: " . $c->session->{username});
            }
        }
        
        # If no roles are found but we're authenticated, at minimum set a role based on session data
        # This ensures authenticated users have at least basic access
        if (@user_roles == 0 && $c->user_exists) {
            # Check if we have admin in session roles
            if ($c->session->{roles} && ref $c->session->{roles} eq 'ARRAY' && 
                grep { lc($_) eq 'admin' } @{$c->session->{roles}}) {
                push @user_roles, 'admin';
                $is_admin = 1;
                $user_role = 'admin';
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view', 
                    "Using 'admin' from session roles for permission check");
            }
            # Otherwise use session username for basic access
            elsif ($c->session->{username}) {
                push @user_roles, 'normal';
                $user_role = 'normal';
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view', 
                    "Using default 'normal' role for authenticated user");
            }
        }
        
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'view', 
            "User role determined: $user_role, is_admin: $is_admin, all roles: " . 
            join(', ', @user_roles) . ", site: " . ($c->stash->{SiteName} || 'default'));
    } else {
        # Not authenticated - set minimal access
        @user_roles = ('normal');
        $user_role = 'normal';
    }
    # Add admin check for Proxmox docs
    if (($page =~ /^Proxmox/ || $page =~ /^proxmox_commands$/) && !$c->check_user_roles('admin')) {
        $c->response->redirect($c->uri_for('/access_denied'));
        return;
    }

    # Get the current site name
    my $site_name = $c->stash->{SiteName} || 'default';

    # Sanitize the page name to prevent directory traversal (preserve dashes)
    $page =~ s/[^a-zA-Z0-9_\.\-]//g;
    
    # SPECIAL CASE: Always allow access to FAQ page regardless of roles or site
    # This ensures the FAQ is accessible to everyone
    if (lc($page) eq 'faq') {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view',
            "Auto-granting access to FAQ page for all users");
            
        # Check for the file in standard locations - only using .tt files
        my @potential_paths = (
            "Documentation/faq.tt",
            "Documentation/FAQ.tt",
            "Documentation/roles/normal/faq.tt",
            "Documentation/user_guides/faq.tt"
        );
        
        my $found_path = undef;
        foreach my $test_path (@potential_paths) {
            my $full_path = $c->path_to('root', $test_path);
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'view',
                "Checking for FAQ at: $full_path (exists: " . (-e $full_path ? 'Yes' : 'No') . ")");
                
            if (-e $full_path && !-d $full_path) {
                $found_path = $test_path;
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view',
                    "Found FAQ at: $test_path");
                last;
            }
        }
        
        if ($found_path) {
            $c->stash(
                template => $found_path,
                user_role => $user_role,
                user_roles => \@user_roles,
                site_name => $site_name
            );
            return $c->forward($c->view('TT'));
        } else {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'view',
                "Could not find FAQ file in any standard location");
        }
    }

    # Check if the user has permission to view this page
    # Modified to ensure admins can access all documentation
    my $pages = $self->documentation_pages;
    if (exists $pages->{$page}) {
        my $metadata = $pages->{$page};
        
        # Special handling for common documentation that should be accessible to all
        # This makes pages like FAQ, getting_started, etc. accessible regardless of role
        if ($page =~ /^(faq|getting_started|account_management|user_guide)$/i) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view',
                "Auto-granting access to commonly accessible page: $page");
            # Override the metadata to ensure it's accessible to all
            $metadata->{site} = 'all';
            $metadata->{roles} = ['normal', 'editor', 'admin', 'developer'];
        }

        # Admins can access all documentation regardless of site or role restrictions
        # IMPORTANT: We check $is_admin which is set based on the presence of 'admin' in the user's roles array
        # This ensures that any user with the admin role can access all documentation
        if ($is_admin) {
            # Log admin access to documentation with all user roles
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view',
                "Admin access granted to documentation: $page (user: " . ($c->session->{username} || 'unknown') . 
                ", site: " . ($site_name || 'default') . ", roles: " . join(', ', @user_roles) . ")");
        } else {
            # Check site-specific access for non-admins
            if ($metadata->{site} ne 'all' && $metadata->{site} ne $site_name) {
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'view',
                    "Access denied to site-specific documentation: $page (user site: $site_name, doc site: $metadata->{site})");

                # Pass all user roles to the template instead of just the primary role
                $c->stash(
                    error_msg => "You don't have permission to view this documentation page. It's specific to the '$metadata->{site}' site.",
                    user_roles => \@user_roles,  # Pass array of roles
                    site_name => $site_name,
                    page_name => $page,  # Add page name for debug information
                    template => 'Documentation/error.tt'
                );
                return $c->forward($c->view('TT'));
            }

            # Check role-based access for non-admins
            my $has_role = 0;
            
            # Use the user_roles array we already populated earlier
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'view',
                "Checking user roles: " . join(', ', @user_roles) . " against required roles: " . join(', ', @{$metadata->{roles}}));
            
            # Check if any user role matches any required role
            foreach my $required_role (@{$metadata->{roles}}) {
                # Special case for "user" or "normal" role - any authenticated user can access
                if ((lc($required_role) eq 'user' || lc($required_role) eq 'normal') && $c->user_exists) {
                    $has_role = 1;
                    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'view',
                        "Basic access granted to page $page for authenticated user");
                    last;
                }
                
                # Check if admin role is required and user has admin role
                if (lc($required_role) eq 'admin' && $is_admin) {
                    $has_role = 1;
                    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'view',
                        "Admin access granted to page $page");
                    last;
                }
                
                # Check each user role against the required role
                foreach my $role (@user_roles) {
                    if (lc($required_role) eq lc($role)) {
                        $has_role = 1;
                        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'view',
                            "Role match: user role $role matches required role $required_role for page $page");
                        last;
                    }
                }
                
                if ($has_role) {
                    last; # Exit outer loop if we found a match
                }
            }

            unless ($has_role) {
                # Check for session roles that might not be in our user_roles array
                my $session_has_admin = 0;
                if ($c->session->{roles} && ref $c->session->{roles} eq 'ARRAY') {
                    foreach my $session_role (@{$c->session->{roles}}) {
                        if (lc($session_role) eq 'admin') {
                            $session_has_admin = 1;
                            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view',
                                "Found admin role in session that wasn't in user_roles array");
                            last;
                        }
                    }
                }
                
                # If we found admin in session roles, grant access
                if ($session_has_admin) {
                    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view',
                        "Granting access based on admin role in session");
                } else {
                    # Log detailed information about the access denial
                    my $roles_str = join(', ', @{$metadata->{roles}});
                    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'view',
                        "Access denied to role-protected documentation: $page (user role: $user_role, username: " . 
                        ($c->session->{username} || 'unknown') . ", site: " . ($site_name || 'default') . 
                        ", required roles: $roles_str)");
    
                    # Log session roles for debugging
                    if ($c->session->{roles} && ref $c->session->{roles} eq 'ARRAY') {
                        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'view',
                            "Session roles: " . join(", ", @{$c->session->{roles}}));
                    }
    
                    # Pass all user roles to the template instead of just the primary role
                    # This allows the template to show the complete list of roles
                    $c->stash(
                        error_msg => "You don't have permission to view this documentation page. It requires higher privileges.",
                        user_roles => \@user_roles,  # Pass the entire roles array
                        session_roles => $c->session->{roles} || [], # Pass session roles explicitly
                        site_name => $site_name,
                        required_roles => $roles_str,
                        template => 'Documentation/error.tt'
                    );
                    return $c->forward($c->view('TT'));
                }
            }
        }
        
        # If we reach here, access is granted - use the metadata path as template
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view',
            "Access granted to documentation: $page, using template: $metadata->{path}");
        
        $c->stash(
            template => $metadata->{path},
            user_role => $user_role,
            user_roles => \@user_roles,
            site_name => $site_name,
            page_name => $page,
            display_role => $user_role eq 'admin' ? 'Administrator' : 
                           $user_role eq 'developer' ? 'Developer' : 
                           $user_role eq 'editor' ? 'Editor' : 'User'
        );
        return $c->forward($c->view('TT'));
    }

    # First check if it's a direct file request (with extension)
    if ($page =~ /\./) {
        # Special handling for .tt files - process them through the template engine
        if ($page =~ /\.tt$/i) {
            my $template_path = "Documentation/$page";
            my $full_path = $c->path_to('root', $template_path);
            
            # Log debugging information about file paths
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'view',
                "Looking for template file at path: $full_path (exists: " . (-e $full_path ? 'Yes' : 'No') . ")");
            
            if (-e $full_path && !-d $full_path) {
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view',
                    "Processing template file: $template_path");
                
                # Set the template and additional context
                $c->stash(
                    template => $template_path,
                    user_role => $user_role,
                    site_name => $site_name,
                    display_role => $user_role eq 'admin' ? 'Administrator' : 
                                   $user_role eq 'developer' ? 'Developer' : 
                                   $user_role eq 'editor' ? 'Editor' : 'User'
                );
                # Must explicitly forward to the view to process the template
                return $c->forward($c->view('TT'));
            } else {
                # Check if the file exists without the .tt extension (for convenience URLs)
                my $alt_path = $page;
                $alt_path =~ s/\.tt$//i;
                my $alt_template_path = "Documentation/$alt_path.tt";
                my $alt_full_path = $c->path_to('root', $alt_template_path);
                
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'view',
                    "Looking for alternate template file at path: $alt_full_path (exists: " . (-e $alt_full_path ? 'Yes' : 'No') . ")");
                
                if (-e $alt_full_path && !-d $alt_full_path) {
                    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view',
                        "Processing alternate template file: $alt_template_path");
                    
                    # Set the template and additional context
                    $c->stash(
                        template => $alt_template_path,
                        user_role => $user_role,
                        site_name => $site_name,
                        display_role => $user_role eq 'admin' ? 'Administrator' : 
                                       $user_role eq 'developer' ? 'Developer' : 
                                       $user_role eq 'editor' ? 'Editor' : 'User'
                    );
                    # Must explicitly forward to the view to process the template
                    return $c->forward($c->view('TT'));
                }
            }
        }
        
        # Handle other file types as static files
        my $file_path = "Documentation/$page";
        my $full_path = $c->path_to('root', $file_path);
        
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'view',
            "Looking for static file at path: $full_path (exists: " . (-e $full_path ? 'Yes' : 'No') . ")");

        if (-e $full_path && !-d $full_path) {
            # Determine content type based on file extension
            my $content_type = 'text/plain';  # Default
            my $is_markdown = 0;
            
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
            } elsif ($page =~ /\.md$/i) {
                $content_type = 'text/html';
                $is_markdown = 1;
            }
            
            # Read the file - binary mode for all files to be safe
            open my $fh, '<:raw', $full_path or die "Cannot open $full_path: $!";
            my $content = do { local $/; <$fh> };
            close $fh;
            
            # Special handling for Markdown
            if ($is_markdown) {
                # Convert Markdown to HTML
                eval {
                    require Text::Markdown;
                    my $markdown = Text::Markdown->new;
                    $content = $markdown->markdown($content);
                    
                    # Wrap in basic HTML
                    $content = <<HTML;
<!DOCTYPE html>
<html>
<head>
    <title>$page</title>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <style>
        body { font-family: Arial, sans-serif; line-height: 1.6; max-width: 900px; margin: 0 auto; padding: 20px; }
        pre { background: #f4f4f4; border: 1px solid #ddd; border-radius: 3px; padding: 15px; overflow: auto; }
        code { background: #f4f4f4; padding: 2px 5px; border-radius: 3px; }
        table { border-collapse: collapse; width: 100%; }
        th, td { border: 1px solid #ddd; padding: 8px; }
        th { background-color: #f2f2f2; }
    </style>
</head>
<body>
    <div class="documentation-container">
        $content
    </div>
</body>
</html>
HTML
                };
                if ($@) {
                    $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'view',
                        "Error converting markdown: $@");
                    $content_type = 'text/plain'; # Fallback to text if conversion fails
                }
            }
            
            # For API-related pages that aren't found as .tt, check if a corresponding .tt file exists
            if (($page =~ /^api/i || $page =~ /api_/i) && !$is_markdown) {
                # Try to find a .tt file with a similar name
                my $alt_path = $page;
                $alt_path =~ s/\.\w+$//; # Remove any extension
                my $alt_template_path = "Documentation/$alt_path.tt";
                my $alt_full_path = $c->path_to('root', $alt_template_path);
                
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'view',
                    "Looking for API template file at path: $alt_full_path (exists: " . (-e $alt_full_path ? 'Yes' : 'No') . ")");
                
                if (-e $alt_full_path && !-d $alt_full_path) {
                    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view',
                        "Processing API template file: $alt_template_path");
                    
                    # Set the template and additional context
                    $c->stash(
                        template => $alt_template_path,
                        user_role => $user_role,
                        site_name => $site_name,
                        display_role => $user_role eq 'admin' ? 'Administrator' : 
                                       $user_role eq 'developer' ? 'Developer' : 
                                       $user_role eq 'editor' ? 'Editor' : 'User'
                    );
                    # Must explicitly forward to the view to process the template
                    return $c->forward($c->view('TT'));
                }
            }

            # Set the response
            $c->response->content_type($content_type);
            $c->response->body($content);
            return;
        }
    }

    # Check if it's a template file (previously markdown)
    my $tt_path = "Documentation/$page.tt";
    my $tt_full_path = $c->path_to('root', $tt_path);
    
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'view',
        "Looking for template file at path: $tt_full_path (exists: " . (-e $tt_full_path ? 'Yes' : 'No') . ")");
    
    # For API links that don't have .tt extension
    if (!-e $tt_full_path && ($page =~ /^api/i || $page =~ /api_/i)) {
        # Try potential variations of the API path
        my @potential_paths = (
            "Documentation/api.tt",                   # Main API docs
            "Documentation/api_credentials.tt",      # API credentials
            "Documentation/api/$page.tt",            # API subfolder
            "Documentation/api_$page.tt"             # API prefixed
        );
        
        foreach my $path (@potential_paths) {
            my $potential_path = $c->path_to('root', $path);
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'view',
                "Looking for API template at alternate path: $potential_path (exists: " . (-e $potential_path ? 'Yes' : 'No') . ")");
                
            if (-e $potential_path && !-d $potential_path) {
                $tt_path = $path;
                $tt_full_path = $potential_path;
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view',
                    "Found API template at alternate path: $tt_path");
                last;
            }
        }
    }

    if (-e $tt_full_path) {
        # Check if this is a .tt file that should be processed by the template engine
        if ($tt_full_path =~ /\.tt$/i) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view',
                "Processing template file directly: $tt_path");
            
            # Set the template and additional context
            $c->stash(
                template => $tt_path,
                user_role => $user_role,
                site_name => $site_name,
                display_role => $user_role eq 'admin' ? 'Administrator' : 
                               $user_role eq 'developer' ? 'Developer' : 
                               $user_role eq 'editor' ? 'Editor' : 'User'
            );
            # Must explicitly forward to the view to process the template
            return $c->forward($c->view('TT'));
        } else {
            # For non-TT files (like markdown), display content
            # Read the template file
            open my $fh, '<:encoding(UTF-8)', $tt_full_path or die "Cannot open $tt_full_path: $!";
            my $content = do { local $/; <$fh> };
            close $fh;

            # Get file modification time
            my $mtime = (stat($tt_full_path))[9];
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
    }

    # If not a markdown file, try as a template
    my $template_path = "Documentation/$page.tt";
    my $full_path = $c->path_to('root', $template_path);

    if (-e $full_path) {
        # Set the template and additional context
        $c->stash(
            template => $template_path,
            user_role => $user_role,
            site_name => $site_name,
            display_role => $user_role eq 'admin' ? 'Administrator' : 
                           $user_role eq 'developer' ? 'Developer' : 
                           $user_role eq 'editor' ? 'Editor' : 'User'
        );
        # Must explicitly forward to the view to process the template
        return $c->forward($c->view('TT'));
    } else {
        # Check for site-specific paths
        my $site_path = "Documentation/sites/$site_name/$page.tt";
        my $site_full_path = $c->path_to('root', $site_path);
        
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'view',
            "Looking for site-specific template file at path: $site_full_path (exists: " . (-e $site_full_path ? 'Yes' : 'No') . ")");

        if (-e $site_full_path) {
            # Set the template for site-specific documentation
            $c->stash(
                template => $site_path,
                user_role => $user_role,
                site_name => $site_name,
                display_role => $user_role eq 'admin' ? 'Administrator' : 
                               $user_role eq 'developer' ? 'Developer' : 
                               $user_role eq 'editor' ? 'Editor' : 'User'
            );
            # Must explicitly forward to the view to process the template
            return $c->forward($c->view('TT'));
        } else {
            # Check for role-specific paths
            my $role_path = "Documentation/roles/$user_role/$page.tt";
            my $role_full_path = $c->path_to('root', $role_path);

            if (-e $role_full_path) {
                # Set the template for role-specific documentation
                $c->stash(
                    template => $role_path,
                    user_role => $user_role,
                    site_name => $site_name,
                    display_role => $user_role eq 'admin' ? 'Administrator' : 
                                   $user_role eq 'developer' ? 'Developer' : 
                                   $user_role eq 'editor' ? 'Editor' : 'User'
                );
                # Must explicitly forward to the view to process the template
                return $c->forward($c->view('TT'));
            } else {
                # Check if there's a default path defined in the documentation_config.json file
                my $config_file = $c->path_to('root', 'Documentation', 'documentation_config.json');
                my $default_path = undef;
                
                if (-e $config_file) {
                    # Read the JSON file
                    eval {
                        open my $fh, '<:encoding(UTF-8)', $config_file or die "Cannot open $config_file: $!";
                        my $json_content = do { local $/; <$fh> };
                        close $fh;
                        
                        # Parse the JSON content
                        require JSON;
                        my $config = JSON::decode_json($json_content);
                        
                        # Check if there's a default path for this page
                        if ($config->{default_paths} && $config->{default_paths}{$page}) {
                            $default_path = $config->{default_paths}{$page};
                            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view',
                                "Found default path for $page: $default_path");
                        }
                    };
                    if ($@) {
                        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'view',
                            "Error loading documentation_config.json: $@");
                    }
                }
                
                # If a default path is defined, try to use it
                if ($default_path) {
                    my $full_default_path = $c->path_to('root', $default_path);
                    
                    if (-e $full_default_path) {
                        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view',
                            "Using default path for $page: $default_path");
                            
                        # Determine file type based on extension
                        if ($default_path =~ /\.md$/i) {
                            # Read the markdown file
                            open my $fh, '<:encoding(UTF-8)', $full_default_path or die "Cannot open $full_default_path: $!";
                            my $content = do { local $/; <$fh> };
                            close $fh;
                            
                            # Get file modification time
                            my $mtime = (stat($full_default_path))[9];
                            my $last_updated = localtime($mtime);
                            $last_updated = $last_updated->strftime('%Y-%m-%d %H:%M:%S');
                            
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
                        } elsif ($default_path =~ /\.tt$/i) {
                            # Set the template
                            $c->stash(
                                template => $default_path,
                                user_role => $user_role,
                                site_name => $site_name,
                                display_role => $user_role eq 'admin' ? 'Administrator' : 
                                               $user_role eq 'developer' ? 'Developer' : 
                                               $user_role eq 'editor' ? 'Editor' : 'User'
                            );
                            # Must explicitly forward to the view to process the template
                            return $c->forward($c->view('TT'));
                        } else {
                            # Handle other file types as static files
                            open my $fh, '<:raw', $full_default_path or die "Cannot open $full_default_path: $!";
                            my $content = do { local $/; <$fh> };
                            close $fh;
                            
                            # Determine content type based on file extension
                            my $content_type = 'text/plain';  # Default
                            if ($default_path =~ /\.json$/i) {
                                $content_type = 'application/json';
                            } elsif ($default_path =~ /\.html?$/i) {
                                $content_type = 'text/html';
                            } elsif ($default_path =~ /\.css$/i) {
                                $content_type = 'text/css';
                            } elsif ($default_path =~ /\.js$/i) {
                                $content_type = 'application/javascript';
                            } elsif ($default_path =~ /\.pdf$/i) {
                                $content_type = 'application/pdf';
                            } elsif ($default_path =~ /\.(jpe?g|png|gif)$/i) {
                                $content_type = 'image/' . lc($1);
                            }
                            
                            # Set the response
                            $c->response->content_type($content_type);
                            $c->response->body($content);
                            return;
                        }
                    } else {
                        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'view',
                            "Default path for $page not found: $default_path");
                    }
                }
                
                # If we get here, the page was not found
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

# Virtualmin Integration documentation
sub virtualmin_integration :Path('Virtualmin_Integration') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'virtualmin_integration',
        "Accessing Virtualmin Integration documentation");
    $c->stash(template => 'Documentation/Virtualmin_Integration.tt');
    $c->forward($c->view('TT'));
}

# All Changelog page
sub all_changelog :Path('all_changelog') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'all_changelog',
        "Accessing All Changelog documentation");
    
    # Get the current user's role
    my $user_role = 'normal';  # Default to normal user
    my $is_admin = 0;  # Flag to track if user has admin role
    
    # First check session roles
    if ($c->session->{roles} && ref $c->session->{roles} eq 'ARRAY' && @{$c->session->{roles}}) {
        # If user has multiple roles, prioritize admin role
        if (grep { lc($_) eq 'admin' } @{$c->session->{roles}}) {
            $user_role = 'admin';
            $is_admin = 1;
        } else {
            # Otherwise use the first role
            $user_role = $c->session->{roles}->[0];
        }
    }
    # If no role found in session but user exists, try to get roles from user object
    elsif ($c->user_exists) {
        if ($c->user && $c->user->can('roles') && $c->user->roles) {
            my @user_roles = ref($c->user->roles) eq 'ARRAY' ? @{$c->user->roles} : ($c->user->roles);
            if (grep { lc($_) eq 'admin' } @user_roles) {
                $user_role = 'admin';
                $is_admin = 1;
            } else {
                # Otherwise use the first role
                $user_role = $user_roles[0] || 'normal';
            }
        } else {
            $user_role = 'normal';
        }
    }
    
    # Get the current site name
    my $site_name = $c->stash->{SiteName} || 'default';
    
    # Get all documentation pages
    my $pages = $self->documentation_pages;
    
    # Filter pages based on user role and site
    my %filtered_pages;
    foreach my $page_name (keys %$pages) {
        my $metadata = $pages->{$page_name};
        
        # Skip if this is site-specific documentation for a different site
        # But allow admins to see all site-specific documentation
        if ($metadata->{site} ne 'all' && $metadata->{site} ne $site_name) {
            # Only skip for non-admins
            next unless $is_admin;
        }
        
        # Skip if the user doesn't have the required role
        # But always include for admins
        my $has_role = $is_admin; # Admins can see everything
        
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
                    last;
                }
            }
        }
        
        next unless $has_role;
        
        # Add to filtered pages
        $filtered_pages{$page_name} = $metadata;
    }
    
    # Create a structured list of documentation pages with metadata
    my $structured_pages = {};
    foreach my $page_name (keys %filtered_pages) {
        my $metadata = $filtered_pages{$page_name};
        my $path = $metadata->{path};
        my $title = $self->_format_title($page_name);
        
        # Generate URL that matches the routing pattern: /Documentation/view/page_name
        # The view action is configured as :Path('/Documentation/view') :Args(1)
        # So we need to create URLs in the format /Documentation/view/page_name
        my $url = $c->uri_for('/Documentation/view', $page_name);
        
        $structured_pages->{$page_name} = {
            title => $title,
            path => $path,
            url => $url,
            site => $metadata->{site},
            roles => $metadata->{roles},
            file_type => $metadata->{file_type},
            description => $metadata->{description},
            date => $metadata->{date} || '',
            author => $metadata->{author} || '',
        };
    }
    
    # Get categories filtered by user role
    my %filtered_categories;
    foreach my $category_key (keys %{$self->documentation_categories}) {
        my $category = $self->documentation_categories->{$category_key};
        
        # Skip if the user doesn't have the required role
        # But always include for admins
        my $has_role = $is_admin; # Admins can see everything
        
        unless ($has_role) {
            foreach my $role (@{$category->{roles}}) {
                # Check if role matches user_role or is in session roles
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
                    last;
                }
            }
        }
        
        next unless $has_role;
        
        # Add to filtered categories
        $filtered_categories{$category_key} = $category;
    }
    
    # Set the template and stash variables
    $c->stash(
        template => 'Documentation/all_changelog.tt',
        structured_pages => $structured_pages,
        categories => \%filtered_categories,
        user_role => $user_role,
        is_admin => $is_admin,
        site_name => $site_name,
        title => 'All Documentation Changelog',
    );
    
    $c->forward($c->view('TT'));
}

# AI Guidelines
sub ai_guidelines :Path('ai_guidelines') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'ai_guidelines',
        "Accessing AI Guidelines documentation");
    
    # Check if the markdown file exists
    my $md_file = $c->path_to('root', 'Documentation', 'AI_Guidelines.md');
    
    if (-e $md_file) {
        # Read the markdown file
        open my $fh, '<:encoding(UTF-8)', $md_file or die "Cannot open $md_file: $!";
        my $content = do { local $/; <$fh> };
        close $fh;
        
        # Pass the content to the template
        $c->stash(
            markdown_content => $content,
            template => 'Documentation/markdown_viewer.tt',
            title => 'AI Assistant Guidelines'
        );
    } else {
        # If the file doesn't exist, show an error
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'ai_guidelines',
            "Documentation file 'AI_Guidelines.md' not found");
        $c->stash(
            error_msg => "Documentation file 'AI_Guidelines.md' not found",
            template => 'Documentation/error.tt'
        );
    }
    
    $c->forward($c->view('TT'));
}

# Linux Commands Reference - redirects to HelpDesk controller
sub linux_commands :Path('linux_commands') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'linux_commands',
        "Redirecting to HelpDesk linux_commands documentation");
    
    # Redirect to the HelpDesk controller's linux_commands route
    $c->response->redirect($c->uri_for('/HelpDesk/kb/linux_commands'));
    $c->detach();
}

# Controller routing guidelines
sub controller_routing_guidelines :Path('controller_routing_guidelines') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'controller_routing_guidelines',
        "Accessing controller routing guidelines");
    
    # Check if the markdown file exists
    my $md_file = $c->path_to('root', 'Documentation', 'controller_routing_guidelines.md');
    
    if (-e $md_file) {
        # Read the markdown file
        open my $fh, '<:encoding(UTF-8)', $md_file or die "Cannot open $md_file: $!";
        my $content = do { local $/; <$fh> };
        close $fh;
        
        # Pass the content to the template
        $c->stash(
            markdown_content => $content,
            template => 'Documentation/markdown_viewer.tt',
            title => 'Controller Routing Guidelines'
        );
    } else {
        # If the file doesn't exist, show an error
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'controller_routing_guidelines',
            "Documentation file 'controller_routing_guidelines.md' not found");
        $c->stash(
            error_msg => "Documentation file 'controller_routing_guidelines.md' not found",
            template => 'Documentation/error.tt'
        );
    }
    
    $c->forward($c->view('TT'));
}

# Controllers documentation
sub controllers_documentation :Path('controllers') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'controllers_documentation',
        "Accessing controllers documentation index");
    
    # Check if the markdown file exists
    my $md_file = $c->path_to('root', 'Documentation', 'controllers', 'index.md');
    
    if (-e $md_file) {
        # Read the markdown file
        open my $fh, '<:encoding(UTF-8)', $md_file or die "Cannot open $md_file: $!";
        my $content = do { local $/; <$fh> };
        close $fh;
        
        # Pass the content to the template
        $c->stash(
            markdown_content => $content,
            template => 'Documentation/markdown_viewer.tt',
            title => 'Controllers Documentation'
        );
    } else {
        # If the file doesn't exist, show an error
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'controllers_documentation',
            "Documentation file 'controllers/index.md' not found");
        $c->stash(
            error_msg => "Documentation file 'controllers/index.md' not found",
            template => 'Documentation/error.tt'
        );
    }
    
    $c->forward($c->view('TT'));
}

# Special handler for /faq route to ensure FAQ is directly accessible
sub faq_handler :Path('/faq') :Args(0) {
    my ($self, $c) = @_;
    
    # Log access to FAQ
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'faq_handler',
        "Direct access to FAQ from /faq route by user: " . ($c->session->{username} || 'guest'));
    
    # Forward to the view action with 'faq' as the page parameter
    $c->forward('view', ['faq']);
}

# Helper method to read file content for search
sub _read_file_content {
    my ($self, $c, $file_path) = @_;
    
    # Convert relative path to absolute path
    # The file_path stored in metadata is relative to root/ (e.g., 'Documentation/file.tt')
    # We need to construct the full path correctly
    my $full_path = $c->path_to('root', $file_path)->stringify;
    
    # Debug logging
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_read_file_content',
        "Attempting to read file: $file_path -> $full_path");
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_read_file_content',
        "File exists: " . (-f $full_path ? 'YES' : 'NO') . ", Readable: " . (-r $full_path ? 'YES' : 'NO'));
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_read_file_content',
        "Full path type: " . ref($full_path) . ", String value: '$full_path'");
    
    # Check if file exists and is readable
    unless (-f $full_path && -r $full_path) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_read_file_content',
            "File not found or not readable: $full_path (exists: " . (-e $full_path ? 'YES' : 'NO') . 
            ", is_file: " . (-f $full_path ? 'YES' : 'NO') . 
            ", readable: " . (-r $full_path ? 'YES' : 'NO') . ")");
        return;
    }
    
    # Read file content
    my $content;
    eval {
        open my $fh, '<:encoding(UTF-8)', $full_path or die "Cannot open $full_path: $!";
        $content = do { local $/; <$fh> };
        close $fh;
        
        # Clean up content for searching (remove Template Toolkit directives and HTML tags)
        $content = $self->_clean_content_for_search($content);
        
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_read_file_content',
            "Successfully read file $file_path, content length: " . length($content || ''));
    };
    
    if ($@) {
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_read_file_content',
            "Error reading file $file_path: $@");
        return;
    }
    
    return $content;
}

# Helper method to clean content for searching
sub _clean_content_for_search {
    my ($self, $content) = @_;
    
    return unless $content;
    
    # Remove Template Toolkit directives
    $content =~ s/\[%.*?%\]//gs;
    
    # Remove HTML tags but keep the content
    $content =~ s/<[^>]+>/ /g;
    
    # Remove multiple whitespace and normalize
    $content =~ s/\s+/ /g;
    $content =~ s/^\s+|\s+$//g;
    
    return $content;
}

# Helper method to extract context around search matches
sub _extract_match_context {
    my ($self, $content, $query, $context_length) = @_;
    
    return unless $content && $query;
    
    $context_length ||= 150;
    
    # Find the position of the first match
    my $pos = CORE::index(lc($content), lc($query));
    return unless $pos >= 0;
    
    # Calculate start and end positions for context
    my $start = $pos - int($context_length / 2);
    $start = 0 if $start < 0;
    
    my $end = $start + $context_length;
    $end = length($content) if $end > length($content);
    
    # Extract context
    my $context = substr($content, $start, $end - $start);
    
    # Add ellipsis if we're not at the beginning/end
    $context = "..." . $context if $start > 0;
    $context = $context . "..." if $end < length($content);
    
    # Clean up any remaining whitespace issues
    $context =~ s/\s+/ /g;
    $context =~ s/^\s+|\s+$//g;
    
    return $context;
}

__PACKAGE__->meta->make_immutable;

1;