#!/usr/bin/perl
use strict;
use warnings;
use JSON::MaybeXS;
use File::Find;
use File::Spec;
use DateTime;

my $base_path = '/home/shanta/PycharmProjects/comserv2';
my $doc_base = "$base_path/Comserv/root/Documentation";
my $code_base = "$base_path/Comserv/lib";

# Data structures
my %doc_files;
my %code_files;
my %mappings;
my %unmapped_docs;
my %unmapped_code;

# Extract all documentation files
sub find_docs {
    return unless -f $_ && $_ =~ /\.tt$/;
    
    my $file = $_;
    my $rel_path = File::Spec->abs2rel($file, $doc_base);
    my $basename = (File::Spec->splitpath($file))[2];
    $basename =~ s/\.tt$//;
    
    $doc_files{$basename} = {
        full_path => $file,
        relative_path => $rel_path,
        category => $rel_path =~ m{^([^/]+)/} ? $1 : 'root',
        file_size => -s $file,
        modified => (stat($file))[9],
    };
}

# Extract all code files
sub find_code {
    return unless -f $_ && $_ =~ /\.pm$/;
    
    my $file = $_;
    my $rel_path = File::Spec->abs2rel($file, $code_base);
    my $basename = (File::Spec->splitpath($file))[2];
    $basename =~ s/\.pm$//;
    
    $code_files{$basename} = {
        full_path => $file,
        relative_path => $rel_path,
        type => $rel_path =~ m{Schema/Result} ? 'model' : 
                $rel_path =~ m{Controller} ? 'controller' :
                $rel_path =~ m{Util} ? 'utility' : 'other',
        file_size => -s $file,
        modified => (stat($file))[9],
    };
}

# Find all files
find(\&find_docs, $doc_base);
find(\&find_code, $code_base);

# Build mappings (naive - based on filename matching)
# A doc "Foo.tt" maps to code "Foo.pm" if basenames match
foreach my $doc_name (sort keys %doc_files) {
    my $found = 0;
    
    # Direct match
    if (exists $code_files{$doc_name}) {
        $mappings{$doc_name} = {
            doc_file => $doc_files{$doc_name},
            code_files => [$code_files{$doc_name}],
            mapping_type => 'direct_match',
        };
        $found = 1;
    }
    
    # If not found, mark as unmapped doc
    unless ($found) {
        $unmapped_docs{$doc_name} = $doc_files{$doc_name};
    }
}

# Find unmapped code files
foreach my $code_name (sort keys %code_files) {
    unless (exists $mappings{$code_name}) {
        $unmapped_code{$code_name} = $code_files{$code_name};
    }
}

# Calculate statistics
my $now = DateTime->now();
my $audit_data = {
    metadata => {
        version => "2.00",
        generated_at => $now->iso8601() . 'Z',
        generated_by => 'comprehensive_documentation_audit.pl',
        purpose => 'Complete bidirectional code-to-documentation mapping with unmapped file identification',
        scope => 'All .pm (code) and .tt (documentation) files in Comserv application',
    },
    
    summary => {
        total_documentation_files => scalar(keys %doc_files),
        total_code_files => scalar(keys %code_files),
        mapped_pairs => scalar(keys %mappings),
        unmapped_documentation_files => scalar(keys %unmapped_docs),
        unmapped_code_files => scalar(keys %unmapped_code),
        documentation_coverage_percent => scalar(keys %doc_files) > 0 
            ? sprintf("%.1f", scalar(keys %mappings) / scalar(keys %code_files) * 100)
            : 0,
    },
    
    mapped_documentation => {
        description => 'Documentation files with direct code file mappings (one-to-one matches)',
        count => scalar(keys %mappings),
        files => \%mappings,
    },
    
    unmapped_documentation => {
        description => 'Documentation files without direct code file mappings - may document multiple files, frameworks, or concepts',
        count => scalar(keys %unmapped_docs),
        files => \%unmapped_docs,
        categories => {},
    },
    
    unmapped_code => {
        description => 'Code files without dedicated documentation - may be documented in broader files or missing docs',
        count => scalar(keys %unmapped_code),
        files => \%unmapped_code,
        by_type => {},
    },
    
    statistics_by_type => {
        controllers => {
            total => scalar(grep { $_->{type} eq 'controller' } values %code_files),
            documented => scalar(grep { exists $mappings{$_} && $code_files{$_}->{type} eq 'controller' } keys %code_files),
        },
        models => {
            total => scalar(grep { $_->{type} eq 'model' } values %code_files),
            documented => scalar(grep { exists $mappings{$_} && $code_files{$_}->{type} eq 'model' } keys %code_files),
        },
        utilities => {
            total => scalar(grep { $_->{type} eq 'utility' } values %code_files),
            documented => scalar(grep { exists $mappings{$_} && $code_files{$_}->{type} eq 'utility' } keys %code_files),
        },
        other => {
            total => scalar(grep { $_->{type} eq 'other' } values %code_files),
            documented => scalar(grep { exists $mappings{$_} && $code_files{$_}->{type} eq 'other' } keys %code_files),
        },
    },
    
    recommendations => {
        immediate => [
            "Create documentation for " . scalar(keys %unmapped_code) . " code files currently without dedicated docs",
            "Review " . scalar(keys %unmapped_docs) . " documentation files to categorize their purpose and relationships",
            "Establish mapping rules for multi-to-multi relationships (one doc covering many code files)",
        ],
        next_steps => [
            "Build bidirectional relationship index showing which docs cover which code",
            "Implement content-based audit (read docs and code to verify accuracy)",
            "Create missing documentation for high-priority unmapped code files",
        ],
    },
};

# Categorize unmapped docs
foreach my $doc_name (keys %unmapped_docs) {
    my $cat = $unmapped_docs{$doc_name}->{category};
    $audit_data->{unmapped_documentation}->{categories}->{$cat} //= [];
    push @{$audit_data->{unmapped_documentation}->{categories}->{$cat}}, $doc_name;
}

# Categorize unmapped code by type
foreach my $code_name (keys %unmapped_code) {
    my $type = $unmapped_code{$code_name}->{type};
    $audit_data->{unmapped_code}->{by_type}->{$type} //= [];
    push @{$audit_data->{unmapped_code}->{by_type}->{$type}}, $code_name;
}

# Output as JSON
my $output_file = "$base_path/Comserv/root/Documentation/session_history/COMPREHENSIVE_DOCUMENTATION_AUDIT.json";
open my $fh, '>', $output_file or die "Cannot write $output_file: $!";
print $fh JSON::MaybeXS->new(pretty => 1, canonical => 1)->encode($audit_data);
close $fh;

print "✅ Comprehensive Documentation Audit Complete\n";
printf "   Total documentation files: %d\n", $audit_data->{summary}->{total_documentation_files};
printf "   Total code files: %d\n", $audit_data->{summary}->{total_code_files};
printf "   Mapped (one-to-one): %d\n", $audit_data->{summary}->{mapped_pairs};
printf "   Unmapped documentation: %d\n", $audit_data->{summary}->{unmapped_documentation_files};
printf "   Unmapped code: %d\n", $audit_data->{summary}->{unmapped_code_files};
printf "   Documentation coverage: %s%%\n", $audit_data->{summary}->{documentation_coverage_percent};
print "   Output file: $output_file\n";
