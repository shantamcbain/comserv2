#!/usr/bin/env perl
#
# seed_reference_links.pl
# Parse existing free-text `reference` fields across all ENCY entity tables.
# Find [N] patterns, match against the `reference` table by ID,
# and create ency_entity_reference junction rows for verified matches.
#
# Usage:
#   perl Comserv/script/seed_reference_links.pl [--dry-run] [--verbose]
#
# --dry-run : report matches without writing to DB
# --verbose : show each entity and matched ref IDs
#
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use lib "$Bin/../local/lib/perl5";

use Comserv::Model::Schema::Forager;
use Comserv::Model::Schema::Ency;

my $DRY_RUN = grep { /--dry-run/ } @ARGV;
my $VERBOSE = grep { /--verbose/ } @ARGV;

my $DB_HOST = '192.168.1.198';
my $DB_USER = 'shanta_forager';
my $DB_PASS = 'UA=nPF8*m+T#';

print "=== ENCY Reference Link Seeder ===\n";
print "Dry run mode\n" if $DRY_RUN;
print "\n";

my $forager = Comserv::Model::Schema::Forager->connect(
    "dbi:mysql:database=shanta_forager;host=$DB_HOST;port=3306",
    $DB_USER, $DB_PASS, { RaiseError => 1, AutoCommit => 1 }
) or die "Cannot connect to Forager schema\n";

my $ency = Comserv::Model::Schema::Ency->connect(
    "dbi:mysql:database=ency;host=$DB_HOST;port=3306",
    $DB_USER, $DB_PASS, { RaiseError => 1, AutoCommit => 1 }
) or die "Cannot connect to Ency schema\n";

print "Connected to databases ($DB_HOST).\n\n";

# Build a hash of all existing reference_ids for quick lookup
my %known_refs;
eval {
    my @all_refs = $ency->resultset('Reference')->search({}, { columns => ['reference_id'] })->all;
    $known_refs{$_->reference_id} = 1 for @all_refs;
};
if ($@) {
    die "Cannot read reference table: $@\n";
}
my $ref_count = scalar keys %known_refs;
print "Found $ref_count known reference IDs in reference table.\n\n";

# Extract all reference IDs from a free-text reference field.
# Strategies:
#   [N]        — bracket notation
#   reference N — explicit keyword
#   \bN\b       — bare 1-2 digit numbers; all our ref IDs are ≤ 38 so page numbers
#                 (100+) are automatically excluded. Two-digit numbers ≥ 39 are skipped.
sub extract_ref_ids {
    my ($text) = @_;
    return () unless defined $text && length $text;
    my %seen;

    # [N] notation
    while ($text =~ /\[(\d+)\]/g) {
        my $n = $1 + 0;
        $seen{$n} = 1 if $n >= 1 && $n <= 38;
    }

    # "reference N" or "references N" keyword
    while ($text =~ /\breferences?\s+(\d+)/gi) {
        my $n = $1 + 0;
        $seen{$n} = 1 if $n >= 1 && $n <= 38;
    }

    # Bare 1-or-2-digit numbers at word boundaries (covers "1, 2, 5" lists and "1. Title")
    # Exclude numbers that are part of larger numbers (word boundary handles this)
    while ($text =~ /\b(\d{1,2})\b/g) {
        my $n = $1 + 0;
        $seen{$n} = 1 if $n >= 1 && $n <= 38;
    }

    return keys %seen;
}

my $total_linked = 0;
my $total_skipped = 0;
my $total_errors = 0;

sub process_entities {
    my ($schema_obj, $resultset_name, $entity_type, $id_col, $ref_col) = @_;
    $ref_col ||= 'reference';
    my @entities = eval {
        $schema_obj->resultset($resultset_name)->search(
            { $ref_col => { '!=' => undef } },
            { columns => [$id_col, $ref_col] }
        )->all;
    };
    if ($@) {
        warn "  ERROR reading $resultset_name: $@\n";
        return;
    }

    print "Processing $entity_type (" . scalar(@entities) . " records with reference field)...\n";

    for my $entity (@entities) {
        my $entity_id  = $entity->$id_col;
        my $ref_text   = $entity->$ref_col // '';
        my @ref_ids    = extract_ref_ids($ref_text);
        next unless @ref_ids;

        for my $ref_id (@ref_ids) {
            unless ($known_refs{$ref_id}) {
                print "  [$entity_type #$entity_id] ref_id=$ref_id not in reference table — skipping\n" if $VERBOSE;
                $total_skipped++;
                next;
            }

            # Check if already linked
            my $existing = eval {
                $ency->resultset('EntityReference')->find({
                    entity_type  => $entity_type,
                    entity_id    => $entity_id,
                    reference_id => $ref_id,
                });
            };
            if ($existing) {
                print "  [$entity_type #$entity_id] ↔ ref#$ref_id already linked\n" if $VERBOSE;
                $total_skipped++;
                next;
            }

            print "  [$entity_type #$entity_id] ↔ ref#$ref_id\n" if $VERBOSE;

            unless ($DRY_RUN) {
                eval {
                    $ency->resultset('EntityReference')->create({
                        entity_type  => $entity_type,
                        entity_id    => $entity_id,
                        reference_id => $ref_id,
                    });
                };
                if ($@) {
                    warn "  ERROR linking [$entity_type #$entity_id] ↔ ref#$ref_id: $@\n";
                    $total_errors++;
                    next;
                }
            }
            $total_linked++;
        }
    }
    print "  Done.\n";
}

# Herb (Forager DB — record_id, reference)
process_entities($forager, 'Herb',        'herb',        'record_id', 'reference');

# Ency DB entities
process_entities($ency, 'Animal',      'animal',      'record_id', 'reference');
process_entities($ency, 'Insect',      'insect',      'record_id', 'reference');
process_entities($ency, 'Disease',     'disease',     'record_id', 'reference');
process_entities($ency, 'Symptom',     'symptom',     'record_id', 'reference');
process_entities($ency, 'Constituent', 'constituent', 'record_id', 'reference');
# Glossary has no reference field — skip
process_entities($ency, 'Drug',        'drug',        'record_id', 'reference');

print "\n=== Summary ===\n";
print "Linked  : $total_linked\n";
print "Skipped : $total_skipped\n";
print "Errors  : $total_errors\n";
print $DRY_RUN ? "(Dry run — no changes written)\n" : "Done.\n";
