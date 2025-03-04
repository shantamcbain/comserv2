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
sub BUILD {
    my ($self) = @_;

    # List of reserved names that should not be used as page names
    my %reserved_names = map { $_ => 1 } qw(
        Calendar sessionplan Schema Model Controller View
        UNIVERSAL CORE GLOB STDIN STDOUT STDERR ARGV ENV INC SIG
    );

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

                    # Handle .tt files
                    if ($file =~ /\.tt$/) {
                        my $basename_no_ext = basename($file, '.tt');

                        # Skip reserved names and ensure valid Perl identifier
                        if (!$reserved_names{$basename_no_ext} &&
                            $basename_no_ext =~ /^[a-zA-Z_][a-zA-Z0-9_]*$/) {
                            $self->documentation_pages->{$basename_no_ext} = $path;
                        } else {
                            # Use a safe prefix for problematic names
                            my $safe_name = "doc_" . $basename_no_ext;
                            $safe_name =~ s/[^a-zA-Z0-9_]/_/g; # Replace invalid chars
                            $self->documentation_pages->{$safe_name} = $path;
                        }
                    } else {
                        # Handle other file types (json, etc.)
                        my ($name, $ext) = split(/\./, $basename, 2);
                        if ($ext) {
                            my $page_name = "${name}_${ext}";

                            # Skip reserved names and ensure valid Perl identifier
                            if (!$reserved_names{$page_name} &&
                                $page_name =~ /^[a-zA-Z_][a-zA-Z0-9_]*$/) {
                                $self->documentation_pages->{$page_name} = $path;
                            } else {
                                # Use a safe prefix for problematic names
                                my $safe_name = "doc_" . $page_name;
                                $safe_name =~ s/[^a-zA-Z0-9_]/_/g; # Replace invalid chars
                                $self->documentation_pages->{$safe_name} = $path;
                            }
                        } else {
                            # Skip reserved names and ensure valid Perl identifier
                            if (!$reserved_names{$basename} &&
                                $basename =~ /^[a-zA-Z_][a-zA-Z0-9_]*$/) {
                                $self->documentation_pages->{$basename} = $path;
                            } else {
                                # Use a safe prefix for problematic names
                                my $safe_name = "doc_" . $basename;
                                $safe_name =~ s/[^a-zA-Z0-9_]/_/g; # Replace invalid chars
                                $self->documentation_pages->{$safe_name} = $path;
                            }
                        }
                    }
                },
                no_chdir => 1,
            },
            $doc_dir
        );
    }

    # Log the discovered documentation pages without context object
    my $file = __FILE__;
    my $line = __LINE__;
    my $message = "Found " . scalar(keys %{$self->documentation_pages}) . " documentation pages";

    # Use log_to_file directly since we don't have a context object in BUILD
    Comserv::Util::Logging::log_to_file("[$file:$line] BUILD - $message", undef, 'INFO');
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
        my $url = $c->uri_for($self->action_for($page_name) || $self->action_for('view'), [$page_name]);

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

# Auto-generated routes for all documentation files
sub auto :Private {
    my ($self, $c) = @_;

    # Get the current action
    my $action = $c->action->name;

    # If this is a documentation page request
    if ($action ne 'index' && $action ne 'view' && exists $self->documentation_pages->{$action}) {
        # Log the action
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, $action, "Accessing documentation page via auto-route: $action");

        # Set the template
        $c->stash(
            template => $self->documentation_pages->{$action}
        );
        $c->forward($c->view('TT'));
        return 0; # Skip further processing
    }

    return 1; # Continue processing
}

# Generate dynamic routes for all documentation files
sub register_actions {
    my ($self, $app) = @_;

    # Call the parent method first
    $self->next::method($app);

    # List of reserved names that should not be used as page names
    my %reserved_names = map { $_ => 1 } qw(
        Calendar sessionplan Schema Model Controller View
        UNIVERSAL CORE GLOB STDIN STDOUT STDERR ARGV ENV INC SIG
    );

    # Get all documentation pages
    my $pages = $self->documentation_pages;

    # For each documentation page, create a route
    foreach my $page_name (keys %$pages) {
        # Skip if we already have an explicit route for this page
        next if $self->can($page_name);

        # Skip if the page name is not a valid Perl identifier or is a reserved name
        next unless $page_name =~ /^[a-zA-Z_][a-zA-Z0-9_]*$/;
        next if $reserved_names{$page_name};

        # Skip if the page name is a package that already exists
        eval "package $page_name; 1;";
        next if $@;

        # Create a method for this page
        my $method_body = sub {
            my ($self, $c) = @_;

            # Log the action
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, $page_name,
                "Accessing documentation page: $page_name");

            # Set the template
            $c->stash(
                template => $pages->{$page_name}
            );
            $c->forward($c->view('TT'));
        };

        # Add the method to the class
        my $fully_qualified_name = __PACKAGE__ . "::$page_name";
        no strict 'refs';
        *{$fully_qualified_name} = $method_body;

        # Add the attributes
        eval {
            $app->dispatcher->register($self, $page_name,
                attributes => { Path => [$page_name], Args => [0] });
        };
        if ($@) {
            # Log the error but continue with other pages
            Comserv::Util::Logging::log_to_file(
                "Failed to register route for page '$page_name': $@",
                undef, 'ERROR'
            );
        }
    }
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