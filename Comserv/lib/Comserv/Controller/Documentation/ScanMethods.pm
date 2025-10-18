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

                    # Handle .tt files
                    if ($file =~ /\.tt$/) {
                        $key = basename($file, '.tt');
                    } elsif ($file =~ /\.md$/) {
                        $key = basename($file, '.md');
                    } else {
                        # Handle other file types (json, etc.)
                        my ($name, $ext) = split(/\./, $basename, 2);
                        if ($ext) {
                            $key = "${name}";
                        } else {
                            $key = $basename;
                        }
                    }

                    # Log the file being processed (only for debug level)
                    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_scan_directories',
                        "Processing file: $file, key: $key, path: $path, full_path: $File::Find::name");

                    # Determine site and role requirements
                    my $site = 'all';
                    my @roles;

                    # Check if this is site-specific documentation
                    if ($path =~ m{Documentation/sites/([^/]+)/}) {
                        $site = uc($1); # Convert site name to uppercase to match SiteName format
                        @roles = ('admin', 'developer', 'editor'); # Site-specific docs restricted
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
                        } elsif ($role eq 'normal') {
                            @roles = ('normal', 'editor', 'admin', 'developer');
                        }
                    }
                    
                    # If no specific role directory, determine by path and content type
                    unless (@roles) {
                        if ($path =~ m{Documentation/admin/}) {
                            @roles = ('admin', 'developer');
                        } elsif ($path =~ m{Documentation/developer/}) {
                            @roles = ('admin', 'developer');  # FIX: Allow admins to access developer docs
                        } elsif ($path =~ m{Documentation/controllers/} || $path =~ m{Documentation/models/}) {
                            @roles = ('admin', 'developer');
                        } elsif ($path =~ m{Documentation/system/} || $path =~ m{Documentation/proxmox/}) {
                            @roles = ('admin', 'developer');
                        } elsif ($path =~ m{Documentation/session_history/}) {
                            @roles = ('admin', 'developer', 'editor');
                        } elsif ($path =~ m{Documentation/changelog/}) {
                            @roles = ('admin', 'developer', 'editor');
                        } elsif ($path =~ m{Documentation/ai_workflows/}) {
                            @roles = ('admin', 'developer');
                        } elsif ($path =~ m{Documentation/general/} || $path =~ m{Documentation/tutorials/}) {
                            @roles = ('normal', 'editor', 'admin', 'developer');
                        } else {
                            # Default for root-level documentation - accessible to all authenticated users
                            @roles = ('normal', 'editor', 'admin', 'developer');
                        }
                    }
                    
                    # Determine file format
                    my $format = 'unknown';
                    if ($path =~ /\.md$/i) {
                        $format = 'markdown';
                    } elsif ($path =~ /\.tt$/i) {
                        $format = 'template';
                    }

                    # Store the path with metadata, prioritizing .tt files over .md files
                    # If both .tt and .md exist, .tt takes precedence (according to workflow)
                    if (exists $self->documentation_pages->{$key}) {
                        my $existing_format = $self->documentation_pages->{$key}->{format};
                        # Only overwrite if current file is .tt and existing is .md
                        # This ensures .tt files take precedence
                        if ($format eq 'template' && $existing_format eq 'markdown') {
                            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_scan_directories',
                                "Overwriting .md file with .tt file for key: $key");
                            $self->documentation_pages->{$key} = {
                                path => $path,
                                site => $site,
                                roles => \@roles,
                                format => $format
                            };
                        } else {
                            # Keep existing entry, log the skip
                            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_scan_directories',
                                "Skipping $format file for key '$key' - already exists as $existing_format");
                        }
                    } else {
                        # First occurrence of this key
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
            
            # Add to developer guides if it's in the developer roles or developer directory
            if ($category_key eq 'developer_guides' && ($path =~ m{Documentation/roles/developer/} || $path =~ m{Documentation/developer/})) {
                push @{$category->{pages}}, $page_id unless grep { $_ eq $page_id } @{$category->{pages}};
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_categorize_pages',
                    "Added '$page_id' to developer_guides category");
            }
        }
    }
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_categorize_pages',
        "Page categorization completed");
}

# Return true value at the end of the module
1;