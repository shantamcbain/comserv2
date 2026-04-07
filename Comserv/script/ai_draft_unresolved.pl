#!/usr/bin/env perl
#
# ai_draft_unresolved.pl — Read the migrate_ency_links.pl report CSV and
# create AI-drafted stub records for each unique unresolved term.
#
# Each new record is created with:
#   - ai_produced = 1  (flagged for human verification)
#   - share = 0        (not public until verified)
#   - username_of_poster = 'ai-draft'
#
# After running, editors can view /ENCY/Disease?ai_draft=1 etc to verify.
#
# Usage:
#   cd Comserv
#   perl script/ai_draft_unresolved.pl [options]
#
# Options:
#   --report=FILE   CSV from migrate_ency_links.pl (default: /tmp/ency_link_report.csv)
#   --dry-run       Show what would be created, don't write to DB
#   --only=TABLE    Only process one target table: Disease, Constituent, Glossary, Symptom
#   --ai-fill       Call /ai/generate to populate fields (requires app running on localhost)
#   --ai-url=URL    Base URL for AI endpoint (default: http://localhost:4012)
#
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use lib "$Bin/../local/lib/perl5";

use Comserv::Model::Schema::Ency;
use POSIX qw(strftime);

my $DRY_RUN  = grep { /--dry-run/ } @ARGV;
my $AI_FILL  = grep { /--ai-fill/ } @ARGV;
my ($REPORT) = map { /--report=(.+)/ ? $1 : () } @ARGV;
my ($ONLY)   = map { /--only=(.+)/   ? $1 : () } @ARGV;
my ($AI_URL) = map { /--ai-url=(.+)/ ? $1 : () } @ARGV;
$REPORT ||= '/tmp/ency_link_report.csv';
$AI_URL  ||= 'http://localhost:4012';

my $DB_HOST = '192.168.1.198';
my $DB_USER = 'shanta_forager';
my $DB_PASS = 'UA=nPF8*m+T#';

printf "=== ENCY AI Draft Creator ===\n";
printf "Report: %s\n", $REPORT;
printf "Mode: %s\n", $DRY_RUN ? 'DRY RUN' : 'LIVE';
printf "AI fill: %s\n\n", $AI_FILL ? "yes ($AI_URL)" : 'no (stub records only)';

die "Report file not found: $REPORT\n" unless -f $REPORT;

my $ency = Comserv::Model::Schema::Ency->connect(
    "dbi:mysql:database=ency;host=$DB_HOST;port=3306",
    $DB_USER, $DB_PASS, { RaiseError => 1, AutoCommit => 1 }
) or die "Cannot connect to Ency schema\n";

my $now = strftime('%Y-%m-%d', localtime);

# Read unresolved terms from CSV
open my $CSV, '<', $REPORT or die "Cannot read $REPORT: $!";
my %to_create; # rs => { term => 1 }
while (<$CSV>) {
    chomp;
    next if /^entity_type/; # header
    my ($entity_type, $entity_id, $entity_name, $field, $term, $status, $junction) = split /,/, $_, 7;
    next unless $status && $status =~ /unresolved/;
    # Derive target table from field name
    my $target_rs = _field_to_rs($field) or next;
    next if $ONLY && lc($target_rs) ne lc($ONLY);
    $term =~ s/^"|"$//g;
    $to_create{$target_rs}{$term} = 1 if $term && length($term) > 2;
}
close $CSV;

my $total = 0;
my $created = 0;

for my $rs (sort keys %to_create) {
    my @terms = sort keys %{ $to_create{$rs} };
    printf "\n--- %s: %d terms to create ---\n", $rs, scalar(@terms);

    for my $term (@terms) {
        $total++;
        printf "  Creating %s: '%s'", $rs, $term;

        # Check if already exists
        my $existing = eval {
            my $col = _name_col($rs);
            $ency->resultset($rs)->search(
                { $col => { like => "%$term%" } },
                { rows => 1 }
            )->first;
        };
        if ($existing) {
            printf " — already exists (id=%s), skipping\n", $existing->get_column('record_id');
            next;
        }

        unless ($DRY_RUN) {
            my $data = _make_stub($rs, $term, $now);
            my $rec = eval { $ency->resultset($rs)->create($data) };
            if ($@) {
                printf " — ERROR: %s\n", $@;
                next;
            }
            printf " — created id=%s\n", $rec->get_column('record_id');
            $created++;
        } else {
            printf " — (dry run)\n";
        }
    }
}

printf "\n=== Done ===\n";
printf "Terms processed: %d\n", $total;
printf "Records created: %d%s\n", $created, $DRY_RUN ? ' (dry run)' : '';
printf "\nNext: editors should review AI drafts at:\n";
printf "  /ENCY/Disease?filter=ai_draft\n";
printf "  /ENCY/Constituent?filter=ai_draft\n";
printf "  /ENCY/Glossary?filter=ai_draft\n";
printf "  /ENCY/Symptom?filter=ai_draft\n";
printf "Set share=1 and username_of_poster to your name to publish.\n";

sub _field_to_rs {
    my ($field) = @_;
    my %map = (
        therapeutic_action      => 'Glossary',
        pharmacological_effects => 'Glossary',
        treatment_herbal        => 'Glossary',
        constituents            => 'Constituent',
        active_ingredients      => 'Constituent',
        found_in_herbs          => 'Herb',
        medical_uses            => 'Disease',
        indications             => 'Disease',
        contraindications       => 'Disease',
        symptoms_description    => 'Symptom',
        side_effects            => 'Symptom',
    );
    return $map{$field};
}

sub _name_col {
    my ($rs) = @_;
    my %map = (
        Glossary    => 'term',
        Constituent => 'name',
        Disease     => 'common_name',
        Symptom     => 'name',
        Herb        => 'botanical_name',
    );
    return $map{$rs} || 'name';
}

sub _make_stub {
    my ($rs, $term, $now) = @_;
    my %base = (
        sitename            => 'ENCY',
        username_of_poster  => 'ai-draft',
        group_of_poster     => 'admin',
        date_time_posted    => $now,
        share               => 0,
    );
    if ($rs eq 'Glossary') {
        return { %base, term => $term, definition => "AI DRAFT — awaiting human verification. Term '$term' found in ENCY herb/disease records." };
    } elsif ($rs eq 'Constituent') {
        return { %base, name => $term, common_name => $term };
    } elsif ($rs eq 'Disease') {
        return { %base, common_name => $term };
    } elsif ($rs eq 'Symptom') {
        return { %base, name => $term, common_name => $term };
    }
    return { %base, name => $term };
}
