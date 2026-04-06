#!/usr/bin/env perl
#
# seed_legacy_herbs.pl — Two tasks in one pass:
#   1. Clean HTML tags/entities from the 73 pre-seeder legacy herb rows in
#      shanta_forager.ency_herb_tb (originally from forager.com 2001 DB dump).
#   2. Process the two herb .htm files excluded from seed_herbs.pl:
#         usbman.htm  → Chamomile (Anthemis nobalis)
#         usbmarl.htm → Burdock  (Arctium lappa)
#
# Usage:
#   perl Comserv/script/seed_legacy_herbs.pl [--dry-run] [--verbose] [--force]
#
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use lib "$Bin/../local/lib/perl5";

use Comserv::Model::Schema::Forager;
use HTML::Entities qw(decode_entities);

my $DRY_RUN = grep { /--dry-run/ } @ARGV;
my $VERBOSE = grep { /--verbose/ } @ARGV;
my $FORCE   = grep { /--force/   } @ARGV;

my $LEGACY_DIR = "$Bin/../root/LegacyStaticPages/ency";

my $DB_HOST = '192.168.1.198';
my $DB_USER = 'shanta_forager';
my $DB_PASS = 'UA=nPF8*m+T#';

print "=== Legacy Herb Seeder ===\n";
print "Dry run mode\n" if $DRY_RUN;

my $forager = Comserv::Model::Schema::Forager->connect(
    "dbi:mysql:database=shanta_forager;host=$DB_HOST;port=3306",
    $DB_USER, $DB_PASS, { RaiseError => 1, AutoCommit => 1 }
) or die "Cannot connect to Forager schema\n";

print "Connected to $DB_HOST.\n\n";

# ── helpers ────────────────────────────────────────────────────────────────────
sub strip_html {
    my ($s) = @_;
    return '' unless defined $s;
    $s = decode_entities($s);
    $s =~ s/<[^>]+>//g;
    $s =~ s/\r?\n/ /g;
    $s =~ s/\s{2,}/ /g;
    $s =~ s/^\s+|\s+$//g;
    $s =~ s/[^\x00-\x7F]/?/g;
    return $s;
}

sub clean_text {
    my ($s) = @_;
    return '' unless defined $s;
    $s =~ s/[^\x00-\x7F]/?/g;
    $s =~ s/^\s+|\s+$//g;
    return $s;
}

# ── TASK 1: clean HTML from legacy rows ────────────────────────────────────────
print "=== Task 1: Cleaning HTML from legacy herb rows ===\n";

my @legacy = $forager->resultset('Herb')->search(
    { username_of_poster => { '!=' => 'seeder' } },
    { order_by => 'record_id' }
)->all;

print "Found " . scalar(@legacy) . " legacy rows.\n\n";

my ($cleaned, $skipped) = (0, 0);

for my $herb (@legacy) {
    my %cols = $herb->get_columns;
    my %updates;

    for my $col (qw(common_names botanical_name therapeutic_action parts_used
                    medical_uses constituents ident_character stem leaves flowers
                    root fruit taste odour distribution solvents history comments
                    contra_indications preparation dosage administration formulas
                    vetrinary non_med cultivation sister_plants harvest)) {
        next unless defined $cols{$col};
        my $orig    = $cols{$col};
        my $cleaned_val = strip_html($orig);
        $cleaned_val = substr($cleaned_val, 0, 1000) if $col eq 'common_names' || $col eq 'flowers' || $col eq 'distribution';
        $cleaned_val = substr($cleaned_val, 0, 250)  if $col eq 'therapeutic_action';
        $cleaned_val = substr($cleaned_val, 0, 150)  if $col eq 'contra_indications' || $col eq 'preparation';
        $cleaned_val = substr($cleaned_val, 0, 100)  if $col eq 'odour' || $col eq 'solvents' || $col eq 'sister_plants';
        $cleaned_val = substr($cleaned_val, 0, 500)  if $col eq 'culinary' || $col eq 'Culinary';
        if ($cleaned_val ne $orig) {
            $updates{$col} = $cleaned_val;
        }
    }

    if (%updates) {
        my $name = $cols{botanical_name} || "record_id=$cols{record_id}";
        print "  CLEAN: $name\n" if $VERBOSE;
        print "    Changed: " . join(', ', keys %updates) . "\n" if $VERBOSE;
        unless ($DRY_RUN) {
            eval { $herb->update(\%updates) };
            warn "  ERROR updating $name: $@\n" if $@;
        }
        $cleaned++;
    } else {
        print "  OK (no HTML): " . ($cols{botanical_name} || "id=$cols{record_id}") . "\n" if $VERBOSE;
        $skipped++;
    }
}

print "Task 1 done: $cleaned rows cleaned, $skipped already clean.\n\n";

# ── TASK 2: process the two excluded herb .htm files ──────────────────────────
print "=== Task 2: Importing excluded herb files (usbman.htm, usbmarl.htm) ===\n";

my @extra_files = grep { -f $_ } map { "$LEGACY_DIR/$_" } qw(usbman.htm usbmarl.htm);
print "Files found: " . scalar(@extra_files) . "\n\n";

my ($imported, $updated, $errors) = (0, 0, 0);

for my $file (@extra_files) {
    my $filename = (split '/', $file)[-1];
    my $parsed   = parse_herb_htm($file);

    unless ($parsed && $parsed->{botanical_name}) {
        print "SKIP (no botanical name): $filename\n";
        next;
    }

    my $label = "$parsed->{botanical_name} / $parsed->{common_names}";
    print "Processing $filename: " . substr($label, 0, 80) . "\n";

    if ($DRY_RUN) {
        print "  [DRY RUN] Would import: $parsed->{botanical_name}\n";
        $imported++;
        next;
    }

    eval {
        my $existing = $forager->resultset('Herb')->search(
            { botanical_name => { like => '%' . $parsed->{botanical_name} . '%' } },
            { rows => 1, order_by => 'record_id' }
        )->first;

        my $herb_data = build_herb_data($parsed);

        if ($existing && !$FORCE) {
            print "  SKIP (exists, use --force): $parsed->{botanical_name}\n";
        } elsif ($existing && $FORCE) {
            $existing->update($herb_data);
            print "  UPDATED: $parsed->{botanical_name}\n";
            $updated++;
        } else {
            $forager->resultset('Herb')->create($herb_data);
            print "  CREATED: $parsed->{botanical_name}\n";
            $imported++;
        }
    };
    if ($@) {
        warn "  ERROR: $@\n";
        $errors++;
    }
}

print "\nTask 2 done: $imported created, $updated updated, $errors errors.\n";

# ── parse_herb_htm — same logic as seed_herbs.pl ─────────────────────────────
sub parse_herb_htm {
    my ($file) = @_;
    open my $fh, '<:raw', $file or return undef;
    my $html = do { local $/; <$fh> };
    close $fh;

    my %p;
    $html =~ s/<script[^>]*>.*?<\/script>//gsi;
    $html =~ s/<!--.*?-->//gs;

    if ($html =~ /BOTANICAL NAMES?[:\s]*([^<\n;]{3,100})/i) {
        my $bn = $1;
        $bn =~ s/^\s+|\s+$//g;
        $bn =~ s/<[^>]+>//g;
        $bn = strip_html($bn);
        $p{botanical_name} = $bn if length($bn) > 2;
    }

    if ($html =~ /COMMON NAMES?[:\s]*<\/B>([^<\n]{3,200})/i ||
        $html =~ /COMMON NAMES?[:\s]*([^<\n]{3,200})/i) {
        $p{common_names} = strip_html($1);
    }

    for my $field (
        [ parts_used         => qr/PARTS?\s+USED[:\s]*([^<\n]{2,300})/i ],
        [ therapeutic_action => qr/THERAPEUTIC\s+ACTIONS?[:\s]*([^<\n]{2,300})/i ],
        [ medical_uses       => qr/MEDICAL\s+USES?[:\s]*(.*?)(?=\n\s*\n|\Z)/is ],
        [ constituents       => qr/CONSTITUENTS?[:\s]*([^<\n]{2,300})/i ],
        [ dosage             => qr/DOSAGE[:\s]*([^<\n]{2,300})/i ],
        [ preparation        => qr/PREPARATION[:\s]*([^<\n]{2,300})/i ],
        [ history            => qr/HISTORY[:\s]*(.*?)(?=\n\s*\n|\Z)/is ],
        [ distribution       => qr/DISTRIBUTION[:\s]*([^<\n]{2,300})/i ],
    ) {
        my ($key, $rx) = @$field;
        if ($html =~ $rx) {
            $p{$key} = strip_html($1);
        }
    }

    return keys(%p) ? \%p : undef;
}

sub build_herb_data {
    my ($p) = @_;
    $p = { map { $_ => clean_text($p->{$_} // '') } keys %$p };
    return {
        botanical_name     => substr($p->{botanical_name}     || '', 0, 500),
        common_names       => substr($p->{common_names}       || '', 0, 1000),
        therapeutic_action => substr($p->{therapeutic_action} || '', 0, 250),
        parts_used         => $p->{parts_used}         || '',
        medical_uses       => $p->{medical_uses}        || '',
        constituents       => $p->{constituents}        || '',
        dosage             => $p->{dosage}              || '',
        preparation        => substr($p->{preparation}  || '', 0, 150),
        history            => $p->{history}             || '',
        distribution       => substr($p->{distribution} || '', 0, 1000),
        contra_indications => '',
        administration     => '',
        ident_character    => '',
        stem               => '',
        leaves             => '',
        flowers            => '',
        root               => '',
        fruit              => '',
        taste              => '',
        odour              => '',
        solvents           => '',
        formulas           => '',
        vetrinary          => '',
        non_med            => '',
        culinary           => '',
        cultivation        => '',
        sister_plants      => '',
        harvest            => '',
        comments           => '',
        homiopathic        => '',
        chinese            => '',
        reference          => '',
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
