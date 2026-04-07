#!/usr/bin/env perl
#
# migrate_ency_links.pl — Bulk migration: scan all ENCY entity records and
# create junction table links from free-text fields.
#
# For each entity, scans fields like 'therapeutic_action', 'constituents',
# 'medical_uses', etc. and matches terms against existing DB records.
# Matched terms get junction table rows; unmatched terms are logged to a
# report file (and optionally to the todo table).
#
# Usage:
#   cd Comserv && perl script/migrate_ency_links.pl [options]
#
# Options:
#   --dry-run     Show what would be linked, don't write to DB
#   --verbose     Print every term checked
#   --entity=X    Only process one entity type: herb, disease, constituent, drug
#   --todos       Also write unresolved terms to the todo table (slow)
#   --report=FILE Write CSV report to FILE (default: /tmp/ency_link_report.csv)
#
# Run from the Comserv/ directory.
#
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use lib "$Bin/../local/lib/perl5";

use Comserv::Model::Schema::Ency;
use Comserv::Model::Schema::Forager;
use POSIX qw(strftime);
use Encode qw(decode encode);

my $DRY_RUN    = grep { /--dry-run/  } @ARGV;
my $VERBOSE    = grep { /--verbose/  } @ARGV;
my $WRITE_TODOS= grep { /--todos/    } @ARGV;
my ($ENTITY)   = map  { /--entity=(.+)/ ? $1 : () } @ARGV;
my ($REPORT)   = map  { /--report=(.+)/ ? $1 : () } @ARGV;
$REPORT ||= '/tmp/ency_link_report.csv';

my $DB_HOST    = '192.168.1.198';
my $DB_USER    = 'shanta_forager';
my $DB_PASS    = 'UA=nPF8*m+T#';

printf "=== ENCY Bulk Link Migration ===\n";
printf "Mode: %s\n", $DRY_RUN ? 'DRY RUN (no DB writes)' : 'LIVE (writing to DB)';
printf "Entities: %s\n", $ENTITY || 'all';
printf "Report: %s\n\n", $REPORT;

my $ency = Comserv::Model::Schema::Ency->connect(
    "dbi:mysql:database=ency;host=$DB_HOST;port=3306",
    $DB_USER, $DB_PASS, { RaiseError => 1, AutoCommit => 1 }
) or die "Cannot connect to Ency schema\n";

my $forager = Comserv::Model::Schema::Forager->connect(
    "dbi:mysql:database=shanta_forager;host=$DB_HOST;port=3306",
    $DB_USER, $DB_PASS, { RaiseError => 1, AutoCommit => 1 }
) or die "Cannot connect to Forager schema\n";

my %STOP = map { lc($_) => 1 }
    qw(and or the a an of in on at to with for by from as is are was were be been being
       have has had do does did will would could should may might shall can not no nor but
       if then than also both either neither used known found common plants herbs diseases
       symptoms include including such eg ie etc may also both types type form forms);

# ---- Field mapping: entity_type => field_name => { schema, resultset, fields, junction }
my %FIELD_MAP = (
    herb => {
        constituents      => { schema=>'ency',    rs=>'Constituent', fields=>['name','common_name'], junction=>'HerbConstituent',  fk_self=>'herb_id',        fk_other=>'constituent_id' },
        therapeutic_action=> { schema=>'ency',    rs=>'Glossary',    fields=>['term'],               junction=>undef },
        medical_uses      => { schema=>'ency',    rs=>'Disease',     fields=>['common_name'],        junction=>'HerbDisease',       fk_self=>'herb_id',        fk_other=>'disease_id' },
        sister_plants     => { schema=>'forager', rs=>'Herb',        fields=>['botanical_name','common_names'], junction=>undef },
    },
    disease => {
        symptoms_description => { schema=>'ency', rs=>'Symptom',    fields=>['name','common_name'], junction=>'DiseaseSymptom',   fk_self=>'disease_id',     fk_other=>'symptom_id' },
        treatment_herbal     => { schema=>'ency', rs=>'Glossary',   fields=>['term'],               junction=>undef },
    },
    constituent => {
        found_in_herbs     => { schema=>'forager', rs=>'Herb',       fields=>['botanical_name','common_names'], junction=>'HerbConstituent', fk_self=>'constituent_id', fk_other=>'herb_id' },
        therapeutic_action => { schema=>'ency',    rs=>'Glossary',   fields=>['term'],               junction=>undef },
        pharmacological_effects => { schema=>'ency', rs=>'Glossary', fields=>['term'],               junction=>undef },
    },
    drug => {
        indications        => { schema=>'ency',    rs=>'Disease',    fields=>['common_name'],        junction=>'DrugDisease',      fk_self=>'drug_id',        fk_other=>'disease_id' },
        active_ingredients => { schema=>'ency',    rs=>'Constituent',fields=>['name','common_name'], junction=>'DrugConstituent',  fk_self=>'drug_id',        fk_other=>'constituent_id' },
        side_effects       => { schema=>'ency',    rs=>'Symptom',    fields=>['name','common_name'], junction=>'DrugSymptom',      fk_self=>'drug_id',        fk_other=>'symptom_id' },
    },
);

my %ENTITY_RS = (
    herb        => { schema=>'forager', rs=>'Herb',        pk=>'record_id', name_col=>'botanical_name' },
    disease     => { schema=>'ency',    rs=>'Disease',     pk=>'record_id', name_col=>'common_name' },
    constituent => { schema=>'ency',    rs=>'Constituent', pk=>'record_id', name_col=>'name' },
    drug        => { schema=>'ency',    rs=>'Drug',        pk=>'record_id', name_col=>'generic_name' },
);

# Stats
my %stats = ( linked=>0, skipped_dup=>0, unresolved=>0, errors=>0, records=>0 );
my @unresolved_log;

open my $RPT, '>', $REPORT or die "Cannot write report to $REPORT: $!";
print $RPT "entity_type,entity_id,entity_name,field,term,status,junction\n";

sub schema_for { $_[0] eq 'ency' ? $ency : $forager }

sub parse_terms {
    my ($text) = @_;
    return () unless defined $text && length($text) > 2;
    my @raw = split /[,;\n\r|\/]+/, $text;
    my @terms;
    for my $t (@raw) {
        $t =~ s/^\s+|\s+$//g;
        $t =~ s/\s*\(.*//;
        $t =~ s/\d+\s*$//;
        $t =~ s/^\d+\s*//;
        next if length($t) < 3;
        next if $STOP{lc($t)};
        next if $t =~ /^\d+(\.\d+)?$/;
        push @terms, $t;
    }
    return @terms;
}

sub find_record {
    my ($schema_name, $rs_name, $fields, $term) = @_;
    my $schema = schema_for($schema_name);
    for my $col (@$fields) {
        my $rec = eval {
            $schema->resultset($rs_name)->search(
                { $col => { like => "%$term%" } },
                { rows => 1, order_by => 'record_id' }
            )->first;
        };
        return $rec if $rec;
    }
    return undef;
}

sub try_link {
    my ($junction_rs, $fk_self, $id_self, $fk_other, $id_other) = @_;
    return 0 unless $junction_rs;
    my $existing = eval {
        $ency->resultset($junction_rs)->find({ $fk_self => $id_self, $fk_other => $id_other });
    };
    if ($existing) {
        $stats{skipped_dup}++;
        return -1; # duplicate
    }
    unless ($DRY_RUN) {
        eval {
            $ency->resultset($junction_rs)->create({ $fk_self => $id_self, $fk_other => $id_other });
        };
        if ($@) {
            warn "  ERROR linking $junction_rs ($fk_self=$id_self, $fk_other=$id_other): $@\n";
            $stats{errors}++;
            return 0;
        }
    }
    $stats{linked}++;
    return 1;
}

my @entities_to_process = $ENTITY ? ($ENTITY) : qw(herb disease constituent drug);

for my $entity_type (@entities_to_process) {
    my $ent_cfg = $ENTITY_RS{$entity_type} or do { warn "Unknown entity: $entity_type\n"; next };
    my $field_cfg = $FIELD_MAP{$entity_type} or next;

    printf "\n--- Processing %ss ---\n", ucfirst($entity_type);

    my $schema    = schema_for($ent_cfg->{schema});
    my @records   = eval { $schema->resultset($ent_cfg->{rs})->all };
    if ($@) { warn "Cannot fetch $entity_type records: $@\n"; next }

    printf "  Found %d %s records\n", scalar(@records), $entity_type;

    for my $rec (@records) {
        $stats{records}++;
        my $id   = $rec->get_column($ent_cfg->{pk});
        my $name = eval { $rec->get_column($ent_cfg->{name_col}) } || "id=$id";
        printf "  [%s #%s] %s\n", $entity_type, $id, $name if $VERBOSE;

        while (my ($field, $cfg) = each %$field_cfg) {
            my $text = eval { $rec->get_column($field) };
            next unless defined $text && $text =~ /\S/;

            my @terms = parse_terms($text);
            for my $term (@terms) {
                printf "    checking %-30s → %s\n", "$field:", $term if $VERBOSE;

                my $found = find_record($cfg->{schema}, $cfg->{rs}, $cfg->{fields}, $term);

                if ($found) {
                    my $other_id = $found->get_column('record_id');
                    if ($cfg->{junction}) {
                        my $result = try_link($cfg->{junction}, $cfg->{fk_self}, $id, $cfg->{fk_other}, $other_id);
                        if ($result == 1) {
                            printf "    LINKED: %s #%s ↔ %s #%s via %s\n",
                                $entity_type, $id, $cfg->{rs}, $other_id, $cfg->{junction} if $VERBOSE;
                            print $RPT "$entity_type,$id,\"$name\",$field,\"$term\",linked,$cfg->{junction}\n";
                        } elsif ($result == -1) {
                            print $RPT "$entity_type,$id,\"$name\",$field,\"$term\",duplicate,$cfg->{junction}\n";
                        }
                    } else {
                        printf "    FOUND (no junction): %s '%s' matches %s #%s\n",
                            $field, $term, $cfg->{rs}, $other_id if $VERBOSE;
                        print $RPT "$entity_type,$id,\"$name\",$field,\"$term\",found_no_junction,none\n";
                    }
                } else {
                    $stats{unresolved}++;
                    printf "    UNRESOLVED: %s '%s'\n", $field, $term if $VERBOSE;
                    print $RPT "$entity_type,$id,\"$name\",$field,\"$term\",unresolved,none\n";
                    push @unresolved_log, {
                        entity_type => $entity_type,
                        entity_id   => $id,
                        entity_name => $name,
                        field       => $field,
                        term        => $term,
                        rs          => $cfg->{rs},
                    };
                }
            }
        }
    }
}

close $RPT;

printf "\n=== Migration Complete ===\n";
printf "Records processed : %d\n", $stats{records};
printf "Junctions created : %d%s\n", $stats{linked},      $DRY_RUN ? ' (dry run)' : '';
printf "Duplicates skipped: %d\n", $stats{skipped_dup};
printf "Unresolved terms  : %d\n", $stats{unresolved};
printf "Errors            : %d\n", $stats{errors};
printf "Report written to : %s\n", $REPORT;

if (@unresolved_log) {
    printf "\n=== Unresolved Terms (need new records) ===\n";
    printf "%-12s %-6s %-25s %-22s %-30s %-15s\n",
        'Entity', 'ID', 'Name', 'Field', 'Term', 'Missing Table';
    printf "%s\n", '-' x 115;
    my %seen;
    for my $u (sort { $a->{entity_type} cmp $b->{entity_type} || $a->{term} cmp $b->{term} } @unresolved_log) {
        my $key = "$u->{rs}:$u->{term}";
        next if $seen{$key}++;
        printf "%-12s %-6s %-25s %-22s %-30s %-15s\n",
            $u->{entity_type}, $u->{entity_id},
            substr($u->{entity_name}, 0, 24),
            $u->{field},
            substr($u->{term}, 0, 29),
            $u->{rs};
    }

    my %_uniq;
    $_uniq{"$_->{rs}:$_->{term}"} = 1 for @unresolved_log;
    printf "\n%d unique unresolved terms need new records.\n", scalar keys %_uniq;
    printf "Next step: run  perl script/ai_draft_unresolved.pl --report=%s\n", $REPORT;
    printf "to have AI create draft records for each unresolved term.\n";
}

printf "\nDone.\n";
