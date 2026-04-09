#!/usr/bin/env perl
#
# seed_glossary.pl — Import glossary/therapeutic-action terms into ency_glossary_tb
# from two sources:
#   1. Forager DB: shanta_forager.ency_glossary_tb (71 rows — mostly therapeutic actions)
#   2. Legacy file: LegacyStaticPages/ency/gloss.htm
#
# Usage:
#   perl Comserv/script/seed_glossary.pl [--dry-run] [--verbose] [--force]
#
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use lib "$Bin/../local/lib/perl5";

use DBI;
use Comserv::Model::Schema::Ency;
use HTML::Entities qw(decode_entities);

my $DRY_RUN = grep { /--dry-run/ } @ARGV;
my $VERBOSE = grep { /--verbose/ } @ARGV;
my $FORCE   = grep { /--force/   } @ARGV;

my $LEGACY_DIR = "$Bin/../root/LegacyStaticPages/ency";

my $DB_HOST = '192.168.1.198';
my $DB_USER = 'shanta_forager';
my $DB_PASS = 'UA=nPF8*m+T#';

print "=== Glossary Seeder ===\n";
print "Dry run mode\n" if $DRY_RUN;

my $ency = Comserv::Model::Schema::Ency->connect(
    "dbi:mysql:database=ency;host=$DB_HOST;port=3306",
    $DB_USER, $DB_PASS, { RaiseError => 1, AutoCommit => 1 }
) or die "Cannot connect to Ency schema\n";

my $src_dbh = DBI->connect(
    "dbi:mysql:database=shanta_forager;host=$DB_HOST;port=3306",
    $DB_USER, $DB_PASS, { RaiseError => 1, AutoCommit => 1 }
) or die "Cannot connect to Forager DB\n";

print "Connected to $DB_HOST.\n\n";

my ($created, $updated, $skipped, $errors) = (0, 0, 0, 0);

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

sub upsert_term {
    my ($term, $definition, $category, $context, $url) = @_;
    $term       = strip_html($term // '');
    $definition = strip_html($definition // '');
    $category   = strip_html($category  // '');
    $context    = strip_html($context   // '');
    $url        = strip_html($url       // '');

    $term = substr($term, 0, 255);
    return unless length($term) > 1;

    print "  Term: $term\n" if $VERBOSE;

    if ($DRY_RUN) {
        print "  [DRY RUN] Would insert: $term\n";
        $created++;
        return;
    }

    my $existing = $ency->resultset('Glossary')->search(
        { term => { like => $term } },
        { rows => 1, order_by => 'record_id' }
    )->first;

    if ($existing && !$FORCE) {
        print "  SKIP (exists): $term\n" if $VERBOSE;
        $skipped++;
        return;
    }

    my $data = {
        term               => $term,
        definition         => $definition,
        category           => $category,
        context            => $context,
        alternate_terms    => '',
        etymology          => '',
        examples           => '',
        related_terms      => '',
        url                => $url,
        sitename           => 'ENCY',
        username_of_poster => 'seeder',
        group_of_poster    => 'admin',
        date_time_posted   => scalar localtime,
        share              => 0,
    };

    eval {
        if ($existing && $FORCE) {
            $existing->update($data);
            print "  UPDATED: $term\n";
            $updated++;
        } else {
            $ency->resultset('Glossary')->create($data);
            print "  CREATED: $term\n";
            $created++;
        }
    };
    if ($@) {
        warn "  ERROR for '$term': $@\n";
        $errors++;
    }
}

# ── SOURCE 1: Forager ency_glossary_tb ────────────────────────────────────────
print "=== Source 1: Forager ency_glossary_tb ===\n";

my $rows = $src_dbh->selectall_arrayref(
    "SELECT * FROM ency_glossary_tb ORDER BY record_id",
    { Slice => {} }
) or die "Cannot query ency_glossary_tb\n";

print "Found " . scalar(@$rows) . " rows.\n\n";

for my $row (@$rows) {
    my $cat = $row->{list_category} || '';
    $cat = 'therapeutic_action' if $cat =~ /therapeutic/i;
    upsert_term(
        $row->{title},
        $row->{definition},
        $cat,
        $row->{comments},
        $row->{url},
    );
}

# ── SOURCE 2: gloss.htm ────────────────────────────────────────────────────────
print "\n=== Source 2: gloss.htm ===\n";

my $gloss_file = "$LEGACY_DIR/gloss.htm";
unless (-f $gloss_file) {
    print "File not found: $gloss_file — skipping.\n";
} else {
    open my $fh, '<:raw', $gloss_file or die "Cannot open $gloss_file: $!";
    my $html = do { local $/; <$fh> };
    close $fh;

    $html =~ s/<script[^>]*>.*?<\/script>//gsi;
    $html =~ s/<!--.*?-->//gs;

    my @terms;
    while ($html =~ /<a\s+name="([^"]+)"[^>]*>\s*<\/a>\s*<strong>([^<]+)<\/strong>\s*(.*?)(?=<a\s+name=|<h[23]|\Z)/gsi) {
        my ($anchor, $term, $body) = ($1, $2, $3);
        my $defn = strip_html($body);
        push @terms, { term => strip_html($term), definition => $defn, category => 'therapeutic_action' };
    }

    if (!@terms) {
        while ($html =~ /<h[23][^>]*>\s*([A-Za-z][^<]{1,80})\s*<\/h[23]>\s*<p>([^<]{5,})/gi) {
            push @terms, { term => strip_html($1), definition => strip_html($2), category => 'therapeutic_action' };
        }
    }

    if (!@terms) {
        while ($html =~ /<li[^>]*>\s*<strong>\s*([A-Za-z][^<]{1,80})<\/strong>\s*(.*?)(?=<li|\Z)/gsi) {
            push @terms, { term => strip_html($1), definition => strip_html($2), category => 'therapeutic_action' };
        }
    }

    print "Found " . scalar(@terms) . " terms in gloss.htm.\n\n";
    for my $t (@terms) {
        upsert_term($t->{term}, $t->{definition}, $t->{category}, '', '');
    }
}

print "\n=== Done: $created created, $updated updated, $skipped skipped, $errors errors. ===\n";
