#!/usr/bin/env perl
use strict;
use warnings;
use File::Find;
use File::Basename;
use File::Spec;
use File::Copy;
use Text::Markdown 'markdown';
use Time::Piece;

# Configuration
my $changelog_dir = "../changelog";
my $template_file = "../changelog/changelog_template.tt";

# Get absolute paths
my $script_dir = dirname(File::Spec->rel2abs($0));
$changelog_dir = File::Spec->rel2abs($changelog_dir, $script_dir);
$template_file = File::Spec->rel2abs($template_file, $script_dir);

# Check if template exists
unless (-f $template_file) {
    die "Template file not found: $template_file\n";
}

# Read template content
open my $template_fh, '<', $template_file or die "Cannot open template file: $!";
my $template_content = do { local $/; <$template_fh> };
close $template_fh;

# Find all .md files in the changelog directory
my @md_files;
find(
    {
        wanted => sub {
            return unless -f $_;
            return unless /\.md$/;
            push @md_files, $File::Find::name;
        },
        no_chdir => 1
    },
    $changelog_dir
);

print "Found " . scalar(@md_files) . " .md files to convert.\n";

# Process each file
foreach my $md_file (@md_files) {
    print "Processing $md_file...\n";
    
    # Generate the new .tt filename
    my $tt_file = $md_file;
    $tt_file =~ s/\.md$/\.tt/;
    
    # Skip if .tt file already exists
    if (-f $tt_file) {
        print "  Skipping: $tt_file already exists.\n";
        next;
    }
    
    # Extract date from filename
    my ($filename) = basename($md_file);
    my $date = '';
    if ($filename =~ /^(\d{4}-\d{2}(-\d{2})?)/) {
        $date = $1;
        # Ensure date is in YYYY-MM-DD format
        if (length($date) == 7) {
            $date .= "-01"; # Default to first day of month if only YYYY-MM
        }
    } else {
        # Use file modification time if no date in filename
        my $mtime = (stat($md_file))[9];
        my $t = localtime($mtime);
        $date = $t->ymd;
    }
    
    # Format date for PageVersion
    my $page_version_date = $date;
    $page_version_date =~ s/-/\//g;
    
    # Read the .md file
    open my $md_fh, '<', $md_file or die "Cannot open $md_file: $!";
    my $md_content = do { local $/; <$md_fh> };
    close $md_fh;
    
    # Extract title from the first heading
    my $title = "Changelog Entry";
    if ($md_content =~ /^#\s+(.+)$/m) {
        $title = $1;
    }
    
    # Extract description from the first paragraph after a heading
    my $description = "System change documentation.";
    if ($md_content =~ /^##\s+.+?\n\n(.+?)(\n\n|\n##|\z)/ms) {
        $description = $1;
        $description =~ s/\n/ /g; # Replace newlines with spaces
    }
    
    # Convert markdown to HTML
    my $html_content = markdown($md_content);
    
    # Clean up the HTML for template use
    $html_content =~ s/<h1>.*?<\/h1>//; # Remove the first h1 (we'll add it back with template vars)
    
    # Create the .tt content
    my $tt_content = $template_content;
    
    # Replace template variables
    $tt_content =~ s/\[% META title = '.*?' %\]/[% META title = '$title' %]/;
    $tt_content =~ s/\[% PageVersion = '.*?' %\]/[% PageVersion = 'Documentation\/changelog\/$filename.tt,v 0.01 $page_version_date Shanta Exp shanta ' %]/;
    $tt_content =~ s/entry_date = '.*?'/entry_date = '$date'/;
    $tt_content =~ s/entry_author = '.*?'/entry_author = 'System Team'/;
    $tt_content =~ s/entry_description = '.*?'/entry_description = '$description'/;
    
    # Replace the content section
    $tt_content =~ s/<div class="changelog-content">.*?<\/div>/<div class="changelog-content">$html_content<\/div>/s;
    
    # Write the .tt file
    open my $tt_fh, '>', $tt_file or die "Cannot write to $tt_file: $!";
    print $tt_fh $tt_content;
    close $tt_fh;
    
    print "  Created $tt_file\n";
}

print "Conversion complete. Converted " . scalar(@md_files) . " files.\n";
print "Please review the generated .tt files before removing the original .md files.\n";