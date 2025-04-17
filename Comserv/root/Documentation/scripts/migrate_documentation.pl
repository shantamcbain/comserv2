#!/usr/bin/perl

use strict;
use warnings;
use File::Find;
use File::Path qw(make_path);
use File::Basename;
use File::Copy;
use JSON;
use Data::Dumper;

# Configuration
my $source_dir = "/home/shanta/PycharmProjects/comserv/Comserv/root/Documentation";
my $target_dir = "/home/shanta/PycharmProjects/comserv/Comserv/root/Documentation/docs";
my $config_file = "$source_dir/documentation_config.json";

# Create target directories if they don't exist
make_path("$target_dir/user");
make_path("$target_dir/admin");
make_path("$target_dir/developer");
make_path("$target_dir/site/mcoop");
make_path("$target_dir/module");
make_path("$target_dir/changelog");

# Load configuration
my $config = load_config($config_file);

# Process files
find(\&process_file, $source_dir);

# Print summary
print "Documentation migration completed.\n";

# Function to load configuration
sub load_config {
    my ($file) = @_;
    
    open my $fh, '<', $file or die "Cannot open $file: $!";
    my $json = do { local $/; <$fh> };
    close $fh;
    
    return decode_json($json);
}

# Function to process each file
sub process_file {
    my $file = $_;
    my $path = $File::Find::name;
    
    # Skip directories and non-documentation files
    return if -d $file;
    return unless $file =~ /\.(md|tt)$/;
    
    # Skip files in the target directory
    return if $path =~ m{^$target_dir};
    
    # Skip configuration files
    return if $path =~ m{documentation_config\.json$};
    return if $path =~ m{completed_items\.json$};
    
    # Skip template files
    return if $path =~ m{/templates/};
    
    # Skip script files
    return if $path =~ m{/scripts/};
    
    # Determine file metadata
    my $metadata = determine_metadata($path, $file);
    
    # Determine target location
    my $target_path = determine_target_path($path, $metadata);
    
    # Create target directory if it doesn't exist
    my $target_dir = dirname($target_path);
    make_path($target_dir) unless -d $target_dir;
    
    # Add metadata to file content
    my $content = add_metadata_to_content($path, $metadata);
    
    # Write to target file
    write_file($target_path, $content);
    
    print "Migrated: $path -> $target_path\n";
}

# Function to determine metadata for a file
sub determine_metadata {
    my ($path, $file) = @_;
    
    my $metadata = {
        title => "",
        description => "",
        author => "System Administrator",
        date => "2025-05-30",
        status => "Active",
        roles => [],
        sites => ["all"],
        categories => [],
        tags => []
    };
    
    # Extract existing metadata from file content
    my $content = read_file($path);
    
    # Extract title
    if ($content =~ /^#\s+(.+)$/m) {
        $metadata->{title} = $1;
    } else {
        # Use filename as title if no title found
        my $basename = basename($file, qr/\.(md|tt)$/);
        $basename =~ s/_/ /g;
        $metadata->{title} = ucfirst($basename);
    }
    
    # Extract author and date
    if ($content =~ /\*\*Author:\*\*\s+(.+?)(?:\s+\*\*|\s*$)/m) {
        $metadata->{author} = $1;
    }
    
    if ($content =~ /\*\*(?:Date|Last Updated):\*\*\s+(.+?)(?:\s+\*\*|\s*$)/m) {
        $metadata->{date} = $1;
    }
    
    if ($content =~ /\*\*Status:\*\*\s+(.+?)(?:\s+\*\*|\s*$)/m) {
        $metadata->{status} = $1;
    }
    
    # Determine roles based on path
    if ($path =~ m{/roles/admin/}) {
        $metadata->{roles} = ["admin", "developer"];
    } elsif ($path =~ m{/roles/developer/}) {
        $metadata->{roles} = ["developer"];
    } elsif ($path =~ m{/roles/normal/}) {
        $metadata->{roles} = ["normal", "editor", "admin", "developer"];
    } else {
        $metadata->{roles} = ["normal", "editor", "admin", "developer"];
    }
    
    # Determine site based on path
    if ($path =~ m{/sites/([^/]+)/}) {
        my $site = uc($1);
        $metadata->{sites} = [$site];
    }
    
    # Determine categories based on path and config
    my $basename = basename($file, qr/\.(md|tt)$/);
    
    # Check if file is in config
    foreach my $category (keys %{$config->{categories}}) {
        if (grep { $_ eq $basename } @{$config->{categories}->{$category}->{pages}}) {
            push @{$metadata->{categories}}, $category;
        }
    }
    
    # If no categories found, determine based on path
    if (!@{$metadata->{categories}}) {
        if ($path =~ m{/roles/admin/}) {
            push @{$metadata->{categories}}, "admin_guides";
        } elsif ($path =~ m{/roles/developer/}) {
            push @{$metadata->{categories}}, "developer_guides";
        } elsif ($path =~ m{/roles/normal/}) {
            push @{$metadata->{categories}}, "user_guides";
        } elsif ($path =~ m{/tutorials/}) {
            push @{$metadata->{categories}}, "tutorials";
        } elsif ($path =~ m{/changelog/}) {
            push @{$metadata->{categories}}, "changelog";
        } elsif ($path =~ m{/controllers/}) {
            push @{$metadata->{categories}}, "controllers";
        } elsif ($path =~ m{/sites/}) {
            push @{$metadata->{categories}}, "site_specific";
        }
    }
    
    # Extract description from content
    if ($content =~ /^#\s+.+\s*$(.*?)^##/ms) {
        my $overview = $1;
        $overview =~ s/^\s*\*\*.*?\*\*\s*$//mg; # Remove metadata lines
        $overview =~ s/^\s+|\s+$//g; # Trim whitespace
        
        if ($overview) {
            my @lines = split /\n/, $overview;
            foreach my $line (@lines) {
                $line =~ s/^\s+|\s+$//g;
                if ($line && $line !~ /^$/) {
                    $metadata->{description} = $line;
                    last;
                }
            }
        }
    }
    
    # If no description found, use a generic one
    if (!$metadata->{description}) {
        $metadata->{description} = "Documentation for " . $metadata->{title};
    }
    
    # Generate tags based on title and content
    my @title_words = split /\s+/, lc($metadata->{title});
    foreach my $word (@title_words) {
        next if length($word) < 4; # Skip short words
        next if $word =~ /^(and|the|for|with|this|that|from|have|what|when|where|which|about)$/; # Skip common words
        push @{$metadata->{tags}}, $word;
    }
    
    # Limit to 5 tags
    if (@{$metadata->{tags}} > 5) {
        @{$metadata->{tags}} = @{$metadata->{tags}}[0..4];
    }
    
    return $metadata;
}

# Function to determine target path for a file
sub determine_target_path {
    my ($path, $metadata) = @_;
    
    my $basename = basename($path);
    my $target_subdir;
    
    # Determine target subdirectory based on roles and categories
    if (grep { $_ eq "developer_guides" } @{$metadata->{categories}}) {
        $target_subdir = "developer";
    } elsif (grep { $_ eq "admin_guides" } @{$metadata->{categories}}) {
        $target_subdir = "admin";
    } elsif (grep { $_ eq "changelog" } @{$metadata->{categories}}) {
        $target_subdir = "changelog";
    } elsif (grep { $_ eq "site_specific" } @{$metadata->{categories}}) {
        my $site = lc($metadata->{sites}->[0]);
        $site = "mcoop" if $site eq "all"; # Default to mcoop if no specific site
        $target_subdir = "site/$site";
    } elsif (grep { $_ eq "modules" } @{$metadata->{categories}}) {
        $target_subdir = "module";
    } else {
        $target_subdir = "user";
    }
    
    return "$target_dir/$target_subdir/$basename";
}

# Function to add metadata to file content
sub add_metadata_to_content {
    my ($path, $metadata) = @_;
    
    my $content = read_file($path);
    
    # Remove existing metadata if present
    $content =~ s/^\s*\*\*(?:Author|Date|Last Updated|Status):\*\*.*$//mg;
    
    # Create metadata section
    my $metadata_section = "---\n";
    $metadata_section .= "title: \"$metadata->{title}\"\n";
    $metadata_section .= "description: \"$metadata->{description}\"\n";
    $metadata_section .= "author: \"$metadata->{author}\"\n";
    $metadata_section .= "date: \"$metadata->{date}\"\n";
    $metadata_section .= "status: \"$metadata->{status}\"\n";
    $metadata_section .= "roles: [" . join(", ", map { "\"$_\"" } @{$metadata->{roles}}) . "]\n";
    $metadata_section .= "sites: [" . join(", ", map { "\"$_\"" } @{$metadata->{sites}}) . "]\n";
    $metadata_section .= "categories: [" . join(", ", map { "\"$_\"" } @{$metadata->{categories}}) . "]\n";
    $metadata_section .= "tags: [" . join(", ", map { "\"$_\"" } @{$metadata->{tags}}) . "]\n";
    $metadata_section .= "---\n\n";
    
    # Add metadata section to content
    return $metadata_section . $content;
}

# Function to read file content
sub read_file {
    my ($path) = @_;
    
    open my $fh, '<:encoding(UTF-8)', $path or die "Cannot open $path: $!";
    my $content = do { local $/; <$fh> };
    close $fh;
    
    return $content;
}

# Function to write file content
sub write_file {
    my ($path, $content) = @_;
    
    open my $fh, '>:encoding(UTF-8)', $path or die "Cannot open $path: $!";
    print $fh $content;
    close $fh;
}