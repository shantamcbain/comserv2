#!/usr/bin/env perl
#
# seed_diseases.pl — Import disease data into ency_disease_tb from two sources:
#   1. Forager DB: shanta_forager.ency_deseases_tb (11 rows)
#   2. Legacy file: LegacyStaticPages/ency/diseases.htm
#
# Usage:
#   perl Comserv/script/seed_diseases.pl [--dry-run] [--verbose] [--force]
#
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use lib "$Bin/../local/lib/perl5";

use Comserv::Model::Schema::Ency;
use HTML::Entities qw(decode_entities);

my $DRY_RUN = grep { /--dry-run/ } @ARGV;
my $VERBOSE = grep { /--verbose/ } @ARGV;
my $FORCE   = grep { /--force/   } @ARGV;

my $LEGACY_DIR = "$Bin/../root/LegacyStaticPages/ency";

my $DB_HOST = '192.168.1.198';
my $DB_USER = 'shanta_forager';
my $DB_PASS = 'UA=nPF8*m+T#';

print "=== Disease Seeder ===\n";
print "Dry run mode\n" if $DRY_RUN;

my $ency = Comserv::Model::Schema::Ency->connect(
    "dbi:mysql:database=ency;host=$DB_HOST;port=3306",
    $DB_USER, $DB_PASS, { RaiseError => 1, AutoCommit => 1 }
) or die "Cannot connect to Ency schema\n";

my $src_dbh = DBI->connect(
    "dbi:mysql:database=shanta_forager;host=$DB_HOST;port=3306",
    $DB_USER, $DB_PASS, { RaiseError => 1, AutoCommit => 1 }
) or die "Cannot connect to Forager DB\n";

use DBI;

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

sub upsert_disease {
    my ($data) = @_;
    return unless $data->{common_name};

    print "  Processing: $data->{common_name}\n";

    if ($DRY_RUN) {
        print "  [DRY RUN] Would insert disease: $data->{common_name}\n";
        return;
    }

    my $existing = $ency->resultset('Disease')->search(
        { common_name => { like => '%' . $data->{common_name} . '%' } },
        { rows => 1, order_by => 'record_id' }
    )->first;

    if ($existing && !$FORCE) {
        print "  SKIP (exists, use --force): $data->{common_name}\n";
        return;
    }

    eval {
        if ($existing && $FORCE) {
            $existing->update($data);
            print "  UPDATED: $data->{common_name}\n";
        } else {
            $ency->resultset('Disease')->create($data);
            print "  CREATED: $data->{common_name}\n";
        }
    };
    warn "  ERROR: $@\n" if $@;
}

my ($total) = (0);

# ── SOURCE 1: Forager ency_deseases_tb ────────────────────────────────────────
print "=== Source 1: Forager ency_deseases_tb ===\n";

my $rows = $src_dbh->selectall_arrayref(
    "SELECT * FROM ency_deseases_tb ORDER BY record_id",
    { Slice => {} }
) or die "Cannot query ency_deseases_tb\n";

print "Found " . scalar(@$rows) . " rows.\n\n";

for my $row (@$rows) {
    my $treatment = join("\n", grep { length($_) }
        strip_html($row->{medical_uses}    || ''),
        strip_html($row->{preparation}     || ''),
        strip_html($row->{dosage}          || ''),
        strip_html($row->{administration}  || ''),
    );
    my $history = join("\n", grep { length($_) }
        strip_html($row->{history}   || ''),
        strip_html($row->{comments}  || ''),
    );

    upsert_disease({
        common_name           => strip_html($row->{display_name} || $row->{name} || ''),
        scientific_name       => '',
        disease_type          => strip_html($row->{category}          || ''),
        host_type             => 'human',
        causative_agent       => '',
        transmission          => '',
        symptoms_description  => strip_html($row->{description}       || ''),
        diagnosis             => '',
        treatment_conventional => $treatment,
        treatment_herbal      => strip_html($row->{herbs}             || ''),
        prevention            => strip_html($row->{contra_indications}|| ''),
        prognosis             => '',
        icd_code              => '',
        distribution          => '',
        image                 => '',
        url                   => strip_html($row->{url}               || ''),
        history               => $history,
        reference             => strip_html($row->{reference}         || ''),
        sitename              => 'ENCY',
        username_of_poster    => 'seeder',
        group_of_poster       => 'admin',
        date_time_posted      => scalar localtime,
        share                 => 0,
    });
    $total++;
}

# ── SOURCE 2: diseases.htm ─────────────────────────────────────────────────────
print "\n=== Source 2: diseases.htm ===\n";

my $diseases_file = "$LEGACY_DIR/diseases.htm";
unless (-f $diseases_file) {
    print "File not found: $diseases_file — skipping.\n";
} else {
    open my $fh, '<:raw', $diseases_file or die "Cannot open $diseases_file: $!";
    my $html = do { local $/; <$fh> };
    close $fh;

    $html =~ s/<script[^>]*>.*?<\/script>//gsi;
    $html =~ s/<!--.*?-->//gs;

    my @entries;
    while ($html =~ /<h[23][^>]*>\s*([A-Za-z][^<]{2,80})\s*<\/h[23]>/gi) {
        my $name = strip_html($1);
        next unless length($name) > 2;
        next if $name =~ /^(Encyclopedia|Box|Suggested|What)/i;
        push @entries, { common_name => $name };
    }

    if (!@entries) {
        while ($html =~ /<b>\s*([A-Za-z][^<]{2,60})\s*<\/b>/gi) {
            my $name = strip_html($1);
            next unless length($name) > 3;
            next if $name =~ /^(Botanical|Common|Identifying|Stem|Leaves|Parts|Therapeutic|Medical|Homeopathic|Chinese|Dosage|Preparation|Formulas|History|Distribution|Cultivation)/i;
            push @entries, { common_name => $name };
        }
    }

    print "Found " . scalar(@entries) . " disease entries in diseases.htm.\n\n";
    for my $e (@entries) {
        upsert_disease({
            %$e,
            scientific_name       => '',
            disease_type          => '',
            host_type             => 'human',
            sitename              => 'ENCY',
            username_of_poster    => 'seeder',
            group_of_poster       => 'admin',
            date_time_posted      => scalar localtime,
            share                 => 0,
        });
        $total++;
    }
}

print "\n=== Done: $total disease records processed. ===\n";
