#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use File::Find;
use File::Spec;
use File::Basename;
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
            return if -d;
            return unless /\.md$/i;
            push @md_files, $File::Find::name;
        },
        no_chdir => 1,
    },
    $changelog_dir
);

foreach my $md_file (@md_files) {
    # Determine output .tt file path
    (my $tt_file = $md_file) =~ s/\.md$/.tt/i;

    # Read markdown content
    open my $md_fh, '<', $md_file or do {
        warn "Cannot open $md_file: $!";
        next;
    };
    my $md_content = do { local $/; <$md_fh> };
    close $md_fh;

    # Extract title and description from markdown content
    my $title = '';
    my $description = '';
    if ($md_content =~ /^#\s*(.+)$/m) {
        $title = $1;
    } else {
        $title = basename($md_file, '.md');
    }
    if ($md_content =~ /^##\s*Description\s*\n(.*?)(?:\n#|\z)/ms) {
        $description = $1;
        $description =~ s/\n/ /g;
        $description =~ s/^\s+|\s+$//g;
    } else {
        $description = "No description available.";
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
        # Use current date if no date in filename
        my $tp = localtime;
        $date = $tp->ymd('-');
    }

    # Convert markdown to HTML (simple conversion for demo)
    my $html_content = $md_content;
    $html_content =~ s/\n/ /g;
    $html_content =~ s/#\s*(.+?)\s*/<h1>$1<\/h1>/g;
    $html_content =~ s/##\s*(.+?)\s*/<h2>$1<\/h2>/g;
    $html_content =~ s/\*\*(.+?)\*\*/<strong>$1<\/strong>/g;
    $html_content =~ s/\*(.+?)\*/<em>$1<\/em>/g;
    $html_content =~ s/\[(.+?)\]\((.+?)\)/<a href="$2">$1<\/a>/g;
    $html_content =~ s/\n+/<br \/>/g;

    # Prepare page version date
    my $page_version_date = $date;
    $page_version_date =~ s/-/\//g;

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
