package Comserv::Controller::Documentation::AutoDiscovery;

use Moose;
use namespace::autoclean;
use JSON;
use File::Find;
use File::Basename;
use File::Spec;
use FindBin;
use Try::Tiny;
use Comserv::Util::Logging;
use Comserv::Util::DocumentationConfig;

BEGIN { extends 'Catalyst::Controller'; }

__PACKAGE__->config(namespace => 'Documentation/AutoDiscovery');

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

# Store discovered files that are not in config
has 'unconfigured_files' => (
    is => 'rw',
    default => sub { [] },
    lazy => 1,
);

# Auto-discovery index - shows admin interface for managing unconfigured files
sub index :Path :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto_discovery_access',
        "User attempting to access auto-discovery interface");
    
    # Check admin permissions
    unless ($c->check_user_roles('admin') || $c->check_user_roles('developer')) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'access_denied',
            "Access denied to auto-discovery interface - insufficient permissions");
        $c->response->redirect($c->uri_for('/'));
        $c->detach;
    }
    
    my $user_id = $c->user ? $c->user->id : 'unknown';
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto_discovery_index',
        "Admin user ($user_id) accessing auto-discovery interface");
    
    # Get configured files count first for logging
    my $config = Comserv::Util::DocumentationConfig->instance;
    my $configured_count = scalar(@{$config->get_pages()});
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'config_status',
        "Current configuration has $configured_count configured documentation files");
    
    # Scan for unconfigured files
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'starting_scan',
        "Starting scan for unconfigured files from admin interface");
    
    my $unconfigured = $self->scan_for_unconfigured_files($c);
    my $unconfigured_count = scalar(@$unconfigured);
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'scan_results',
        "Scan completed: $unconfigured_count unconfigured files found, $configured_count already configured");
    
    # Get available categories for the form
    my $categories = $self->get_available_categories();
    my $category_count = scalar(keys %$categories);
    
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'categories_loaded',
        "Loaded $category_count available categories for form");
    
    $c->stash(
        template => 'Documentation/AutoDiscovery/index.tt',
        unconfigured_files => $unconfigured,
        categories => $categories,
        configured_count => $configured_count,
        page_title => 'Documentation Auto-Discovery'
    );
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'template_prepared',
        "Template prepared with $unconfigured_count unconfigured files and $category_count categories");
}

# Scan documentation directories for files not in configuration
sub scan_for_unconfigured_files {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'scan_unconfigured_start',
        "Starting scan for unconfigured documentation files");
    
    my $config = Comserv::Util::DocumentationConfig->instance;
    my $configured_paths = {};
    my $configured_count = 0;
    
    # Build hash of configured file paths for quick lookup
    foreach my $page (@{$config->get_pages()}) {
        $configured_paths->{$page->{path}} = 1;
        $configured_count++;
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'configured_path',
            "Configured path: $page->{path}");
    }
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'configured_paths_loaded',
        "Loaded $configured_count configured paths from documentation config");
    
    my @unconfigured = ();
    my $doc_root = File::Spec->catdir($FindBin::Bin, "..", "root", "Documentation");
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'scan_directory',
        "Scanning documentation root directory: $doc_root");
    
    # Check if directory exists and is readable
    unless (-d $doc_root) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'directory_not_found',
            "Documentation root directory does not exist: $doc_root");
        return \@unconfigured;
    }
    
    unless (-r $doc_root) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'directory_not_readable',
            "Documentation root directory is not readable: $doc_root");
        return \@unconfigured;
    }
    
    my $files_scanned = 0;
    my $files_skipped_directory = 0;
    my $files_skipped_extension = 0;
    my $files_skipped_configured = 0;
    my $files_skipped_system = 0;
    my $files_added = 0;
    
    # Scan for .tt files in Documentation directory
    find({
        wanted => sub {
            my $current_file = $File::Find::name;
            $files_scanned++;
            
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'file_found',
                "Processing file: $current_file");
            
            # Skip directories
            if (-d $_) {
                $files_skipped_directory++;
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'skip_directory',
                    "Skipping directory: $current_file");
                return;
            }
            
            # Check file extension
            unless (/\.(tt|md|html|txt)$/i) {
                $files_skipped_extension++;
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'skip_extension',
                    "Skipping file with unsupported extension: $current_file");
                return;
            }
            
            my $full_path = $File::Find::name;
            my $rel_path = $full_path;
            
            # Convert to relative path from root
            if ($rel_path =~ m{/root/(.+)$}) {
                $rel_path = $1;
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'path_conversion',
                    "Converted path from '$full_path' to '$rel_path'");
            } else {
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'path_conversion_failed',
                    "Failed to convert path to relative: $full_path");
            }
            
            # Skip if already configured
            if ($configured_paths->{$rel_path}) {
                $files_skipped_configured++;
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'skip_configured',
                    "Skipping already configured file: $rel_path");
                return;
            }
            
            # Skip system files
            if ($rel_path =~ m{/config/}) {
                $files_skipped_system++;
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'skip_config',
                    "Skipping config directory file: $rel_path");
                return;
            }
            if ($rel_path =~ m{/scripts/}) {
                $files_skipped_system++;
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'skip_scripts',
                    "Skipping scripts directory file: $rel_path");
                return;
            }
            
            my $filename = basename($full_path);
            my $suggested_category = $self->suggest_category($rel_path, $filename);
            my $suggested_roles = $self->suggest_roles($rel_path);
            
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'unconfigured_file_found',
                "Found unconfigured file: $rel_path (category: $suggested_category, roles: " . join(',', @$suggested_roles) . ")");
            
            push @unconfigured, {
                path => $rel_path,
                filename => $filename,
                full_path => $full_path,
                suggested_category => $suggested_category,
                suggested_roles => $suggested_roles,
                title => $self->generate_title($filename),
                description => $self->generate_description($filename, $rel_path)
            };
            
            $files_added++;
        },
        no_chdir => 1
    }, $doc_root);
    
    # Log comprehensive scan results
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'scan_complete',
        "Scan complete - Files scanned: $files_scanned, " .
        "Directories skipped: $files_skipped_directory, " .
        "Wrong extension: $files_skipped_extension, " .
        "Already configured: $files_skipped_configured, " .
        "System files: $files_skipped_system, " .
        "Unconfigured found: $files_added");
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'scan_unconfigured',
        "Found " . scalar(@unconfigured) . " unconfigured documentation files");
    
    # Log each unconfigured file for detailed debugging
    foreach my $file (@unconfigured) {
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'unconfigured_detail',
            "Unconfigured: $file->{path} -> Title: '$file->{title}', Category: $file->{suggested_category}");
    }
    
    return \@unconfigured;
}

# Suggest category based on file path and name
sub suggest_category {
    my ($self, $path, $filename) = @_;
    
    # Path-based suggestions
    return 'tutorials' if $path =~ m{/tutorials/};
    return 'modules' if $path =~ m{/modules/};
    return 'proxmox' if $path =~ m{/proxmox/};
    return 'developer_guides' if $path =~ m{/developer/};
    return 'changelog' if $path =~ m{/changelog/};
    return 'admin_guides' if $path =~ m{/roles/admin/};
    return 'user_guides' if $path =~ m{/roles/normal/};
    return 'developer_guides' if $path =~ m{/roles/developer/};
    
    # Filename-based suggestions
    return 'admin_guides' if $filename =~ /^(installation|configuration|system|admin)/i;
    return 'user_guides' if $filename =~ /^(getting_started|account_management|user_guide|faq)/i;
    return 'modules' if $filename =~ /^(todo|project|task)/i;
    return 'proxmox' if $filename =~ /^(proxmox)/i;
    
    return 'user_guides'; # Default
}

# Suggest roles based on file path
sub suggest_roles {
    my ($self, $path) = @_;
    
    # Admin-only paths
    if ($path =~ m{/roles/admin/} || 
        $path =~ m{/proxmox/} ||
        $path =~ m{/controllers/} ||
        $path =~ m{/models/}) {
        return ['admin', 'developer'];
    }
    
    # Developer-only paths
    if ($path =~ m{/roles/developer/}) {
        return ['developer'];
    }
    
    # Default - accessible to all
    return ['normal', 'editor', 'admin', 'developer'];
}

# Generate title from filename
sub generate_title {
    my ($self, $filename) = @_;
    
    my ($name) = fileparse($filename, qr/\.[^.]*/);
    
    # Convert underscores and hyphens to spaces
    $name =~ s/[_-]/ /g;
    
    # Capitalize first letter of each word
    $name =~ s/\b(\w)/uc($1)/ge;
    
    return $name;
}

# Generate description from filename and path
sub generate_description {
    my ($self, $filename, $path) = @_;
    
    my $title = $self->generate_title($filename);
    
    if ($path =~ m{/tutorials/}) {
        return "Tutorial: $title";
    } elsif ($path =~ m{/modules/}) {
        return "Module documentation: $title";
    } elsif ($path =~ m{/proxmox/}) {
        return "Proxmox documentation: $title";
    } elsif ($path =~ m{/roles/admin/}) {
        return "Administrator guide: $title";
    } elsif ($path =~ m{/roles/developer/}) {
        return "Developer documentation: $title";
    }
    
    return "Documentation for $title";
}

# Get available categories for the form
sub get_available_categories {
    my ($self) = @_;
    
    my $config = Comserv::Util::DocumentationConfig->instance;
    return $config->get_categories();
}

# Process single file addition to configuration
sub add_single :Path('add_single') :Args(0) {
    my ($self, $c) = @_;
    
    # Check admin permissions
    unless ($c->check_user_roles('admin') || $c->check_user_roles('developer')) {
        $c->response->status(403);
        $c->response->body('Access denied');
        $c->detach;
    }
    
    my $params = $c->request->params;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_single_start',
        "Processing single file addition for path: " . ($params->{path} || 'unknown'));
    
    # Validate required parameters
    unless ($params->{path} && $params->{title} && $params->{category}) {
        $c->response->status(400);
        $c->response->body('Missing required parameters');
        $c->detach;
    }
    
    my $file_data = {
        id => $self->generate_id($params->{path}),
        title => $params->{title},
        description => $params->{description} || $self->generate_description(basename($params->{path}), $params->{path}),
        path => $params->{path},
        categories => [$params->{category}],
        roles => $self->parse_roles($params->{roles}),
        site => 'all',
        format => ($params->{path} =~ /\.tt$/i) ? 'template' : 'markdown'
    };
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_single_data',
        "File data prepared: ID=$file_data->{id}, Title=$file_data->{title}, Category=$params->{category}");
    
    # Add to configuration
    my $config = Comserv::Util::DocumentationConfig->instance;
    
    try {
        $config->add_page($file_data);
        $config->save_config();
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_single_success',
            "Successfully added file to configuration: $file_data->{path}");
        
        # Return JSON response for AJAX
        $c->response->content_type('application/json');
        $c->response->body(JSON::encode_json({
            success => 1,
            message => "File '$file_data->{title}' added successfully",
            file_id => $file_data->{id}
        }));
        
    } catch {
        my $error = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'add_single_error',
            "Error adding file to configuration: $error");
        
        $c->response->status(500);
        $c->response->content_type('application/json');
        $c->response->body(JSON::encode_json({
            success => 0,
            message => "Error adding file: $error"
        }));
    };
}

# Preview file content
sub preview_file :Path('preview_file') :Args(0) {
    my ($self, $c) = @_;
    
    # Check admin permissions
    unless ($c->check_user_roles('admin') || $c->check_user_roles('developer')) {
        $c->response->status(403);
        $c->response->body('Access denied');
        $c->detach;
    }
    
    my $file_path = $c->request->params->{path};
    
    unless ($file_path) {
        $c->response->status(400);
        $c->response->body('File path is required');
        $c->detach;
    }
    
    # Construct full path to file
    my $full_path = File::Spec->catfile($FindBin::Bin, '..', 'root', $file_path);
    
    # Security check - ensure file is within Documentation directory
    my $doc_dir = File::Spec->catfile($FindBin::Bin, '..', 'root', 'Documentation');
    unless ($full_path =~ /^\Q$doc_dir\E/) {
        $c->response->status(403);
        $c->response->body('Access denied - file outside Documentation directory');
        $c->detach;
    }
    
    # Check if file exists and is readable
    unless (-f $full_path && -r $full_path) {
        $c->response->status(404);
        $c->response->body('File not found or not readable');
        $c->detach;
    }
    
    try {
        # Read file content
        open my $fh, '<:encoding(UTF-8)', $full_path or die "Cannot open file: $!";
        my $content = do { local $/; <$fh> };
        close $fh;
        
        # Return content as plain text
        $c->response->content_type('text/plain; charset=utf-8');
        $c->response->body($content);
        
    } catch {
        my $error = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'preview_file_error',
            "Error reading file $file_path: $error");
        
        $c->response->status(500);
        $c->response->body("Error reading file: $error");
    };
}

# Process form submission to add files to configuration
sub add_to_config :Path('add_to_config') :Args(0) {
    my ($self, $c) = @_;
    
    # Check admin permissions
    unless ($c->check_user_roles('admin') || $c->check_user_roles('developer')) {
        $c->response->status(403);
        $c->response->body('Access denied');
        $c->detach;
    }
    
    my $params = $c->request->params;
    my @files_to_add = ();
    
    # Process each selected file
    foreach my $param_name (keys %$params) {
        next unless $param_name =~ /^file_(\d+)$/;
        my $index = $1;
        
        # Skip if not selected
        next unless $params->{"selected_$index"};
        
        my $file_data = {
            id => $self->generate_id($params->{"path_$index"}),
            title => $params->{"title_$index"} || $self->generate_title(basename($params->{"path_$index"})),
            description => $params->{"description_$index"} || $self->generate_description(basename($params->{"path_$index"}), $params->{"path_$index"}),
            path => $params->{"path_$index"},
            categories => [$params->{"category_$index"} || 'user_guides'],
            roles => $self->parse_roles($params->{"roles_$index"}),
            site => $params->{"site_$index"} || 'all',
            format => 'template'
        };
        
        push @files_to_add, $file_data;
    }
    
    if (@files_to_add) {
        my $result = $self->update_config_file($c, \@files_to_add);
        
        if ($result->{success}) {
            $c->flash->{message} = "Successfully added " . scalar(@files_to_add) . " files to documentation configuration.";
            $c->flash->{message_type} = 'success';
        } else {
            $c->flash->{message} = "Error updating configuration: " . $result->{error};
            $c->flash->{message_type} = 'error';
        }
    } else {
        $c->flash->{message} = "No files selected for addition.";
        $c->flash->{message_type} = 'warning';
    }
    
    $c->response->redirect($c->uri_for('/Documentation/AutoDiscovery'));
}

# Generate unique ID for a file
sub generate_id {
    my ($self, $path) = @_;
    
    my $filename = basename($path);
    my ($name) = fileparse($filename, qr/\.[^.]*/);
    
    # Convert to lowercase and replace non-alphanumeric with underscores
    $name = lc($name);
    $name =~ s/[^a-z0-9]/_/g;
    $name =~ s/_+/_/g;  # Collapse multiple underscores
    $name =~ s/^_|_$//g; # Remove leading/trailing underscores
    
    return $name;
}

# Parse roles from form input
sub parse_roles {
    my ($self, $roles_string) = @_;
    
    return ['normal', 'editor', 'admin', 'developer'] unless $roles_string;
    
    my @roles = split(/,/, $roles_string);
    @roles = map { s/^\s+|\s+$//g; $_ } @roles; # Trim whitespace
    
    return \@roles;
}

# Update the configuration JSON file
sub update_config_file {
    my ($self, $c, $files_to_add) = @_;
    
    my $config_file = File::Spec->catfile($FindBin::Bin, '..', 'root', 'Documentation', 'config', 'documentation_config.json');
    
    try {
        # Read current configuration
        open my $fh, '<:encoding(UTF-8)', $config_file or die "Cannot open $config_file: $!";
        my $json_content = do { local $/; <$fh> };
        close $fh;
        
        my $config = decode_json($json_content);
        
        # Add new files to pages array
        push @{$config->{pages}}, @$files_to_add;
        
        # Write updated configuration
        open $fh, '>:encoding(UTF-8)', $config_file or die "Cannot write to $config_file: $!";
        print $fh JSON->new->pretty->encode($config);
        close $fh;
        
        # Reload the configuration in the utility class
        Comserv::Util::DocumentationConfig->instance->reload_config();
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'config_updated',
            "Added " . scalar(@$files_to_add) . " files to documentation configuration");
        
        return { success => 1 };
        
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'config_update_failed',
            "Failed to update configuration: $_");
        
        return { success => 0, error => $_ };
    };
}

# API endpoint to get unconfigured files as JSON
sub api_unconfigured :Path('api/unconfigured') :Args(0) {
    my ($self, $c) = @_;
    
    # Check admin permissions
    unless ($c->check_user_roles('admin') || $c->check_user_roles('developer')) {
        $c->response->status(403);
        $c->stash->{json_data} = { error => 'Access denied' };
        $c->forward('View::JSON');
        return;
    }
    
    my $unconfigured = $self->scan_for_unconfigured_files($c);
    
    $c->stash->{json_data} = {
        success => 1,
        files => $unconfigured,
        count => scalar(@$unconfigured)
    };
    
    $c->forward('View::JSON');
}

# Background scan method that can be called periodically
sub background_scan {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'background_scan',
        "Starting background scan for unconfigured documentation files");
    
    my $unconfigured = $self->scan_for_unconfigured_files($c);
    
    if (@$unconfigured) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'background_scan_results',
            "Background scan found " . scalar(@$unconfigured) . " unconfigured files");
        
        # Could send notification to admins here
        # $self->notify_admins($c, $unconfigured);
    }
    
    return $unconfigured;
}

__PACKAGE__->meta->make_immutable;

1;