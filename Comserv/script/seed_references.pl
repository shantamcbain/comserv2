#!/usr/bin/env perl
#
# seed_references.pl — Populate reference table with data from legacy refreance.html
#                      Also seeds ency_publisher_tb and ency_author_tb then links them.
#
# Usage:
#   perl Comserv/script/seed_references.pl [--dry-run] [--verbose]
#
# What it does:
#   1. Inserts/updates the reference table with correct reference_ids (matching legacy numbers)
#   2. Fixes reference_system column to hold media type ('book') not the legacy number
#   3. Inserts publishers into ency_publisher_tb and links via publisher_id FK
#   4. Inserts authors into ency_author_tb and links via ency_reference_author junction
#   5. Removes orphan placeholder records (old auto-inc rows for books 27/28)
#
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use lib "$Bin/../local/lib/perl5";
use DBI;

my $DRY_RUN = grep { /--dry-run/ } @ARGV;
my $VERBOSE = grep { /--verbose/ } @ARGV;

print "=== Reference Seeder ===\n";
print "DRY RUN\n" if $DRY_RUN;
print "\n";

my $DB_HOST = '192.168.1.198';
my $DB_USER = 'shanta_forager';
my $DB_PASS = 'UA=nPF8*m+T#';

my $dbh = DBI->connect(
    "dbi:mysql:database=ency;host=$DB_HOST;port=3306",
    $DB_USER, $DB_PASS, { RaiseError => 1, AutoCommit => 1, PrintError => 0 }
) or die "Cannot connect to ency DB: $DBI::errstr\n";

print "Connected.\n\n";

# ─────────────────────────────────────────────────────────
# PUBLISHERS
# ─────────────────────────────────────────────────────────
my @publishers = (
    { name => 'Grosset & Dunlap',               location => 'New York, NY' },
    { name => 'Bantam Books',                    location => 'New York, NY' },
    { name => 'Publishers Merco',                location => 'Windsor, Ontario, Canada' },
    { name => 'Parker Publishing Company',       location => 'West Nyack, New York' },
    { name => 'Microlith Printing',              location => 'Provo, Utah' },
    { name => 'A.R. Harding Publishing',         location => 'Columbus, Ohio' },
    { name => 'Beoagrtown Press',                location => undef },
    { name => 'Eclectic Medical Publications',   location => 'Portland, Oregon' },
    { name => 'W.B. Saunders Company',           location => 'Philadelphia, PA' },
);

my %pub_id;  # name → publisher_id

print "── Publishers ──\n";
for my $p (@publishers) {
    my $existing = $dbh->selectrow_hashref(
        "SELECT publisher_id FROM ency_publisher_tb WHERE name=?", undef, $p->{name}
    );
    if ($existing) {
        $pub_id{ $p->{name} } = $existing->{publisher_id};
        print "  SKIP (exists) publisher_id=$pub_id{$p->{name}}: $p->{name}\n" if $VERBOSE;
    } else {
        print "  INSERT: $p->{name}\n";
        unless ($DRY_RUN) {
            $dbh->do(
                "INSERT INTO ency_publisher_tb (name, location) VALUES (?, ?)",
                undef, $p->{name}, $p->{location}
            );
            $pub_id{ $p->{name} } = $dbh->{mysql_insertid};
            print "    → publisher_id=$pub_id{$p->{name}}\n" if $VERBOSE;
        }
    }
}
print "\n";

# ─────────────────────────────────────────────────────────
# AUTHORS
# ─────────────────────────────────────────────────────────
my @authors = (
    { full_name => 'Stuart, Malcolm',                          affiliation => undef },
    { full_name => 'Lust, John',                               affiliation => undef },
    { full_name => 'Hutchens, Alma R.',                        affiliation => undef },
    { full_name => 'Kadans, Joseph M.',                        affiliation => undef },
    { full_name => 'Christopher, John R.',                     affiliation => undef },
    { full_name => 'Harding, A.R.',                            affiliation => undef },
    { full_name => 'Bliss, Beatrice',                          affiliation => undef },
    { full_name => 'Felter, Harvey Wickes',
      affiliation => 'Eclectic Medical Institute, Cincinnati' },
    { full_name => 'Lloyd, John Uri',
      affiliation => 'Eclectic Medical Institute, Cincinnati' },
    { full_name => 'Miller, Benjamin F.',                      affiliation => undef },
    { full_name => 'Keane, Claire Brackman',                   affiliation => undef },
    { full_name => 'Levy, Juliette de Bairach',                affiliation => undef },
);

my %auth_id;  # full_name → author_id

print "── Authors ──\n";
for my $a (@authors) {
    my $existing = $dbh->selectrow_hashref(
        "SELECT author_id FROM ency_author_tb WHERE full_name=?", undef, $a->{full_name}
    );
    if ($existing) {
        $auth_id{ $a->{full_name} } = $existing->{author_id};
        print "  SKIP (exists) author_id=$auth_id{$a->{full_name}}: $a->{full_name}\n" if $VERBOSE;
    } else {
        print "  INSERT: $a->{full_name}\n";
        unless ($DRY_RUN) {
            $dbh->do(
                "INSERT INTO ency_author_tb (full_name, affiliation) VALUES (?, ?)",
                undef, $a->{full_name}, $a->{affiliation}
            );
            $auth_id{ $a->{full_name} } = $dbh->{mysql_insertid};
            print "    → author_id=$auth_id{$a->{full_name}}\n" if $VERBOSE;
        }
    }
}
print "\n";

# ─────────────────────────────────────────────────────────
# REFERENCES
# Each entry: id (legacy book number = reference_id), title, authors[], publisher, year, isbn, notes
# reference_system column is now media type ('book', 'journal', etc.)
# ─────────────────────────────────────────────────────────
my @refs = (
    {
        id         => 1,
        title      => 'The Encyclopedia of Herbs and Herbalism',
        authors    => ['Stuart, Malcolm'],
        publisher  => 'Grosset & Dunlap',
        year       => '1979',
        isbn       => '0-448-15472-2',
        notes      => 'Copyright 1979 Orbis Publishing Limited, London. ISBN printed as ISDN in original.',
    },
    {
        id         => 2,
        title      => 'The Herb Book',
        authors    => ['Lust, John'],
        publisher  => 'Bantam Books',
        year       => undef,
        isbn       => undef,
        notes      => undef,
    },
    {
        id         => 3,
        title      => 'Indian Herbalogy of North America',
        authors    => ['Hutchens, Alma R.'],
        publisher  => 'Publishers Merco',
        year       => '1974',
        isbn       => undef,
        notes      => 'Copyright 1974. Windsor, Ontario.',
    },
    {
        id         => 4,
        title      => 'Modern Encyclopedia of Herbs',
        authors    => ['Kadans, Joseph M.'],
        publisher  => 'Parker Publishing Company',
        year       => undef,
        isbn       => undef,
        notes      => undef,
    },
    {
        id         => 5,
        title      => 'School of Natural Healing',
        authors    => ['Christopher, John R.'],
        publisher  => 'Microlith Printing',
        year       => '1976',
        isbn       => undef,
        notes      => 'Copyright 1976 John R. Christopher.',
    },
    {
        id         => 7,
        title      => 'Ginseng and Other Medicinal Plants',
        authors    => ['Harding, A.R.'],
        publisher  => 'A.R. Harding Publishing',
        year       => undef,
        isbn       => undef,
        notes      => undef,
    },
    {
        id         => 8,
        title      => '(Title Not Recorded)',
        authors    => ['Bliss, Beatrice'],
        publisher  => 'Beoagrtown Press',
        year       => undef,
        isbn       => undef,
        notes      => 'Title missing in 1999 legacy reference list.',
    },
    {
        id         => 27,
        title      => "King's American Dispensatory",
        authors    => ['Felter, Harvey Wickes', 'Lloyd, John Uri'],
        publisher  => 'Eclectic Medical Publications',
        year       => '1898',
        isbn       => undef,
        url        => 'https://www.henriettes-herb.com/eclectic/kings/',
        notes      => '18th Edition, 3rd Revision, 1898; reprinted 1983. Public domain — freely available online.',
    },
    {
        id         => 35,
        title      => 'Encyclopedia and Dictionary of Medicine, Nursing, and Allied Health (2nd Edition)',
        authors    => ['Miller, Benjamin F.', 'Keane, Claire Brackman'],
        publisher  => 'W.B. Saunders Company',
        year       => '1978',
        isbn       => '0-7216-6358-3',
        notes      => undef,
    },
);

# Remove orphan placeholder records created for books 27/28 at wrong reference_ids
print "── Cleaning orphan placeholder records ──\n";
my $orphans = $dbh->selectall_arrayref(
    "SELECT reference_id, reference_system FROM `reference`
      WHERE reference_system REGEXP '^[0-9]+\$'
        AND reference_id NOT IN (" . join(',', map { $_->{id} } @refs) . ")",
    { Slice => {} }
);
for my $o (@$orphans) {
    printf "  reference_id=%d has reference_system='%s' (numeric legacy ID at wrong record)\n",
        $o->{reference_id}, $o->{reference_system};
    unless ($DRY_RUN) {
        eval { $dbh->do("DELETE FROM `reference` WHERE reference_id=?", undef, $o->{reference_id}) };
        print "    Deleted reference_id=$o->{reference_id}\n";
    }
}

# Also remove orphans that ARE in the known ID set but have wrong reference_system
# e.g. reference_id=11 has reference_system='27' → should be replaced by reference_id=27
my @known_ids = map { $_->{id} } @refs;
$orphans = $dbh->selectall_arrayref(
    "SELECT reference_id, reference_system FROM `reference`
      WHERE reference_system REGEXP '^[0-9]+\$'
        AND reference_id NOT IN (" . join(',', @known_ids) . ")",
    { Slice => {} }
);
for my $o (@$orphans) {
    printf "  Orphan: reference_id=%d reference_system='%s'\n",
        $o->{reference_id}, $o->{reference_system};
    unless ($DRY_RUN) {
        $dbh->do("DELETE FROM `reference` WHERE reference_id=?", undef, $o->{reference_id});
        print "    Deleted\n";
    }
}
print "\n";

# Upsert references
print "── References ──\n";
my $upsert = $dbh->prepare(q{
    INSERT INTO `reference`
        (reference_id, title, author, publisher, publisher_id, publication_date, isbn, url,
         reference_system, notes, sitename, username_of_poster, date_time_posted)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'book', ?, 'ENCY', 'seed_references', NOW())
    ON DUPLICATE KEY UPDATE
        title            = IF(VALUES(title) IS NOT NULL AND VALUES(title) != '', VALUES(title), title),
        author           = IF(VALUES(author) IS NOT NULL AND VALUES(author) != '', VALUES(author), author),
        publisher        = IF(VALUES(publisher) IS NOT NULL, VALUES(publisher), publisher),
        publisher_id     = IF(VALUES(publisher_id) IS NOT NULL, VALUES(publisher_id), publisher_id),
        publication_date = IF(VALUES(publication_date) IS NOT NULL, VALUES(publication_date), publication_date),
        isbn             = IF(VALUES(isbn) IS NOT NULL AND VALUES(isbn) != '', VALUES(isbn), isbn),
        url              = IF(VALUES(url) IS NOT NULL AND VALUES(url) != '', VALUES(url), url),
        reference_system = 'book',
        notes            = IF(VALUES(notes) IS NOT NULL AND VALUES(notes) != '', VALUES(notes), notes)
});

for my $r (@refs) {
    my $author_str = join('; ', @{ $r->{authors} || [] });
    my $pub_name   = $r->{publisher} // '';
    my $pid        = $pub_id{$pub_name} // undef;
    my $pub_date   = $r->{year} ? "$r->{year}-01-01" : undef;
    my $url        = $r->{url} // undef;

    printf "  [%2d] %s — %s\n", $r->{id}, $r->{title}, $author_str;
    unless ($DRY_RUN) {
        eval {
            $upsert->execute(
                $r->{id}, $r->{title}, $author_str, $pub_name, $pid,
                $pub_date, $r->{isbn}, $url, $r->{notes}
            );
        };
        if ($@) { print "    ERROR: $@\n" }
        else     { print "    OK\n" if $VERBOSE }
    }
}
print "\n";

# ─────────────────────────────────────────────────────────
# REFERENCE_AUTHOR JUNCTION
# ─────────────────────────────────────────────────────────
print "── Reference-Author links ──\n";
my $ra_insert = $dbh->prepare(q{
    INSERT IGNORE INTO ency_reference_author (reference_id, author_id, author_order)
    VALUES (?, ?, ?)
});

for my $r (@refs) {
    my $order = 1;
    for my $aname (@{ $r->{authors} || [] }) {
        my $aid = $auth_id{$aname};
        unless ($aid) {
            print "  WARN: no author_id for '$aname' (not yet in DB — run after authors insert)\n";
            next;
        }
        printf "  ref_id=%d → author_id=%d (%s)\n", $r->{id}, $aid, $aname if $VERBOSE;
        unless ($DRY_RUN) {
            eval { $ra_insert->execute($r->{id}, $aid, $order++) };
            print "  ERROR linking ref $r->{id} → $aname: $@\n" if $@;
        }
    }
}
print "\n";

$dbh->disconnect;
print "Done.\n";
