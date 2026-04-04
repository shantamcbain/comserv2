#!/usr/bin/env perl
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use lib "$Bin/../local/lib/perl5";

use Comserv::Model::Schema::Ency;
use Comserv::Model::Schema::Forager;

my $LEGACY_DIR = "$Bin/../root/LegacyStaticPages/ency";
my $DRY_RUN    = grep { /--dry-run/ } @ARGV;
my $VERBOSE    = grep { /--verbose/ } @ARGV;
my $FORCE      = grep { /--force/   } @ARGV;

my $DB_HOST = '192.168.1.198';
my $DB_USER = 'shanta_forager';
my $DB_PASS = 'UA=nPF8*m+T#';

print "=== USBM Formula Seeder ===\n";
print "Dry run mode\n" if $DRY_RUN;

my $ency_schema = Comserv::Model::Schema::Ency->connect(
    "dbi:mysql:database=ency;host=$DB_HOST;port=3306",
    $DB_USER, $DB_PASS, { RaiseError => 1, AutoCommit => 1 }
) or die "Cannot connect to Ency schema\n";

my $forager_schema = Comserv::Model::Schema::Forager->connect(
    "dbi:mysql:database=shanta_forager;host=$DB_HOST;port=3306",
    $DB_USER, $DB_PASS, { RaiseError => 1, AutoCommit => 1 }
) or die "Cannot connect to Forager schema\n";

print "Connected to databases ($DB_HOST).\n";

sub clean_text {
    my ($s) = @_;
    return '' unless defined $s;
    $s =~ s/[^\x00-\x7F]/?/g;
    return $s;
}

my @formula_files = sort glob("$LEGACY_DIR/usbmf*.htm");
print "Found " . scalar(@formula_files) . " formula files.\n\n";

my ($imported, $skipped, $errors) = (0, 0, 0);

for my $file (@formula_files) {
    my $filename = (split '/', $file)[-1];
    my $parsed = parse_formula_htm($file);

    unless ($parsed && $parsed->{formula_number} && $parsed->{name}) {
        print "  SKIP (no parseable content): $filename\n" if $VERBOSE;
        $skipped++;
        next;
    }

    print "Processing $filename: Formula #$parsed->{formula_number} — $parsed->{name}\n";

    if (!$DRY_RUN) {
        eval {
            my $existing = $ency_schema->resultset('Formula')->find({ formula_number => $parsed->{formula_number} });
            if ($existing && !$FORCE) {
                print "  SKIP (already exists, use --force to overwrite): Formula #$parsed->{formula_number}\n";
                $skipped++;
                return;
            }
            if ($existing && $FORCE) {
                $ency_schema->resultset('FormulaHerb')->search({ formula_id => $existing->record_id })->delete;
                $ency_schema->resultset('FormulaDisease')->search({ formula_id => $existing->record_id })->delete;
                $existing->delete;
            }

            my $image = find_image($forager_schema, $parsed->{herb_names});

            my $formula = $ency_schema->resultset('Formula')->create({
                formula_number     => clean_text($parsed->{formula_number}),
                name               => clean_text($parsed->{name}),
                indications        => clean_text($parsed->{indications}),
                description        => clean_text($parsed->{description}),
                herbs_raw          => clean_text($parsed->{herbs_raw}),
                preparation        => clean_text($parsed->{preparation}),
                dosage             => clean_text($parsed->{dosage}),
                administration     => clean_text($parsed->{administration}),
                notes              => clean_text($parsed->{notes}),
                reference          => clean_text($parsed->{reference}),
                source             => 'USBM Legacy',
                source_file        => $filename,
                image              => $image,
                sitename           => 'ENCY',
                username_of_poster => 'seeder',
                date_time_posted   => scalar localtime,
                share              => 0,
            });

            my $fid = $formula->record_id;
            my $herb_count = 0;
            my $herb_match = 0;

            for my $herb_entry (@{ $parsed->{herbs} }) {
                my $herb_id = find_herb_id($forager_schema, $herb_entry->{botanical}, $herb_entry->{common});
                $herb_match++ if $herb_id;
                $ency_schema->resultset('FormulaHerb')->create({
                    formula_id         => $fid,
                    herb_id            => $herb_id,
                    herb_name_raw      => $herb_entry->{common}    // '',
                    botanical_name_raw => $herb_entry->{botanical} // '',
                    quantity           => $herb_entry->{quantity}  // '',
                    plant_part         => $herb_entry->{part}      // '',
                });
                $herb_count++;
            }

            for my $cond (@{ $parsed->{conditions} }) {
                next unless length($cond) > 2;
                my $disease_id = find_disease_id($ency_schema, $cond);
                $ency_schema->resultset('FormulaDisease')->create({
                    formula_id     => $fid,
                    disease_id     => $disease_id,
                    condition_name => $cond,
                });
            }

            print "  Saved: #$parsed->{formula_number}, $herb_count herbs ($herb_match matched), "
                . scalar(@{$parsed->{conditions}}) . " conditions"
                . ($image ? ", image: $image" : "")
                . "\n";
            $imported++;
        };
        if ($@) {
            print "  ERROR: $@\n";
            $errors++;
        }
    } else {
        print "  [DRY RUN] Would import: #$parsed->{formula_number} with "
            . scalar(@{$parsed->{herbs}}) . " herbs, "
            . scalar(@{$parsed->{conditions}}) . " conditions\n";
        $imported++;
    }
}

print "\n=== Done: $imported imported, $skipped skipped, $errors errors ===\n";

sub parse_formula_htm {
    my ($file) = @_;
    local $/;
    open(my $fh, '<', $file) or return undef;
    my $html = <$fh>;
    close $fh;

    $html =~ s/<!--.*?-->//gs;
    $html =~ s/<script.*?<\/script>//gsi;
    $html =~ s/<[^>]+>//g;
    $html =~ s/&amp;/&/g;
    $html =~ s/&nbsp;/ /g;
    $html =~ s/&#(\d+);/chr($1)/ge;
    $html =~ s/\x{c2}\x{b0}/°/g;

    my @lines = map { s/^\s+//; s/\s+$//; $_ } split(/\n/, $html);
    @lines = grep { length($_) > 1 } @lines;

    my $in_content = 0;
    my @content;
    for my $line (@lines) {
        $in_content = 1 if $line =~ /Formula\s*#?\s*\d+/i;
        next unless $in_content;
        last if $line =~ /Copyright|CoffeeCup|dateMod|document\.|window\.|License|reuse|rights reserved/i;
        next if $line =~ /botanical\s*name|common\s*name|diseases\.|glossery\.|donations\.|formulas\.|help\.|Reference\.|regester\.|submit info|download ENCY|ComServ|What's New|ENCY Home Page|WebMaster/i;
        next if $line =~ /^\|$/;
        push @content, $line;
    }
    return undef unless @content;

    my $result = {
        formula_number => undef,
        name           => '',
        indications    => '',
        description    => '',
        herbs_raw      => '',
        preparation    => '',
        dosage         => '',
        administration => '',
        notes          => '',
        reference      => '',
        herbs          => [],
        conditions     => [],
        herb_names     => [],
    };

    my @herb_lines;
    my $title_done = 0;
    my $phase = 'title';

    for my $line (@content) {
        if (!$title_done && $line =~ /Formula\s*#?\s*0*(\d+)\s*(.*)$/i) {
            $result->{formula_number} = $1;
            my $rest = $2;
            $rest =~ s/^\s*[-:.]\s*//;
            $result->{name} = $rest || "Formula $1";
            $title_done = 1;
            $phase = 'herbs';
            extract_conditions($result, $rest);
            next;
        }
        next unless $title_done;

        if ($line =~ /^Preparation\s*:/i) {
            $phase = 'prep';
            (my $p = $line) =~ s/^Preparation\s*:\s*//i;
            $result->{preparation} = $p;
            next;
        }
        if ($line =~ /^Infusion|^Decoction|^Steep|^Simmer|^Boil|^Macerate|^Warm/i && $phase eq 'herbs') {
            $phase = 'prep';
            $result->{preparation} = $line;
            next;
        }
        if ($line =~ /^Dosage\s*:/i) {
            $phase = 'dosage';
            (my $d = $line) =~ s/^Dosage\s*:\s*//i;
            $result->{dosage} = $d;
            next;
        }
        if ($line =~ /^Administration\s*:/i) {
            $phase = 'admin';
            (my $a = $line) =~ s/^Administration\s*:\s*//i;
            $result->{administration} = $a;
            next;
        }
        if ($line =~ /^Ref(?:erence|s?)[\s:]/i || $line =~ /^\s*Indian Herbal|^\s*King's|^\s*Hutchens/i) {
            $phase = 'ref';
            $result->{reference} .= $line . "\n";
            next;
        }
        if ($line =~ /^Note\s*:/i || $line =~ /^NM\b/i) {
            $result->{notes} .= $line . "\n";
            next;
        }

        if ($phase eq 'herbs') {
            push @herb_lines, $line;
        } elsif ($phase eq 'prep')   { $result->{preparation}    .= " $line"; }
        elsif ($phase eq 'dosage')   { $result->{dosage}         .= " $line"; }
        elsif ($phase eq 'admin')    { $result->{administration}  .= " $line"; }
        elsif ($phase eq 'ref')      { $result->{reference}       .= "$line\n"; }
    }

    $result->{herbs_raw} = join("\n", @herb_lines);

    for my $hl (@herb_lines) {
        my $entry = parse_herb_line($hl);
        push @{ $result->{herbs} }, $entry if $entry && ($entry->{botanical} || $entry->{common});
        push @{ $result->{herb_names} }, $entry->{botanical} || $entry->{common}
            if $entry && ($entry->{botanical} || $entry->{common});
    }

    $result->{preparation}    =~ s/\s+/ /g;
    $result->{dosage}         =~ s/\s+/ /g;
    $result->{administration} =~ s/\s+/ /g;
    $result->{name}           =~ s/\s+/ /g;
    $result->{name}           = substr($result->{name}, 0, 499) if length($result->{name}) > 499;

    return $result;
}

sub extract_conditions {
    my ($result, $text) = @_;
    return unless $text;
    my @parts = split /[;,()]/, $text;
    for my $p (@parts) {
        $p =~ s/^\s+//; $p =~ s/\s+$//;
        next unless length($p) > 2;
        next if $p =~ /^\d+$|^NM$|^\(?\d/;
        push @{ $result->{conditions} }, $p;
        $result->{indications} .= "$p; " unless $result->{indications} =~ /\Q$p\E/i;
    }
    $result->{indications} =~ s/;\s*$//;
}

sub parse_herb_line {
    my ($line) = @_;
    my %entry = (botanical => '', common => '', quantity => '', part => '');

    $line =~ s/^\s+//; $line =~ s/\s+$//;
    return undef if length($line) < 3;
    return undef if $line =~ /Preparation|Dosage|Administration|Infusion|Decoction|Steep|Simmer|Boil|^Note/i;

    if ($line =~ /^(\d+[\d\/]*(?:\s*tsp?\.?|tbsp?\.?|oz\.?|cup)?)\s+(.+)/) {
        $entry{quantity} = $1;
        $line = $2;
    } elsif ($line =~ /^(Pinch|handful|few drops?)\s+/i) {
        $entry{quantity} = $1;
        $line = $';
    }

    if ($line =~ /^([A-Z][a-z]+(?:\s+[a-z]+){1,3})\s*\(([^)]+)\)(.*)$/) {
        $entry{botanical} = $1;
        $entry{common}    = $2;
        my $rest = $3;
        if ($rest =~ /(\d+[\d\/]*)\s*$/) { $entry{quantity} ||= $1; }
    } elsif ($line =~ /\(([^)]+)\)/) {
        my $in_paren = $1;
        (my $before = $`) =~ s/\s+$//;
        if ($before =~ /^[A-Z][a-z]/) { $entry{botanical} = $before; $entry{common} = $in_paren; }
        else                            { $entry{common} = $before || $in_paren; }
    } else {
        ($line =~ /^[A-Z][a-z]+\s+[a-z]+/) ? ($entry{botanical} = $line) : ($entry{common} = $line);
    }

    for my $key (qw(common botanical)) {
        $entry{$key} =~ s/\s*\d+\s*$//;
        $entry{$key} =~ s/^\s+|\s+$//g;
        $entry{$key} = substr($entry{$key}, 0, 254) if length($entry{$key}) > 254;
    }

    if ($entry{common} =~ s/\s+(leaves?|root|bark|flower?s?|seed|berries|herb|lf\.|flw\.?|tincture|aerial parts?)\s*$//i) {
        $entry{part} = $1;
    } elsif ($entry{botanical} =~ s/\s+(leaves?|root|bark|flower?s?|seed|berries)\s*$//i) {
        $entry{part} = $1;
    }

    return \%entry;
}

sub find_herb_id {
    my ($schema, $botanical, $common) = @_;
    my $herb;
    for my $name (grep { $_ && length($_) > 2 } ($botanical, $common)) {
        eval {
            $herb = $schema->resultset('Herb')->search(
                { -or => [
                    botanical_name => { like => "%$name%" },
                    common_names   => { like => "%$name%" },
                ]},
                { rows => 1, order_by => 'record_id' }
            )->first;
        } or do {};
        last if $herb;
    }
    return $herb ? $herb->record_id : undef;
}

sub find_disease_id {
    my ($schema, $condition) = @_;
    my $disease;
    eval {
        $disease = $schema->resultset('Disease')->search(
            { common_name => { like => "%$condition%" } },
            { rows => 1, order_by => 'record_id' }
        )->first;
    } or do {};
    return $disease ? $disease->record_id : undef;
}

sub find_image {
    my ($schema, $herb_names) = @_;
    return undef unless $herb_names && @$herb_names;
    for my $name (@$herb_names) {
        next unless $name && length($name) > 2;
        my $herb;
        eval {
            $herb = $schema->resultset('Herb')->search(
                { -or => [
                    botanical_name => { like => "%$name%" },
                    common_names   => { like => "%$name%" },
                ]},
                { rows => 1, order_by => 'record_id' }
            )->first;
        } or do {};
        if ($herb && $herb->image && length($herb->image) > 3) {
            return $herb->image;
        }
    }
    return undef;
}
