#!/usr/bin/env perl
use strict;
use warnings;
use DBI;
use LWP::UserAgent;
use JSON;
use Getopt::Long;

my $host     = '192.168.1.198';
my $port     = 3306;
my $database = 'ency';
my $user     = 'shanta_forager';
my $pass     = 'UA=nPF8*m+T#';
my $dry_run  = 0;
my $limit    = 0;

GetOptions(
    'dry-run' => \$dry_run,
    'limit=i' => \$limit,
);

my $dbh = DBI->connect(
    "dbi:MariaDB:database=$database;host=$host;port=$port",
    $user, $pass,
    { RaiseError => 1, PrintError => 0, AutoCommit => 1 }
) or die "Cannot connect: $DBI::errstr";

my $ua = LWP::UserAgent->new(timeout => 20);
$ua->default_header('Accept' => 'application/json');

my $insert = $dbh->prepare(q{
    INSERT INTO ency_organism_tb
        (common_name, scientific_name, organism_type, kingdom, phylum,
         class_name, order_name, family_name, genus, species, ncbi_tax_id,
         description, sitename, username_of_poster, date_time_posted, share)
    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,NOW(),1)
    ON DUPLICATE KEY UPDATE
        common_name     = VALUES(common_name),
        scientific_name = VALUES(scientific_name),
        organism_type   = VALUES(organism_type),
        kingdom         = VALUES(kingdom),
        phylum          = VALUES(phylum),
        class_name      = VALUES(class_name),
        order_name      = VALUES(order_name),
        family_name     = VALUES(family_name),
        genus           = VALUES(genus),
        species         = VALUES(species)
});

my @taxa_to_import = (
    { tax_id => 9606,    type => 'human',    label => 'Homo sapiens (Human)' },
    { tax_id => 40674,   type => 'mammal',   label => 'Mammalia (Mammals)' },
    { tax_id => 8782,    type => 'bird',     label => 'Aves (Birds)' },
    { tax_id => 50557,   type => 'insect',   label => 'Insecta (Insects)' },
    { tax_id => 7460,    type => 'insect',   label => 'Apis mellifera (Honeybee)' },
    { tax_id => 6960,    type => 'insect',   label => 'Arthropoda' },
    { tax_id => 7898,    type => 'fish',     label => 'Actinopterygii (Ray-finned fish)' },
    { tax_id => 8292,    type => 'amphibian',label => 'Amphibia' },
    { tax_id => 8504,    type => 'reptile',  label => 'Reptilia' },
    { tax_id => 33090,   type => 'plant',    label => 'Viridiplantae (Green plants)' },
    { tax_id => 4751,    type => 'fungus',   label => 'Fungi' },
    { tax_id => 2,       type => 'bacterium',label => 'Bacteria' },
    { tax_id => 10239,   type => 'virus',    label => 'Viruses' },
    { tax_id => 9615,    type => 'animal',   label => 'Canis lupus familiaris (Dog)' },
    { tax_id => 9685,    type => 'animal',   label => 'Felis catus (Cat)' },
    { tax_id => 9823,    type => 'animal',   label => 'Sus scrofa (Pig)' },
    { tax_id => 9913,    type => 'animal',   label => 'Bos taurus (Cattle)' },
    { tax_id => 9031,    type => 'bird',     label => 'Gallus gallus (Chicken)' },
    { tax_id => 9796,    type => 'animal',   label => 'Equus caballus (Horse)' },
);

my $count = 0;
for my $taxon (@taxa_to_import) {
    last if $limit && $count >= $limit;

    print "Fetching NCBI tax_id $taxon->{tax_id} ($taxon->{label})...\n";

    my $common_name     = $taxon->{label};
    my $scientific_name = '';
    my ($kingdom, $phylum, $class_name, $order_name, $family_name) = ('','','','','');
    my ($genus, $species) = ('', '');

    unless ($dry_run) {
        my $url = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esummary.fcgi"
                . "?db=taxonomy&id=$taxon->{tax_id}&retmode=json";
        my $resp = $ua->get($url);
        if ($resp->is_success) {
            my $data = eval { decode_json($resp->decoded_content) };
            if (!$@ && ref $data->{result} eq 'HASH') {
                my $rec = $data->{result}{ $taxon->{tax_id} } // {};
                $common_name     = $rec->{commonname} || $taxon->{label};
                $scientific_name = $rec->{scientificname} || '';
                ($genus, $species) = split /\s+/, $scientific_name, 2;
                $family_name  = $rec->{family}  // '';
                $order_name   = $rec->{order}   // '';
                $class_name   = $rec->{class}   // '';
                $phylum       = $rec->{phylum}  // '';
                $kingdom      = $rec->{kingdom} // '';
            }
        } else {
            warn "  WARN: HTTP failed for $taxon->{tax_id}: " . $resp->status_line . "\n";
        }
    }

    if ($dry_run) {
        print "  DRY: $common_name | $taxon->{type}\n";
    } else {
        eval {
            $insert->execute(
                $common_name, $scientific_name, $taxon->{type},
                $kingdom, $phylum, $class_name, $order_name, $family_name,
                $genus, $species, $taxon->{tax_id},
                "NCBI Taxonomy ID: $taxon->{tax_id}",
                'ENCY', 'system'
            );
            print "  OK: inserted/updated record_id via ncbi_tax_id=$taxon->{tax_id}\n";
        };
        warn "  ERR: $@\n" if $@;
    }

    $count++;
    sleep(0.35);
}

print "\nDone. $count record(s) processed.\n";

sub _extract_rank {
    my ($lineage, $rank) = @_;
    return '' unless $lineage;
    return '';
}
