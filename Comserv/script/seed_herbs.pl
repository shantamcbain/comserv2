#!/usr/bin/env perl
#
# seed_herbs.pl — Import legacy USBM herb .htm pages into ency_herb_tb (Forager DB)
# Cross-links constituents, medical conditions, and reference books into Ency DB.
#
# Usage:
#   perl Comserv/script/seed_herbs.pl [--dry-run] [--verbose] [--force]
#
# --dry-run : parse and report without writing to DB
# --verbose : show field-level detail for each herb
# --force   : overwrite existing records (matched by botanical_name)
#
# Prerequisites (admin must run schema compare first):
#   Forager DB : ency_herb_tb  (already exists)
#   Ency DB    : ency_constituent_tb, herb_constituent, herb_disease, reference
#                (new tables from Steps 2-4 — must be created before running seeder)
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
my $FORCE   = grep { /--force/   } @ARGV;

my $LEGACY_DIR = "$Bin/../root/LegacyStaticPages/ency";

my $DB_HOST = '192.168.1.198';
my $DB_USER = 'shanta_forager';
my $DB_PASS = 'UA=nPF8*m+T#';

print "=== USBM Herb Seeder ===\n";
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

# ── Pre-seed the known reference books ─────────────────────────────────────
my %REF_BOOKS = (
    '1'  => 'The Encyclopedia of Herbs and Herbalism',
    '2'  => 'The Herb Book',
    '3'  => 'Back to Eden',
    '4'  => 'A Modern Herbal',
    '5'  => 'Potter\'s New Cyclopaedia of Botanical Drugs',
    '6'  => 'The Herbalist',
    '7'  => 'Ginseng and Other Medical Plants',
    '8'  => 'Herbal Medicine',
    '9'  => 'The Complete Book of Herbs',
    '10' => 'Medical Herbalism',
    '27' => 'Kings Dispensatory',
    '28' => 'Indian Herbalogy of North America',
);
my %ref_id_cache;

unless ($DRY_RUN) {
    print "Pre-seeding reference books...\n";
    my $dbh = $ency->storage->dbh;
    for my $num (sort keys %REF_BOOKS) {
        my $title = $REF_BOOKS{$num};
        my ($existing_id) = $dbh->selectrow_array(
            "SELECT reference_id FROM reference WHERE reference_system = ? LIMIT 1",
            {}, $num
        );
        if ($existing_id) {
            $ref_id_cache{$num} = $existing_id;
            print "  EXISTS [$existing_id]: $title\n" if $VERBOSE;
        } else {
            eval {
                $dbh->do(
                    "INSERT INTO reference (reference_system, sitename, username_of_poster, date_time_posted) VALUES (?, ?, ?, ?)",
                    {}, $num, 'ENCY', 'seeder', scalar localtime
                );
                my $new_id = $dbh->last_insert_id(undef, undef, undef, undef);
                $ref_id_cache{$num} = $new_id;
                print "  CREATED [$new_id]: $title\n" if $VERBOSE;
            };
            warn "  Warning: could not create reference '$title': $@\n" if $@;
        }
    }
    print "\n";
}

# ── Find individual herb .htm files ────────────────────────────────────────
my @herb_files = sort grep {
    $_ !~ /usbmf\d|usbmherb|usbmformula|usbmhl\.htm|usbmgg\.htm|usbm9\.htm|usbman\.htm|usbmarl\.htm/
} glob("$LEGACY_DIR/usbm*.htm");

print "Found " . scalar(@herb_files) . " herb files to process.\n\n";

my ($imported, $updated, $skipped, $errors) = (0, 0, 0, 0);

for my $file (@herb_files) {
    my $filename = (split '/', $file)[-1];
    my $parsed   = parse_herb_htm($file);

    unless ($parsed && $parsed->{botanical_name}) {
        print "SKIP (no botanical name): $filename\n";
        $skipped++;
        next;
    }

    my $label = "$parsed->{botanical_name} / $parsed->{common_names}";
    $label = substr($label, 0, 80);
    print "Processing $filename: $label\n";

    if ($DRY_RUN) {
        print "  [DRY RUN] Would import: " . join(', ',
            map { "$_=" . substr($parsed->{$_}//'',0,40) }
            qw(botanical_name common_names parts_used)
        ) . "\n";
        print "  Constituents: " . join(', ', @{$parsed->{constituent_list}}[0..4]) . "\n"
            if @{$parsed->{constituent_list}};
        print "  Medical conditions: " . join(', ', @{$parsed->{condition_list}}[0..4]) . "\n"
            if @{$parsed->{condition_list}};
        print "  Formula refs: " . join(', ', @{$parsed->{formula_refs}}[0..4]) . "\n"
            if @{$parsed->{formula_refs}};
        $imported++;
        next;
    }

    eval {
        # ── Find or create herb record ──────────────────────────────────────
        my $existing = $forager->resultset('Herb')->search(
            { botanical_name => { like => '%' . $parsed->{botanical_name} . '%' } },
            { rows => 1, order_by => 'record_id' }
        )->first;

        my $herb;
        my $herb_data = build_herb_data($parsed);

        if ($existing && !$FORCE) {
            print "  SKIP herb (exists, use --force): $parsed->{botanical_name}\n";
            $herb = $existing;
            $skipped++;
        } elsif ($existing && $FORCE) {
            $existing->update($herb_data);
            $herb = $existing;
            print "  UPDATED herb: $parsed->{botanical_name}\n";
            $updated++;
        } else {
            $herb = $forager->resultset('Herb')->create($herb_data);
            print "  CREATED herb: $parsed->{botanical_name} [id=" . $herb->record_id . "]\n";
            $imported++;
        }

        my $herb_id = $herb->record_id;

        # ── Link constituents ───────────────────────────────────────────────
        my $const_count = 0;
        for my $cname (@{$parsed->{constituent_list}}) {
            next unless $cname && length($cname) > 2;
            my $constituent = find_or_create_constituent($ency, $cname, $parsed->{botanical_name});
            next unless $constituent;
            my $exists = $ency->resultset('HerbConstituent')->search({
                herb_id        => $herb_id,
                constituent_id => $constituent->record_id,
                plant_part     => '',
            }, { rows => 1, order_by => 'id' })->first;
            unless ($exists) {
                $ency->resultset('HerbConstituent')->create({
                    herb_id        => $herb_id,
                    constituent_id => $constituent->record_id,
                    plant_part     => '',
                    notes          => "Extracted from $filename",
                });
                $const_count++;
            }
        }
        print "  Linked $const_count constituents\n" if $const_count;

        # ── Link medical conditions → diseases ──────────────────────────────
        my $disease_count = 0;
        for my $cond (@{$parsed->{condition_list}}) {
            next unless $cond && length($cond) > 3;
            my $disease = $ency->resultset('Disease')->search(
                { -or => [
                    common_name    => { like => "%$cond%" },
                    scientific_name => { like => "%$cond%" },
                ]},
                { rows => 1, order_by => 'record_id' }
            )->first;
            next unless $disease;
            my $exists = $ency->resultset('HerbDisease')->search({
                herb_id   => $herb_id,
                disease_id => $disease->record_id,
            }, { rows => 1, order_by => 'id' })->first;
            unless ($exists) {
                $ency->resultset('HerbDisease')->create({
                    herb_id           => $herb_id,
                    disease_id        => $disease->record_id,
                    relationship_type => 'treats',
                    evidence_level    => 'traditional',
                    notes             => "From USBM legacy herb page",
                });
                $disease_count++;
            }
        }
        print "  Linked $disease_count diseases\n" if $disease_count;

        # ── Update formula back-references ──────────────────────────────────
        # Formula seeder runs separately; the formulas field (raw text) is
        # already stored in the herb record. The formula seeder's find_herb_by_name
        # will find this herb and link it from the formula side.
        if ($VERBOSE && @{$parsed->{formula_refs}}) {
            print "  Formula cross-refs: " . join(', ', @{$parsed->{formula_refs}}) . "\n";
        }
    };
    if ($@) {
        print "  ERROR: $@\n";
        $errors++;
    }
}

print "\n=== Done: $imported inserted, $updated updated, $skipped skipped, $errors errors ===\n";

# ── Subroutines ─────────────────────────────────────────────────────────────

sub parse_herb_htm {
    my ($file) = @_;
    local $/;
    open(my $fh, '<', $file) or return undef;
    my $html = <$fh>;
    close $fh;

    $html =~ s/<!--.*?-->//gs;
    $html =~ s/<script[^>]*>.*?<\/script>//gsi;
    $html =~ s/<applet[^>]*>.*?<\/applet>//gsi;
    $html =~ s/<style[^>]*>.*?<\/style>//gsi;
    $html =~ s/<[^>]+>//g;
    $html =~ s/&amp;/&/g;
    $html =~ s/&nbsp;/ /g;
    $html =~ s/&#(\d+);/chr($1)/ge;
    $html =~ s/\x{c2}\x{a9}/©/g;

    my @lines = grep { /\S/ && length($_) > 1 }
                map  { s/^\s+//; s/\s+$//; $_ }
                split /\n/, $html;

    # Filter boilerplate
    @lines = grep {
        $_ !~ /web\.archive|wombat|RufflePlayer|__wm|_static|
                {font=|{align=|{size=|{enter=|{exit=|{pause=|{textColor=|{effect=|
                {url=|{bgI|{bgE|param\s+name=|value="|applet|CoffeeCup|
                ComServ|WebMaster|dateMod|document\.|window\.|Copyright/xi
    } @lines;

    # Find start of herb content — require colon to distinguish nav link from section header
    my $start = 0;
    for my $i (0..$#lines) {
        if ($lines[$i] =~ /^BOTANICAL\s+NAMES?\s*:/i) { $start = $i; last; }
    }
    # If no uppercase colon form found, skip this file
    return undef unless $start;
    @lines = @lines[$start..$#lines];

    my %herb = (
        botanical_name   => '', common_names     => '', pharmacopeial    => '',
        ident_character  => '', stem             => '', leaves           => '',
        flowers          => '', root             => '', fruit            => '',
        taste            => '', odour            => '', distribution     => '',
        parts_used       => '', body_parts       => '', constituents     => '',
        solvents         => '', therapeutic_action => '', medical_uses   => '',
        homiopathic      => '', chinese          => '', contra_indications => '',
        preparation      => '', dosage           => '', administration   => '',
        notes            => '', formulas         => '', congenial        => '',
        vetrinary        => '', non_med          => '', culinary         => '',
        cultivation      => '', sister_plants    => '', history          => '',
        harvest          => '', reference        => '',
        constituent_list => [], condition_list   => [], formula_refs     => [],
    );

    my %section_map = (
        'BOTANICAL NAMES?'              => 'botanical_name',
        'COMMON NAMES?'                 => 'common_names',
        'PHARMACOPEIAL NAMES?'          => 'pharmacopeial',
        'IDENTIFYING CHARACTERISTICS?'  => 'ident_character',
        'STEM'                          => 'stem',
        'LEAVES?'                       => 'leaves',
        'FLOWERS?'                      => 'flowers',
        'ROOT'                          => 'root',
        'FRUIT'                         => 'fruit',
        'TASTE'                         => 'taste',
        'ODOUR'                         => 'odour',
        'DISTRIBUTION'                  => 'distribution',
        'PARTS USED'                    => 'parts_used',
        'BODY PARTS AFFECTED'           => 'body_parts',
        'CONSTITUENTS?'                 => 'constituents',
        'SOLVENTS?'                     => 'solvents',
        'THERAPEUTIC ACTIONS?'          => 'therapeutic_action',
        'ASTROLOGICAL'                  => undef,
        'NUMEROLOGICAL'                 => undef,
        'MEDICAL USES'                  => 'medical_uses',
        'HOMEO?PATHIC'                  => 'homiopathic',
        'CHINESE'                       => 'chinese',
        'CONTRA[-\s]INDICATIONS?'       => 'contra_indications',
        'PREPARATION'                   => 'preparation',
        'DOSAGE'                        => 'dosage',
        'ADMINISTRATIONS?'              => 'administration',
        'NOTES?'                        => 'notes',
        'FORMULAS?'                     => 'formulas',
        'CONGENIAL COMBINATIONS?'       => 'congenial',
        'VETERIN?ARY'                   => 'vetrinary',
        'NON[-\s]MED(?:ICAL)? USES?'   => 'non_med',
        'CULINARY'                      => 'culinary',
        'CULTIVATION'                   => 'cultivation',
        'SISTER PLANTS?'                => 'sister_plants',
        'HISTORY'                       => 'history',
        'HARVEST'                       => 'harvest',
        'REFERENCE'                     => 'reference',
    );

    my $current_field = undef;

    LINE: for my $line (@lines) {
        # Stop at footer
        last if $line =~ /^ENCY Home Page|^What's New at ENCY|^ComServ\.|^Copyright/i;
        # Check if line starts a new section (must have colon to avoid nav-bar false positives)
        for my $pat_key (keys %section_map) {
            if ($line =~ /^($pat_key)\s*:(.*)?$/i) {
                my $rest = $2 // '';
                $rest =~ s/^\s+//;
                $current_field = $section_map{$pat_key};
                if (defined $current_field && $rest =~ /\S/) {
                    $herb{$current_field} .= ($herb{$current_field} ? ' ' : '') . $rest;
                }
                next LINE;
            }
        }
        # Append to current field
        if (defined $current_field && $line =~ /\S/) {
            $herb{$current_field} .= ($herb{$current_field} ? ' ' : '') . $line;
        }
    }

    # ── Clean up botanical_name (take first; handle "Genus species; Alias")
    $herb{botanical_name} =~ s/;.*$//;
    $herb{botanical_name} =~ s/^\s+|\s+$//g;
    $herb{botanical_name} = substr($herb{botanical_name}, 0, 500);

    # ── Clean common_names
    $herb{common_names} =~ s/^\s+|\s+$//g;

    # ── Parse constituent list from raw constituents text
    if ($herb{constituents} =~ /\S/) {
        my @raw = split /[;,]/, $herb{constituents};
        @{$herb{constituent_list}} = grep { /\S/ && length($_) > 2 }
                                     map  { s/^\s+//; s/\s+$//; s/\s+/ /g; $_ }
                                     @raw;
    }

    # ── Parse medical conditions from medical_uses text
    if ($herb{medical_uses} =~ /\S/) {
        my @raw = split /[.;,\n]/, $herb{medical_uses};
        @{$herb{condition_list}} = grep { /\S/ && length($_) > 3 && !/^\d+$/ }
                                   map  { s/^\s+//; s/\s+$//; s/\s+/ /g;
                                          s/\s*[\(\),]+\s*.*$//; $_ }
                                   @raw;
        # Deduplicate
        my %seen;
        @{$herb{condition_list}} = grep { !$seen{lc $_}++ } @{$herb{condition_list}};
    }

    # ── Parse formula cross-references (split on each "Formula #NN" occurrence)
    while ($herb{formulas} =~ /Formula\s+#?\s*0*(\d+)\s+([^F]*?)(?=Formula\s+#|\z)/gi) {
        my ($num, $title) = ($1, $2);
        $title =~ s/\s+/ /g; $title =~ s/^\s+|\s+$//g;
        push @{$herb{formula_refs}}, "Formula #$num $title";
    }

    # ── Parse reference numbers and map to known books
    while ($herb{reference} =~ /\(?(\d+)\)?/g) {
        my $num = $1;
        $herb{"ref_$num"} = $REF_BOOKS{$num} if $REF_BOOKS{$num};
    }
    # Also capture "Indian Herbalogy" style un-numbered refs
    if ($herb{reference} =~ /Indian Herbalogy/i) { $herb{ref_28} = $REF_BOOKS{28}; }
    if ($herb{reference} =~ /Kings? Dispensat/i)  { $herb{ref_27} = $REF_BOOKS{27}; }

    return \%herb;
}

sub clean_text {
    my ($s) = @_;
    return '' unless defined $s;
    $s =~ s/[^\x00-\x7F]/?/g;
    return $s;
}

sub build_herb_data {
    my ($p) = @_;
    $p = { map { $_ => clean_text($p->{$_}) } keys %$p };
    return {
        botanical_name     => $p->{botanical_name}    || '',
        common_names       => substr($p->{common_names}      || '', 0, 1000),
        ident_character    => $p->{ident_character}   || '',
        stem               => $p->{stem}              || '',
        leaves             => $p->{leaves}            || '',
        flowers            => substr($p->{flowers}    || '', 0, 1000),
        root               => $p->{root}              || '',
        fruit              => $p->{fruit}             || '',
        taste              => $p->{taste}             || '',
        odour              => substr($p->{odour}      || '', 0, 100),
        distribution       => substr($p->{distribution} || '', 0, 1000),
        parts_used         => $p->{parts_used}        || '',
        constituents       => $p->{constituents}      || '',
        solvents           => substr($p->{solvents}   || '', 0, 100),
        therapeutic_action => substr($p->{therapeutic_action}|| '', 0, 250),
        medical_uses       => $p->{medical_uses}      || '',
        homiopathic        => $p->{homiopathic}       || '',
        chinese            => $p->{chinese}           || '',
        contra_indications => substr($p->{contra_indications}|| '', 0, 150),
        preparation        => substr($p->{preparation}|| '', 0, 150),
        dosage             => $p->{dosage}            || '',
        administration     => $p->{administration}    || '',
        comments           => $p->{notes}             || '',
        formulas           => $p->{formulas}          || '',
        vetrinary          => $p->{vetrinary}         || '',
        non_med            => $p->{non_med}           || '',
        culinary           => substr($p->{culinary}   || '', 0, 500),
        cultivation        => $p->{cultivation}       || '',
        sister_plants      => substr($p->{sister_plants} || '', 0, 100),
        history            => $p->{history}           || '',
        harvest            => $p->{harvest}           || '',
        reference          => $p->{reference}         || '',
        url                => '',
        username_of_poster => 'seeder',
        group_of_poster    => 'admin',
        date_time_posted   => scalar localtime,
        share              => 0,
        pollennotes        => '',
        nectarnotes        => '',
        apis               => '',
        pollinator         => '',
        nectar             => 0,
        pollen             => 0,
    };
}

sub find_or_create_constituent {
    my ($ency_schema, $name, $herb_name) = @_;
    $name =~ s/^\s+|\s+$//g;
    $name = substr($name, 0, 255);
    return undef unless length($name) > 2;

    my $constituent;
    eval {
        $constituent = $ency_schema->resultset('Constituent')->search(
            { name => { like => $name } }, { rows => 1, order_by => 'record_id' }
        )->first;
    } or do {};

    unless ($constituent) {
        eval {
            $constituent = $ency_schema->resultset('Constituent')->create({
                name               => $name,
                found_in_herbs     => $herb_name,
                sitename           => 'ENCY',
                username_of_poster => 'seeder',
                date_time_posted   => scalar localtime,
                share              => 0,
            });
        };
        if ($@) {
            warn "  Warning: could not create constituent '$name': $@\n";
            return undef;
        }
    }
    return $constituent;
}
