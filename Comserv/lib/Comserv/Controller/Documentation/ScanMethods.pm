package Comserv::Controller::Documentation::ScanMethods;
use strict;
use warnings;
use File::Find;
use File::Basename;
use Comserv::Util::Logging;
use Exporter 'import';

our @EXPORT = qw(_scan_directories _categorize_pages);

# Scan directories for documentation files
sub _scan_directories {
    my ($self) = @_;
    
    Comserv::Util::Logging::log_to_file("Starting directory scan for documentation files", undef, 'INFO');
    
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

                    # Log the file being processed
                    Comserv::Util::Logging::log_to_file("Processing file: $file, key: $key, path: $path", undef, 'INFO');

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
                    
                    # Determine file format
                    my $format = 'unknown';
                    if ($path =~ /\.md$/i) {
                        $format = 'markdown';
                    } elsif ($path =~ /\.tt$/i) {
                        $format = 'template';
                    }

                    # Store the path with metadata
                    $self->documentation_pages->{$key} = {
                        path => $path,
                        site => $site,
                        roles => \@roles,
                        format => $format
                    };
                },
                no_chdir => 1,
            },
            $doc_dir
        );
    }
    
    Comserv::Util::Logging::log_to_file(
        "Directory scan completed. Found " . scalar(keys %{$self->documentation_pages}) . " pages.",
        undef, 'INFO'
    );
}

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
        }
    }
    
    Comserv::Util::Logging::log_to_file("Page categorization completed", undef, 'INFO');
}

# Return true value at the end of the module
1;