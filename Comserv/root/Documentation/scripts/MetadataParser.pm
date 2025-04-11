package MetadataParser;

use strict;
use warnings;
use YAML::XS;
use Carp;
use File::Find;

sub new {
    my ($class, %args) = @_;
    my $self = {
        docs_dir => $args{docs_dir} || die "docs_dir is required",
        cache => {},
    };
    return bless $self, $class;
}

sub parse_file {
    my ($self, $file_path) = @_;
    
    # Check cache
    return $self->{cache}{$file_path} if exists $self->{cache}{$file_path};
    
    # Read file
    open my $fh, '<:encoding(UTF-8)', $file_path or croak "Cannot open $file_path: $!";
    my $content = do { local $/; <$fh> };
    close $fh;
    
    # Extract metadata
    my $metadata = {};
    if ($content =~ /^---\s*$(.*?)^---\s*$/ms) {
        my $yaml_content = $1;
        
        # Parse YAML
        eval {
            $metadata = YAML::XS::Load($yaml_content);
        };
        if ($@) {
            warn "Error parsing metadata in $file_path: $@";
            
            # Try manual parsing as fallback
            foreach my $line (split /\n/, $yaml_content) {
                if ($line =~ /^\s*(\w+)\s*:\s*"?([^"]*)"?\s*$/) {
                    my ($key, $value) = ($1, $2);
                    $metadata->{$key} = $value;
                }
                elsif ($line =~ /^\s*(\w+)\s*:\s*\[(.*)\]\s*$/) {
                    my ($key, $value_list) = ($1, $2);
                    my @values = map { s/^\s*"?//; s/"?\s*$//; $_ } split /,/, $value_list;
                    $metadata->{$key} = \@values;
                }
            }
        }
    }
    
    # Set defaults for required fields
    $metadata->{title} ||= "Untitled Document";
    $metadata->{description} ||= "No description provided";
    $metadata->{author} ||= "Unknown";
    $metadata->{date} ||= "Unknown";
    $metadata->{status} ||= "Active";
    $metadata->{roles} ||= ["developer"];
    $metadata->{sites} ||= ["all"];
    $metadata->{categories} ||= [];
    $metadata->{tags} ||= [];
    
    # Cache result
    $self->{cache}{$file_path} = $metadata;
    
    return $metadata;
}

sub scan_directory {
    my ($self) = @_;
    my $docs_dir = $self->{docs_dir};
    my @files;
    
    find(
        {
            wanted => sub {
                my $file = $_;
                return if -d $file;
                return unless $file =~ /\.(md|tt)$/;
                push @files, $File::Find::name;
            },
            no_chdir => 1
        },
        $docs_dir
    );
    
    return @files;
}

sub extract_metadata_from_content {
    my ($self, $content) = @_;
    
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
    
    # Extract title
    if ($content =~ /^#\s+(.+)$/m) {
        $metadata->{title} = $1;
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
    
    return $metadata;
}

sub add_metadata_to_content {
    my ($self, $content, $metadata) = @_;
    
    # Remove existing metadata if present
    $content =~ s/^---\s*$(.*?)^---\s*$//ms;
    
    # Create metadata section
    my $metadata_section = "---\n";
    $metadata_section .= "title: \"$metadata->{title}\"\n";
    $metadata_section .= "description: \"$metadata->{description}\"\n";
    $metadata_section .= "author: \"$metadata->{author}\"\n";
    $metadata_section .= "date: \"$metadata->{date}\"\n";
    $metadata_section .= "status: \"$metadata->{status}\"\n";
    
    # Handle arrays
    $metadata_section .= "roles: [" . join(", ", map { "\"$_\"" } @{$metadata->{roles}}) . "]\n";
    $metadata_section .= "sites: [" . join(", ", map { "\"$_\"" } @{$metadata->{sites}}) . "]\n";
    $metadata_section .= "categories: [" . join(", ", map { "\"$_\"" } @{$metadata->{categories}}) . "]\n";
    $metadata_section .= "tags: [" . join(", ", map { "\"$_\"" } @{$metadata->{tags}}) . "]\n";
    $metadata_section .= "---\n\n";
    
    # Add metadata section to content
    return $metadata_section . $content;
}

1;