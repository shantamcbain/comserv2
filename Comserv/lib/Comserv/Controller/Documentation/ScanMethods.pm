package Comserv::Controller::Documentation::ScanMethods;
use strict;
use warnings;
use File::Find;
use File::Basename;
use Comserv::Util::Logging;
use Exporter 'import';
use FindBin;
use File::Spec;

our @EXPORT = qw(_scan_directories _categorize_pages _parse_meta_block _extract_md_metadata _convert_to_camel_case);

# Helper function to convert filenames to CamelCase format
sub _convert_to_camel_case {
    my ($filename) = @_;
    my ($name, $ext) = $filename =~ /^(.+)(\.[^.]+)$/ or return $filename;
    
    # Handle dates at start: 2025-04-08-something.tt -> something-2025-04-08.tt
    if ($name =~ /^(\d{4}-\d{2}-\d{2})-(.+)$/) {
        my $date = $1;
        my $rest = $2;
        $rest =~ s/-([a-z])/\U$1/g;
        $rest = ucfirst($rest);
        return "$rest-$date$ext";
    }
    
    # Handle dates at end: something_2025-12-25.tt
    if ($name =~ /^(.+?)_(\d{4}-\d{2}-\d{2})$/) {
        my $rest = $1;
        my $date = $2;
        $rest =~ s/_([a-z])/\U$1/g;
        $rest = ucfirst($rest);
        return "$rest-$date$ext";
    }
    
    # Regular conversion: convert underscores/hyphens to CamelCase
    $name =~ s/_([a-z])/\U$1/g;
    $name =~ s/-([a-z])/\U$1/g;
    $name = ucfirst($name);
    
    return "$name$ext";
}

# Get the application log file path
my $APP_LOG_FILE = $ENV{'COMSERV_LOG_DIR'} ? 
    File::Spec->catfile($ENV{'COMSERV_LOG_DIR'}, 'application.log') : 
    File::Spec->catfile($FindBin::Bin, '..', 'logs', 'application.log');

# Helper function to parse META block from .tt files
sub _parse_meta_block {
    my ($content) = @_;
    my $meta = {};

    # Look for [% META ... %] block
    if ($content =~ /\[% \s* META \s* (.*?) \s* %\]/sx) {
        my $meta_content = $1;

        # Parse key = value pairs
        while ($meta_content =~ /\b(\w+)\s*=\s*["']([^"']*)["']/g) {
            my ($key, $value) = ($1, $2);
            $meta->{$key} = $value;
        }
    }

    return $meta;
}

# Helper function to extract metadata from .md files
sub _extract_md_metadata {
    my ($content, $filename) = @_;
    my $meta = {};

    # Default category for .md files
    $meta->{category} = 'admin';

    # Try to extract title from first heading
    if ($content =~ /^#\s+(.+)$/m) {
        $meta->{title} = $1;
    } else {
        # Convert filename to title (remove extension and convert underscores/spaces)
        my $title = $filename;
        $title =~ s/_/ /g;
        $title =~ s/-/ /g;
        $title = join(' ', map { ucfirst(lc($_)) } split(/\s+/, $title));
        $meta->{title} = $title;
    }

    # Extract description from first paragraph after title or from content
    if ($content =~ /^#.*$(?:\r?\n)+([^\n#]+)(?:\r?\n|$)/m) {
        my $desc = $1;
        $desc =~ s/^\s+|\s+$//g;
        $meta->{description} = $desc if length($desc) > 10;
    } elsif ($content =~ /^([^\n#]+)(?:\r?\n|$)/m) {
        my $desc = $1;
        $desc =~ s/^\s+|\s+$//g;
        $meta->{description} = $desc if length($desc) > 10;
    }

    # Default roles for admin category
    $meta->{roles} = 'admin,developer';

    return $meta;
}

# Scan directories for documentation files
sub _scan_directories {
    my ($self, $c) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_scan_directories',
        "Starting directory scan for documentation files");

    # Scan the Documentation directory for all files
    # Use Catalyst's path_to() for correct path resolution within Comserv app structure
    my $doc_dir = $c->path_to('root', 'Documentation');
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
                    my $doc_base = $c->path_to('root');
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

                    # Read file content to extract metadata
                    my $file_meta = {};
                    eval {
                        open my $fh, '<:encoding(UTF-8)', $file or die "Cannot open file: $!";
                        my $content = do { local $/; <$fh> };
                        close $fh;

                        if ($file =~ /\.tt$/) {
                            $file_meta = _parse_meta_block($content);
                        } elsif ($file =~ /\.md$/) {
                            $file_meta = _extract_md_metadata($content, $key);
                        }
                    };

                    if ($@) {
                        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, '_scan_directories',
                            "Error reading metadata from $file: $@");
                    }

                    # Determine site and role requirements
                    my $site = $file_meta->{site_specific} && $file_meta->{site_specific} eq 'true' ? 'specific' : 'all';
                    my @roles;

                    # Use roles from file metadata if available
                    if ($file_meta->{roles}) {
                        @roles = split(/\s*,\s*/, $file_meta->{roles});
                    } else {
                        # Fallback to path-based logic

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
                                @roles = ('admin', 'developer');
                            } elsif ($path =~ m{Documentation/controllers/} || $path =~ m{Documentation/models/}) {
                                @roles = ('admin', 'developer');
                            } elsif ($path =~ m{Documentation/system/} || $path =~ m{Documentation/proxmox/}) {
                                @roles = ('admin', 'developer');
                            } elsif ($path =~ m{Documentation/environment/}) {
                                @roles = ('admin', 'developer');
                            } elsif ($path =~ m{Documentation/deployment/}) {
                                @roles = ('admin', 'developer');
                            } elsif ($path =~ m{Documentation/operations/}) {
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
                                format => $format,
                                title => $file_meta->{title},
                                description => $file_meta->{description},
                                category => $file_meta->{category}
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
                            format => $format,
                            title => $file_meta->{title},
                            description => $file_meta->{description},
                            category => $file_meta->{category}
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
        my $assigned_category = $page->{category};

        # Determine category if not assigned
        if (!$assigned_category) {
            # For uncategorized pages, assign to admin_guides
            $assigned_category = 'admin_guides';
            $page->{category} = $assigned_category; # Update the page metadata
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_categorize_pages',
                "Assigned uncategorized page '$page_id' to admin_guides");
        }

        # Add to appropriate categories
        foreach my $category_key (keys %{$self->documentation_categories}) {
            my $category = $self->documentation_categories->{$category_key};

            # Add to category based on assigned category (highest priority)
            if ($assigned_category && $assigned_category eq $category_key) {
                push @{$category->{pages}}, $page_id unless grep { $_ eq $page_id } @{$category->{pages}};
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_categorize_pages',
                    "Added '$page_id' to $category_key category (assigned)");
                next; # Skip path-based checks for this category since assigned
            }

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