#!/usr/bin/perl
use strict;
use warnings;
use JSON::XS;
use File::Find;
use File::Spec;
use Data::Dumper;

my $doc_dir = "Comserv/root/Documentation";
my $code_dir = "Comserv/lib/Comserv";
my %code_to_docs;  # code_file => [related_docs_array]

# Step 1: Get all .pm code files
my @code_files;
find(sub {
    return unless /\.pm$/;
    my $path = File::Spec->canonpath($File::Find::name);
    push @code_files, $path;
}, $code_dir);

print "Found " . scalar(@code_files) . " code files\n";

# Step 2: For each code file, search documentation for references
foreach my $code_file (@code_files) {
    my $related = [];
    
    # Extract filename for grepping (e.g., "Admin.pm" from "Comserv/lib/Comserv/Controller/Admin.pm")
    my $filename = (split /\//, $code_file)[-1];
    my $basename = $filename;
    $basename =~ s/\.pm$//;
    
    # Search docs for references to this code file
    my $grep_results = `grep -r "$filename\\|$basename" "$doc_dir" 2>/dev/null | grep -E '\\.tt:' | cut -d: -f1 | sort -u`;
    
    if ($grep_results) {
        my @doc_files = split /\n/, $grep_results;
        @doc_files = grep { $_ && -f $_ } @doc_files;  # Only valid files
        @doc_files = map { 
            my $p = $_;
            $p =~ s|^Comserv/root/||;  # Remove prefix for cleaner paths
            $p;
        } @doc_files;
        
        $related = \@doc_files if @doc_files;
    }
    
    my $clean_path = $code_file;
    $clean_path =~ s|^Comserv/lib/||;
    $code_to_docs{$clean_path} = $related;
}

# Step 3: Load existing RepositoryCodeAudit.json
my $audit_file = "Comserv/root/Documentation/config/RepositoryCodeAudit.json";
open my $fh, '<', $audit_file or die "Cannot read $audit_file: $!";
my $audit_data = JSON::XS->new->decode(do { local $/; <$fh> });
close $fh;

# Step 4: Merge new documentation references into audit data
foreach my $code_file (keys %{$audit_data->{code_files}}) {
    my $code_entry = $audit_data->{code_files}{$code_file};
    my $relative_path = $code_entry->{code_file};
    $relative_path =~ s|^Comserv/lib/||;
    
    # Find matching entry in our grep results
    if (exists $code_to_docs{$relative_path}) {
        my $docs = $code_to_docs{$relative_path};
        
        # Keep the original documentation_path if it exists
        my @all_docs;
        if ($code_entry->{documentation_path}) {
            push @all_docs, $code_entry->{documentation_path};
        }
        
        # Add all newly found docs
        push @all_docs, @$docs;
        
        # Remove duplicates and sort
        my %seen;
        @all_docs = grep { !$seen{$_}++ } @all_docs;
        @all_docs = sort @all_docs;
        
        # Convert to new structure
        $code_entry->{related_documentation} = \@all_docs;
        $code_entry->{doc_count} = scalar(@all_docs);
    }
}

# Step 5: Write updated audit file with timestamp
my $timestamp = `date -u +"%Y-%m-%dT%H:%M:%SZ"`;
chomp $timestamp;
$audit_data->{audit_timestamp} = $timestamp;
$audit_data->{mapping_version} = "2.0";  # Indicate 1:N support
$audit_data->{mapping_note} = "Each code file now maps to array of related documentation files (1:N relationship)";

my $json = JSON::XS->new->pretty->canonical->encode($audit_data);
open $fh, '>', $audit_file or die "Cannot write $audit_file: $!";
print $fh $json;
close $fh;

print "\n✅ Updated RepositoryCodeAudit.json with 1:N documentation mapping\n";
print "   - Timestamp: $timestamp\n";
print "   - Mapping version: 2.0 (1:N relationships)\n";

# Summary statistics
my $total_entries = scalar(keys %{$audit_data->{code_files}});
my $with_docs = scalar(grep { $_->{doc_count} && $_->{doc_count} > 0 } values %{$audit_data->{code_files}});
my $with_multiple = scalar(grep { $_->{doc_count} && $_->{doc_count} > 1 } values %{$audit_data->{code_files}});

print "\n📊 Mapping Statistics:\n";
print "   - Total code files: $total_entries\n";
print "   - Files with documentation: $with_docs\n";
print "   - Files with multiple docs: $with_multiple\n";
