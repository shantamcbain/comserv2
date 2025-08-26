#!/usr/bin/perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/Comserv/lib";

# Simple test to debug the search functionality
use File::Find;
use File::Basename;

print "=== Documentation Search Debug Test ===\n";

my $base_dir = "$FindBin::Bin/Comserv/root/Documentation";
my $query = "user";

print "Base directory: $base_dir\n";
print "Search query: $query\n";
print "Directory exists: " . (-d $base_dir ? "YES" : "NO") . "\n\n";

my @found_files;

# Scan for .tt files
find({
    wanted => sub {
        return if -d $_;
        return unless /\.tt$/i;
        
        my $full_path = $File::Find::name;
        my $rel_path = $full_path;
        $rel_path =~ s/^.*\/root\///;  # Remove everything up to and including /root/
        
        push @found_files, {
            full_path => $full_path,
            rel_path => $rel_path,
            filename => basename($full_path)
        };
    },
    no_chdir => 1
}, $base_dir);

print "Found " . scalar(@found_files) . " .tt files\n\n";

# Test reading and searching first 5 files
my $count = 0;
foreach my $file (@found_files) {
    last if $count >= 5;
    
    print "=== File $count: $file->{filename} ===\n";
    print "Full path: $file->{full_path}\n";
    print "Rel path: $file->{rel_path}\n";
    print "File exists: " . (-f $file->{full_path} ? "YES" : "NO") . "\n";
    print "File readable: " . (-r $file->{full_path} ? "YES" : "NO") . "\n";
    
    if (-f $file->{full_path} && -r $file->{full_path}) {
        # Read file content
        open my $fh, '<:encoding(UTF-8)', $file->{full_path} or do {
            print "ERROR: Cannot open file: $!\n\n";
            next;
        };
        
        my $content = do { local $/; <$fh> };
        close $fh;
        
        print "Content length: " . length($content) . "\n";
        
        # Clean content (simplified version)
        my $cleaned = $content;
        $cleaned =~ s/\[%.*?%\]//gs;  # Remove TT directives
        $cleaned =~ s/<[^>]+>/ /g;    # Remove HTML tags
        $cleaned =~ s/\s+/ /g;        # Normalize whitespace
        $cleaned =~ s/^\s+|\s+$//g;   # Trim
        
        print "Cleaned length: " . length($cleaned) . "\n";
        
        # Test search
        my $has_match = $cleaned =~ /\Q$query\E/i;
        print "Contains '$query': " . ($has_match ? "YES" : "NO") . "\n";
        
        if ($has_match) {
            # Show context
            if ($cleaned =~ /(.{0,50}\Q$query\E.{0,50})/i) {
                print "Context: $1\n";
            }
        }
        
        print "Sample content: " . substr($cleaned, 0, 100) . "...\n";
    }
    
    print "\n";
    $count++;
}

print "=== Test Complete ===\n";