#!/usr/bin/perl

use strict;
use warnings;
use lib '.';
use MetadataParser;
use Data::Dumper;

# Configuration
my $docs_dir = "/home/shanta/PycharmProjects/comserv/Comserv/root/Documentation/docs";

# Create metadata parser
my $parser = MetadataParser->new(docs_dir => $docs_dir);

# Test parsing a file
if (@ARGV) {
    my $file = $ARGV[0];
    print "Parsing file: $file\n";
    
    my $metadata = $parser->parse_file($file);
    print "Metadata:\n";
    print Dumper($metadata);
} else {
    # Scan directory and parse all files
    my @files = $parser->scan_directory();
    
    print "Found " . scalar(@files) . " files\n";
    
    foreach my $file (@files) {
        print "Parsing file: $file\n";
        
        my $metadata = $parser->parse_file($file);
        print "Metadata:\n";
        print Dumper($metadata);
        
        print "\n";
    }
}