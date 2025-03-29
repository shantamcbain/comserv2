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

# Store documentation pages
has 'documentation_pages' => (
    is => 'ro',
    default => sub { {} },
    lazy => 1,
);

# Initialize - scan for documentation files
# Initialize - scan for documentation files
sub BUILD {
    my ($self) = @_;

    # Create a logging instance
    my $logging = $self->logging;

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
                            $key = "${name}_${ext}";
                        } else {
                            $key = $basename;
                        }
                    }

                    # Store the path with the key
                    $self->documentation_pages->{$key} = $path;
                },
                no_chdir => 1,
            },
            $doc_dir
        );
    }

    # Log the number of pages found using the logging attribute
    my $message = "Found " . scalar(keys %{$self->documentation_pages}) . " documentation pages";
    $logging->log_with_details(
        undef,  # No context object in BUILD
        'info',
        __FILE__,
        __LINE__,
        'BUILD',
        $message
    );
}

# Main documentation index
sub index :Path :Args(0) {
    my ($self, $c) = @_;

    # Log the action
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Accessing documentation index");

    # Get list of available documentation pages
    my $pages = $self->documentation_pages;

    # Sort pages alphabetically for better presentation
    my @sorted_pages = sort keys %$pages;

    # Create a structured list of documentation pages with metadata
    my $structured_pages = {};
    foreach my $page_name (@sorted_pages) {
        my $path = $pages->{$page_name};
        my $title = $self->_format_title($page_name);

        # Always use the view action with the page name as parameter
        my $url = $c->uri_for($self->action_for('view'), [$page_name]);

        $structured_pages->{$page_name} = {
            title => $title,
            path => $path,
            url => $url,
        };
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
        documentation_pages => $pages,
        structured_pages => $structured_pages,
        sorted_page_names => \@sorted_pages,
        completed_items => $completed_items,
        template => 'Documentation/index.tt'
    );

    $c->forward($c->view('TT'));
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

    # Sanitize the page name to prevent directory traversal
    $page =~ s/[^a-zA-Z0-9_\.]//g;

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

    # If not a direct file or file not found, try as a template
    my $template_path = "Documentation/$page.tt";
    my $full_path = $c->path_to('root', $template_path);

    if (-e $full_path) {
        # Set the template
        $c->stash(template => $template_path);
    } else {
        # Log the error
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'view', "Documentation page not found: $page");

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