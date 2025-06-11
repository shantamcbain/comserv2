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
    my ($self) = @_;
    
    Comserv::Util::Logging::log_to_file("Starting directory scan for documentation files", $APP_LOG_FILE, 'INFO');
    
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
                    # Skip hidden files
                    return if $basename =~ /^\./;

                    # Create a safe key for the documentation_pages hash
                    my $key;

                    # Handle .tt files (template toolkit)
                    if ($file =~ /\.tt$/) {
                        $key = basename($file, '.tt');
                    } 
                    # Handle .md files (markdown)
                    elsif ($file =~ /\.md$/) {
                        $key = basename($file, '.md');
                    }
                    # Handle .html files
                    elsif ($file =~ /\.html$/) {
                        $key = basename($file, '.html');
                    }
                    # Handle .txt files
                    elsif ($file =~ /\.txt$/) {
                        $key = basename($file, '.txt');
                    }
                    else {
                        # Handle other file types (json, etc.)
                        my ($name, $ext) = split(/\./, $basename, 2);
                        if ($ext) {
                            $key = "${name}";
                        } else {
                            $key = $basename;
                        }
                    }

                    # Clean the key to remove special characters
                    $key =~ s/[^\w\-]/_/g;

                    # Log the file being processed
                    Comserv::Util::Logging::log_to_file("Processing file: $file, key: $key, path: $path", $APP_LOG_FILE, 'INFO');

                    # Determine site and role requirements
                    my $site = 'all';
                    my @roles = ('normal', 'editor', 'admin', 'developer');

                    # Check if this is site-specific documentation
                    if ($path =~ m{Documentation/sites/([^/]+)/}) {
                        $site = uc($1); # Convert site name to uppercase to match SiteName format
                        Comserv::Util::Logging::log_to_file("Found site-specific doc for site: $site", $APP_LOG_FILE, 'INFO');
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
                        Comserv::Util::Logging::log_to_file("Found role-specific doc for roles: " . join(',', @roles), $APP_LOG_FILE, 'INFO');
                    }
                    
                    # Also recognize admin docs in the admin directory
                    if ($path =~ m{Documentation/admin/}) {
                        @roles = ('admin', 'developer');
                        Comserv::Util::Logging::log_to_file("Found admin directory doc - setting admin roles", $APP_LOG_FILE, 'INFO');
                    }
                    
                    # Determine file format
                    my $format = 'other';
                    if ($path =~ /\.md$/i) {
                        $format = 'markdown';
                    } elsif ($path =~ /\.tt$/i) {
                        $format = 'template';
                    } elsif ($path =~ /\.html$/i) {
                        $format = 'html';
                    } elsif ($path =~ /\.txt$/i) {
                        $format = 'text';
                    }

                    # Generate a title from the key
                    my $title = $key;
                    $title =~ s/_/ /g;  # Replace underscores with spaces
                    $title =~ s/-/ /g;  # Replace hyphens with spaces
                    $title = join(' ', map { ucfirst($_) } split(/\s+/, $title)); # Capitalize words
                    
                    # Store the path with metadata
                    $self->documentation_pages->{$key} = {
                        path => $path,
                        site => $site,
                        roles => \@roles,
                        format => $format,
                        title => $title,
                        description => "Documentation for $title"
                    };
                },
                no_chdir => 1,
            },
            $doc_dir
        );
    }
    
    Comserv::Util::Logging::log_to_file(
        "Directory scan completed. Found " . scalar(keys %{$self->documentation_pages}) . " pages.",
        $APP_LOG_FILE, 'INFO'
    );
}

# Categorize pages based on their paths
sub _categorize_pages {
    my ($self) = @_;
    
    Comserv::Util::Logging::log_to_file("Categorizing documentation pages", $APP_LOG_FILE, 'INFO');
    
    # Clear existing category pages
    foreach my $category_key (keys %{$self->documentation_categories}) {
        $self->documentation_categories->{$category_key}->{pages} = [];
    }
    
    # Add every documentation page to the general category first
    foreach my $page_id (keys %{$self->documentation_pages}) {
        push @{$self->documentation_categories->{general}->{pages}}, $page_id;
    }
    
    # Categorize each page
    foreach my $page_id (keys %{$self->documentation_pages}) {
        my $page = $self->documentation_pages->{$page_id};
        my $path = $page->{path};
        my $site = $page->{site};
        my $page_name = $page_id; # Use page ID for name matching
        
        # Log page being categorized
        Comserv::Util::Logging::log_to_file("Categorizing page: $page_id (path: $path)", $APP_LOG_FILE, 'DEBUG');
        
        # Site-specific category
        if ($site ne 'all') {
            push @{$self->documentation_categories->{site_specific}->{pages}}, $page_id;
            Comserv::Util::Logging::log_to_file(
                "Added '$page_id' to site-specific category (site: $site)", $APP_LOG_FILE, 'INFO');
        }
        
        # Controller documentation
        if ($path =~ m{Documentation/controllers/} || 
            $page_name =~ /controller/i || 
            $page_name =~ /^(root|user|site|admin|documentation|proxmox|todo|project|file|mail|log|themeadmin|themeeditor|csc|ency|usbm|apiary|bmaster|forager|ve7tit|workshop)$/i) {
            
            push @{$self->documentation_categories->{controllers}->{pages}}, $page_id;
            Comserv::Util::Logging::log_to_file(
                "Added '$page_id' to controllers category", $APP_LOG_FILE, 'INFO');
        }
        
        # Model documentation
        if ($path =~ m{Documentation/models/} || 
            $page_name =~ /model/i || 
            $page_name =~ /^(user|site|theme|themeconfig|todo|project|proxmox|calendar|file|mail|log|dbschemamanager|dbency|dbforager|encymodel|bmaster|bmastermodel|apiarymodel|workshop)$/i) {
            
            push @{$self->documentation_categories->{models}->{pages}}, $page_id;
            Comserv::Util::Logging::log_to_file(
                "Added '$page_id' to models category", $APP_LOG_FILE, 'INFO');
        }
        
        # Proxmox documentation
        if ($path =~ m{Documentation/proxmox/} || $page_name =~ /proxmox/i) {
            push @{$self->documentation_categories->{proxmox}->{pages}}, $page_id;
            Comserv::Util::Logging::log_to_file(
                "Added '$page_id' to proxmox category", $APP_LOG_FILE, 'INFO');
        }
        
        # Changelog documentation
        if ($path =~ m{Documentation/changelog/}) {
            push @{$self->documentation_categories->{changelog}->{pages}}, $page_id;
            Comserv::Util::Logging::log_to_file(
                "Added '$page_id' to changelog category", $APP_LOG_FILE, 'INFO');
        }
        
        # User guides - for normal users
        if ($path =~ m{Documentation/roles/normal/} || 
            $page_name =~ /^(getting_started|account_management|user_guide|faq)/i) {
            
            push @{$self->documentation_categories->{user_guides}->{pages}}, $page_id;
            Comserv::Util::Logging::log_to_file(
                "Added '$page_id' to user_guides category", $APP_LOG_FILE, 'INFO');
        }
        
        # Admin guides
        if ($path =~ m{Documentation/roles/admin/} || 
            $path =~ m{Documentation/admin/} ||
            $page_name =~ /^(installation|configuration|system|admin|user_management)/i) {
            
            push @{$self->documentation_categories->{admin_guides}->{pages}}, $page_id;
            Comserv::Util::Logging::log_to_file(
                "Added '$page_id' to admin_guides category", $APP_LOG_FILE, 'INFO');
        }
        
        # Developer guides
        if ($path =~ m{Documentation/roles/developer/} || 
            $path =~ m{Documentation/developer/}) {
            
            push @{$self->documentation_categories->{developer_guides}->{pages}}, $page_id;
            Comserv::Util::Logging::log_to_file(
                "Added '$page_id' to developer_guides category", $APP_LOG_FILE, 'INFO');
        }
        
        # Tutorials
        if ($path =~ m{Documentation/tutorials/} || 
            $path =~ m{Documentation/workshops/}) {
            
            push @{$self->documentation_categories->{tutorials}->{pages}}, $page_id;
            Comserv::Util::Logging::log_to_file(
                "Added '$page_id' to tutorials category", $APP_LOG_FILE, 'INFO');
        }
        
        # Modules
        if ($path =~ m{Documentation/modules/} || 
            $page_name =~ /^(todo|project|task)/i) {
            
            push @{$self->documentation_categories->{modules}->{pages}}, $page_id;
            Comserv::Util::Logging::log_to_file(
                "Added '$page_id' to modules category", $APP_LOG_FILE, 'INFO');
        }
    }
    
    # Log category counts
    foreach my $category_key (keys %{$self->documentation_categories}) {
        my $count = scalar(@{$self->documentation_categories->{$category_key}->{pages}});
        Comserv::Util::Logging::log_to_file(
            "Category '$category_key' has $count pages", $APP_LOG_FILE, 'INFO');
    }
    
    Comserv::Util::Logging::log_to_file("Page categorization completed", $APP_LOG_FILE, 'INFO');
}

# Return true value at the end of the module
1;