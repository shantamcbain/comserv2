package Comserv::Controller::Documentation::ScanMethods;
use strict;
use warnings;
use File::Find;
use File::Basename;
use Comserv::Util::Logging;
use Exporter 'import';
use FindBin;
use File::Spec;

our @EXPORT = qw(_scan_directories _categorize_pages);

# Get the application log file path
my $APP_LOG_FILE = $ENV{'COMSERV_LOG_DIR'} ? 
    File::Spec->catfile($ENV{'COMSERV_LOG_DIR'}, 'application.log') : 
    File::Spec->catfile($FindBin::Bin, '..', 'logs', 'application.log');

# Scan directories for documentation files
sub _scan_directories {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_scan_directories',
        "Starting directory scan for documentation files");
    
    # Scan the Documentation directory for all files
    # Use absolute path to ensure we find the directory regardless of working directory
    my $doc_dir = File::Spec->catdir($FindBin::Bin, '..', 'root', 'Documentation');
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_scan_directories',
        "Looking for documentation directory at: $doc_dir");
    if (-d $doc_dir) {
        find(
            {
                wanted => sub {
                    my $file = $_;
                    # Skip directories
                    return if -d $file;

                    my $basename = basename($file);
                    my $path = $File::Find::name;
                    # Convert absolute path to relative path starting with Documentation/
                    my $doc_base = File::Spec->catdir($FindBin::Bin, '..', 'root');
                    $path =~ s/^\Q$doc_base\E[\/\\]?//; # Remove base path prefix

                    # Skip configuration files
                    return if $path =~ m{Documentation/.*_config\.json$};
                    # Skip templates and other non-documentation files
                    return if $path =~ m{Documentation/config/};
                    return if $path =~ m{Documentation/config_based/};

                    # Create a safe key for the documentation_pages hash
                    my $key;

                    # Extract the path relative to Documentation directory
                    my $rel_path = $path;
                    $rel_path =~ s/^Documentation\///;  # Remove Documentation/ prefix

                    # Handle .tt files
                    if ($file =~ /\.tt$/) {
                        $key = $rel_path;
                        $key =~ s/\.tt$//;  # Remove .tt extension
                    } elsif ($file =~ /\.md$/) {
                        $key = $rel_path;
                        $key =~ s/\.md$//;  # Remove .md extension
                    } else {
                        # Handle other file types (json, etc.)
                        $key = $rel_path;
                        $key =~ s/\.[^.]+$//;  # Remove any extension
                    }

                    # Log the file being processed (only for debug level)
                    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_scan_directories',
                        "Processing file: $file, key: $key, path: $path, full_path: $File::Find::name");

                    # Determine site and role requirements
                    my $site = 'all';
                    my @roles = ('normal', 'editor', 'admin', 'developer');  # Default roles

                    # Check if this is site-specific documentation
                    if ($path =~ m{Documentation/sites/([^/]+)/}) {
                        $site = uc($1); # Convert site name to uppercase to match SiteName format
                    }

                    # Check if this page has specific roles configured in JSON
                    my $config_roles = _get_page_roles_from_config($key);
                    if ($config_roles && @$config_roles) {
                        @roles = @$config_roles;
                        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_scan_directories',
                            "Using JSON config roles for $key: " . join(', ', @roles));
                    } else {
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
                    }
                    
                    # Determine file format
                    my $format = 'unknown';
                    if ($path =~ /\.md$/i) {
                        $format = 'markdown';
                    } elsif ($path =~ /\.tt$/i) {
                        $format = 'template';
                    }

                    # Store the path with metadata
                    # Prioritize .tt files over .md files when both exist
                    my $existing_entry = $self->documentation_pages->{$key};
                    my $should_store = 1;
                    
                    if ($existing_entry) {
                        # If existing entry is a .tt file and current is .md, skip
                        if ($existing_entry->{format} eq 'template' && $format eq 'markdown') {
                            $should_store = 0;
                            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_scan_directories',
                                "Skipping .md file $path as .tt version already exists for key: $key");
                        }
                        # If existing entry is .md and current is .tt, replace
                        elsif ($existing_entry->{format} eq 'markdown' && $format eq 'template') {
                            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_scan_directories',
                                "Replacing .md file with .tt version for key: $key");
                        }
                    }
                    
                    if ($should_store) {
                        $self->documentation_pages->{$key} = {
                            path => $path,
                            site => $site,
                            roles => \@roles,
                            format => $format
                        };
                    }
                },
                no_chdir => 1,
            },
            $doc_dir
        );
    } else {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_scan_directories',
            "Documentation directory not found at: $doc_dir");
    }
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_scan_directories',
        "Directory scan completed. Found " . scalar(keys %{$self->documentation_pages}) . " pages.");
}

# Categorize pages based on their paths
sub _categorize_pages {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_categorize_pages',
        "Categorizing documentation pages");
    
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
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_categorize_pages',
                    "Added '$page_id' to site-specific category (site: $site)");
            }
            
            # Add to module category if it's in a module directory
            if ($category_key eq 'modules' && $path =~ m{Documentation/modules/}) {
                push @{$category->{pages}}, $page_id unless grep { $_ eq $page_id } @{$category->{pages}};
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_categorize_pages',
                    "Added '$page_id' to modules category");
            }
            
            # Add to tutorials if it's in the tutorials directory
            if ($category_key eq 'tutorials' && $path =~ m{Documentation/tutorials/}) {
                push @{$category->{pages}}, $page_id unless grep { $_ eq $page_id } @{$category->{pages}};
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_categorize_pages',
                    "Added '$page_id' to tutorials category");
            }
            
            # Add to user guides if it's in the normal roles directory
            if ($category_key eq 'user_guides' && $path =~ m{Documentation/roles/normal/}) {
                push @{$category->{pages}}, $page_id unless grep { $_ eq $page_id } @{$category->{pages}};
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_categorize_pages',
                    "Added '$page_id' to user_guides category");
            }
            
            # Add to admin guides if it's in the admin roles directory
            if ($category_key eq 'admin_guides' && $path =~ m{Documentation/roles/admin/}) {
                push @{$category->{pages}}, $page_id unless grep { $_ eq $page_id } @{$category->{pages}};
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_categorize_pages',
                    "Added '$page_id' to admin_guides category");
            }
            
            # Add to developer guides if it's in the developer roles directory
            if ($category_key eq 'developer_guides' && $path =~ m{Documentation/roles/developer/}) {
                push @{$category->{pages}}, $page_id unless grep { $_ eq $page_id } @{$category->{pages}};
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_categorize_pages',
                    "Added '$page_id' to developer_guides category");
            }
            
            # Add to admin guides if it's in various admin-related directories
            if ($category_key eq 'admin_guides' && (
                $path =~ m{Documentation/admin/} ||
                $path =~ m{Documentation/system/} ||
                $path =~ m{Documentation/proxmox/} ||
                $path =~ m{Documentation/cloudflare/} ||
                $path =~ m{Documentation/session_history/}
            )) {
                push @{$category->{pages}}, $page_id unless grep { $_ eq $page_id } @{$category->{pages}};
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_categorize_pages',
                    "Added '$page_id' to admin_guides category (directory-based)");
            }
            
            # Add to developer guides if it's in various developer-related directories
            if ($category_key eq 'developer_guides' && (
                $path =~ m{Documentation/developer/} ||
                $path =~ m{Documentation/controllers/} ||
                $path =~ m{Documentation/models/} ||
                $path =~ m{Documentation/features/} ||
                $path =~ m{Documentation/changelog/} ||
                $path =~ m{Documentation/scripts/} ||
                $path =~ m{Documentation/ai_workflows/}
            )) {
                push @{$category->{pages}}, $page_id unless grep { $_ eq $page_id } @{$category->{pages}};
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_categorize_pages',
                    "Added '$page_id' to developer_guides category (directory-based)");
            }
            
            # Add to user guides if it's in general directories
            if ($category_key eq 'user_guides' && (
                $path =~ m{Documentation/general/} ||
                ($path =~ m{^Documentation/[^/]+\.(md|tt)$} && $path !~ m{Documentation/(admin|developer|system|proxmox|cloudflare|session_history|controllers|models|features|changelog|scripts|ai_workflows|config|sites|roles|modules|tutorials)/})
            )) {
                push @{$category->{pages}}, $page_id unless grep { $_ eq $page_id } @{$category->{pages}};
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_categorize_pages',
                    "Added '$page_id' to user_guides category (general files)");
            }
        }
    }
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_categorize_pages',
        "Page categorization completed");
}

# Get page roles from JSON configuration
sub _get_page_roles_from_config {
    my ($self, $page_key) = @_;
    
    return unless $page_key;
    
    # Load the JSON configuration
    eval {
        require JSON;
        require File::Spec;
        require FindBin;
        
        my $config_file = File::Spec->catfile($FindBin::Bin, '..', 'config', 'documentation_config.json');
        return unless -f $config_file;
        
        open(my $fh, '<', $config_file) or return;
        my $json_text = do { local $/; <$fh> };
        close($fh);
        
        my $json = JSON->new();
        my $config = $json->decode($json_text);
        
        # Look through each category to find the page
        foreach my $category_name (keys %{$config->{categories}}) {
            my $category = $config->{categories}->{$category_name};
            if ($category->{pages} && ref($category->{pages}) eq 'ARRAY') {
                foreach my $page (@{$category->{pages}}) {
                    if ($page eq $page_key) {
                        # Found the page in this category, return the category's roles
                        return $category->{roles} if $category->{roles};
                    }
                }
            }
        }
    };
    
    return; # Return undef if not found or on error
}

# Return true value at the end of the module
1;