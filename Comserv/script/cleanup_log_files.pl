#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use File::Path qw(make_path);
use File::Basename;
use File::Copy;

# Base directory
my $app_root = "$FindBin::Bin/..";
my $log_dir = "$app_root/logs";

# Create logs directory if it doesn't exist
unless (-d $log_dir) {
    make_path($log_dir) or die "Failed to create logs directory: $!";
    print "Created logs directory: $log_dir\n";
}

# Patterns that identify log files that should be in the logs directory
my @log_patterns = (
    '^Categorized as',
    '^Added .+ to .+ category',
    '^Formatting title from:',
    '^Formatted title result:',
    '^Documentation system',
    '^Starting Documentation',
    '^Found documentation',
    '^Category .+ has \d+ pages',
    '^Pages in .+ Documentation:',
    '^.+ controller .+ action called',
    '^IT .+ action called',
    '^INFO:',
    '^DEBUG:',
    '^WARN:',
    '^ERROR:',
    '^FATAL:'
);

# Find all files in the application root that match the patterns
my @files_to_move;
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
        foreach my $pattern (@log_patterns) {
            if ($first_line =~ /$pattern/) {
                $match = 1;
                last;
            }
        }
        
        # Also check if the filename itself matches a pattern
        foreach my $pattern (@log_patterns) {
            if ($file =~ /$pattern/) {
                $match = 1;
                last;
            }
        }
    }
    
    if ($match) {
        push @files_to_move, $file;
    }
}
closedir($dh);

# Move the log files to the logs directory
my $moved_count = 0;
my $removed_count = 0;
print "Moving log files from application root to logs directory...\n";
foreach my $file (@files_to_move) {
    my $source = "$app_root/$file";
    my $dest = "$log_dir/moved_$file";
    
    print "  Moving: $file\n";
    if (copy($source, $dest)) {
        if (unlink($source)) {
            $moved_count++;
        } else {
            print "    Failed to remove original file: $!\n";
        }
    } else {
        print "    Failed to copy: $!\n";
        # If we can't copy, try to remove the file directly
        if (unlink($source)) {
            print "    Removed original file\n";
            $removed_count++;
        } else {
            print "    Failed to remove original file: $!\n";
        }
    }
}

print "\nSummary:\n";
print "  $moved_count files moved to logs directory\n";
print "  $removed_count files removed directly\n";
print "Done.\n";
