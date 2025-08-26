#!/usr/bin/env perl
use strict;
use warnings;
use File::Basename;

# Base directory
my $app_root = "/home/shanta/PycharmProjects/comserv2/Comserv";

# Patterns to identify categorization files
my @patterns = (
    '^Added .+ to .+ category',
    '^Formatting title from:',
    '^Formatted title result:',
    '^Categorized as',
    '^Category .+ has \d+ pages',
    '^Pages in .+ Documentation:',
    '^.+ controller .+ action called',
    '^IT .+ action called',
    '^Starting Documentation controller',
    '^Documentation system initialized'
);

# Find all files in the application root that match the patterns
my @files_to_remove;
opendir(my $dh, $app_root) or die "Cannot open directory $app_root: $!";
while (my $file = readdir($dh)) {
    next if $file =~ /^\./ || -d "$app_root/$file";
    
    # Skip important files
    next if $file =~ /\.(pl|pm|conf|json|yml|yaml|sh|sql|css|js|html|tt|txt|md)$/;
    next if $file eq 'Makefile.PL' || $file eq 'README' || $file eq 'comserv.psgi' || $file eq 'cpanfile' || $file eq 'project_fixes.patch';
    
    # Check if file matches any of the patterns
    my $match = 0;
    open(my $fh, '<', "$app_root/$file") or next;
    my $first_line = <$fh>;
    close($fh);
    
    if ($first_line) {
        chomp $first_line;
        foreach my $pattern (@patterns) {
            if ($first_line =~ /$pattern/) {
                $match = 1;
                last;
            }
        }
        
        # Also check if the filename itself matches a pattern
        foreach my $pattern (@patterns) {
            if ($file =~ /$pattern/) {
                $match = 1;
                last;
            }
        }
    }
    
    if ($match) {
        push @files_to_remove, $file;
    }
}
closedir($dh);

# Remove the categorization files
my $removed_count = 0;
print "Removing categorization files from application root...\n";
foreach my $file (@files_to_remove) {
    print "  Removing: $file\n";
    if (unlink("$app_root/$file")) {
        $removed_count++;
    } else {
        print "    Failed to remove: $!\n";
    }
}

print "\nSummary:\n";
print "  $removed_count files removed\n";
print "Done.\n";
