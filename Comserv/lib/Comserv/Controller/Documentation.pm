package Comserv::Controller::Documentation;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;
use File::Find;
use File::Basename;

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
has 'documentation_categories' => (
    is => 'ro',
    default => sub {
        {
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
        }
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

    # Scan the Documentation directory for all files
    my $doc_dir = "root/Documentation";
    if (-d $doc_dir) {
        find(
            {
                wanted => sub {
                    my $file = $_;
                    # Skip directories
                    return if -d $file;

                    my $basename = basename($file);
                    my $path = $File::Find::name;
                    $path =~ s/^root\///; # Remove 'root/' prefix

                    # Create a safe key for the documentation_pages hash
                    my $key;

                    # Handle .tt files
                    if ($file =~ /\.tt$/) {
                        $key = basename($file, '.tt');
                    } else {
                        # Handle other file types (json, md, etc.)
                        my ($name, $ext) = split(/\./, $basename, 2);
                        if ($ext) {
                            $key = "${name}";
                        } else {
                            $key = $basename;
                        }
                    }

                    # Determine site and role requirements
                    my $site = 'all';
                    my @roles = ('normal', 'editor', 'admin', 'developer');

                    # Check if this is site-specific documentation
                    if ($path =~ m{Documentation/sites/([^/]+)/}) {
                        $site = $1;
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
                    $self->documentation_pages->{$key} = {
                        path => $path,
                        site => $site,
                        roles => \@roles,
                    };

                    # Add to appropriate category if it matches
                    foreach my $category_key (keys %{$self->documentation_categories}) {
                        my $category = $self->documentation_categories->{$category_key};

                        # Add to site-specific category if applicable
                        if ($category_key eq 'site_specific' && $site ne 'all') {
                            push @{$category->{pages}}, $key unless grep { $_ eq $key } @{$category->{pages}};
                        }

                        # Add to module category if it's in a module directory
                        if ($category_key eq 'modules' && $path =~ m{Documentation/modules/}) {
                            push @{$category->{pages}}, $key unless grep { $_ eq $key } @{$category->{pages}};
                        }

                        # Add to tutorials if it's in the tutorials directory
                        if ($category_key eq 'tutorials' && $path =~ m{Documentation/tutorials/}) {
                            push @{$category->{pages}}, $key unless grep { $_ eq $key } @{$category->{pages}};
                        }
                    }
                },
                no_chdir => 1,
            },
            $doc_dir
        );
    }

    # Also scan for role-specific documentation
    my $roles_dir = "root/Documentation/roles";
    if (-d $roles_dir) {
        find(
            {
                wanted => sub {
                    my $file = $_;
                    # Skip directories
                    return if -d $file;

                    my $basename = basename($file);
                    my $path = $File::Find::name;
                    $path =~ s/^root\///; # Remove 'root/' prefix

                    # Create a safe key for the documentation_pages hash
                    my $key;

                    # Handle .tt files
                    if ($file =~ /\.tt$/) {
                        $key = basename($file, '.tt');
                    } elsif ($file =~ /\.md$/) {
                        $key = basename($file, '.md');
                    } else {
                        # Handle other file types
                        my ($name, $ext) = split(/\./, $basename, 2);
                        if ($ext) {
                            $key = "${name}";
                        } else {
                            $key = $basename;
                        }
                    }

                    # Determine role requirements
                    my @roles = ('normal', 'editor', 'admin', 'developer');

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
                    $self->documentation_pages->{$key} = {
                        path => $path,
                        site => 'all',
                        roles => \@roles,
                    };

                    # Add to appropriate category
                    if ($path =~ m{roles/admin/}) {
                        push @{$self->documentation_categories->{admin_guides}->{pages}}, $key
                            unless grep { $_ eq $key } @{$self->documentation_categories->{admin_guides}->{pages}};
                    } elsif ($path =~ m{roles/developer/}) {
                        push @{$self->documentation_categories->{developer_guides}->{pages}}, $key
                            unless grep { $_ eq $key } @{$self->documentation_categories->{developer_guides}->{pages}};
                    } else {
                        push @{$self->documentation_categories->{user_guides}->{pages}}, $key
                            unless grep { $_ eq $key } @{$self->documentation_categories->{user_guides}->{pages}};
                    }
                },
                no_chdir => 1,
            },
            $roles_dir
        );
    }

    # Also scan for site-specific documentation
    my $sites_dir = "root/Documentation/sites";
    if (-d $sites_dir) {
        find(
            {
                wanted => sub {
                    my $file = $_;
                    # Skip directories
                    return if -d $file;

                    my $basename = basename($file);
                    my $path = $File::Find::name;
                    $path =~ s/^root\///; # Remove 'root/' prefix

                    # Create a safe key for the documentation_pages hash
                    my $key;

                    # Handle .tt files
                    if ($file =~ /\.tt$/) {
                        $key = basename($file, '.tt');
                    } elsif ($file =~ /\.md$/) {
                        $key = basename($file, '.md');
                    } else {
                        # Handle other file types
                        my ($name, $ext) = split(/\./, $basename, 2);
                        if ($ext) {
                            $key = "${name}";
                        } else {
                            $key = $basename;
                        }
                    }

                    # Determine site
                    my $site = 'all';
                    if ($path =~ m{Documentation/sites/([^/]+)/}) {
                        $site = $1;
                    }

                    # Store the path with metadata
                    $self->documentation_pages->{$key} = {
                        path => $path,
                        site => $site,
                        roles => ['normal', 'editor', 'admin', 'developer'],
                    };

                    # Add to site-specific category
                    push @{$self->documentation_categories->{site_specific}->{pages}}, $key
                        unless grep { $_ eq $key } @{$self->documentation_categories->{site_specific}->{pages}};
                },
                no_chdir => 1,
            },
            $sites_dir
        );
    }

    # Log the discovered documentation pages without context object
    $file = __FILE__;
    $line = __LINE__;
    my $message = "Found " . scalar(keys %{$self->documentation_pages}) . " documentation pages";

    # Use log_to_file directly since we don't have a context object in BUILD
    Comserv::Util::Logging::log_to_file("[$file:$line] BUILD - $message", undef, 'INFO');
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
    my %filtered_pages;
    foreach my $page_name (keys %$pages) {
        my $metadata = $pages->{$page_name};

        # Skip if this is site-specific documentation for a different site
        next if $metadata->{site} ne 'all' && $metadata->{site} ne $site_name;

        # Skip if the user doesn't have the required role
        my $has_role = 0;
        foreach my $role (@{$metadata->{roles}}) {
            if ($role eq $user_role || ($role eq 'normal' && $user_role)) {
                $has_role = 1;
                last;
            }
        }
        next unless $has_role;

        # Add to filtered pages
        $filtered_pages{$page_name} = $metadata;
    }

    # Sort pages alphabetically for better presentation
    my @sorted_pages = sort keys %filtered_pages;

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
        my $has_role = 0;
        foreach my $role (@{$category->{roles}}) {
            if ($role eq $user_role || ($role eq 'normal' && $user_role)) {
                $has_role = 1;
                last;
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

    # Convert underscores to spaces and capitalize each word
    my $title = $page_name;
    $title =~ s/_/ /g;
    $title = join(' ', map { ucfirst $_ } split(/\s+/, $title));

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

    # Get the current site name
    my $site_name = $c->stash->{SiteName} || 'default';

    # Sanitize the page name to prevent directory traversal
    $page =~ s/[^a-zA-Z0-9_\.]//g;

    # Check if the user has permission to view this page
    my $pages = $self->documentation_pages;
    if (exists $pages->{$page}) {
        my $metadata = $pages->{$page};

        # Check site-specific access
        if ($metadata->{site} ne 'all' && $metadata->{site} ne $site_name) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'view',
                "Access denied to site-specific documentation: $page (user site: $site_name, doc site: $metadata->{site})");

            $c->stash(
                error_msg => "You don't have permission to view this documentation page. It's specific to the '$metadata->{site}' site.",
                template => 'Documentation/error.tt'
            );
            return $c->forward($c->view('TT'));
        }

        # Check role-based access
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

__PACKAGE__->meta->make_immutable;

1;