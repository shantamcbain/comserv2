#!/usr/bin/env perl
# Propose HealthKitchen sourcing attributes for a site's food inventory items.
#   perl script/hk_classify_sourcing.pl --sitename Shanta            # DRY RUN (default, read-only)
#   perl script/hk_classify_sourcing.pl --sitename Shanta --csv      # dry run as CSV
#   perl script/hk_classify_sourcing.pl --sitename Shanta --apply    # writes (needs approval)
# --apply only fills inventory_item_attributes columns that are currently NULL (never
# overwrites user edits), skips 'unknown' items, and requires the sourcing columns to exist
# (Schema Compare: Accounting::InventoryItemAttributes). One transaction. Run from Comserv/ (needs logs/).
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Getopt::Long;
use Comserv;
use Comserv::Util::HealthKitchen;

my ( $site, $apply, $csv, $include_inferred ) = ( undef, 0, 0, 1 );
GetOptions( 'sitename=s' => \$site, 'apply' => \$apply, 'csv' => \$csv,
            'inferred!' => \$include_inferred )
    or die "usage: $0 --sitename NAME [--apply] [--csv] [--no-inferred]\n";
die "--sitename is required\n" unless $site;

my $hk  = Comserv::Util::HealthKitchen->new;
my $s   = Comserv->model('DBEncy')->schema;
my $dbh = $s->storage->dbh;
my @F   = qw(food_category production animal_raising catch_method gmo);

my $items = $dbh->selectall_arrayref(
    q{SELECT id, name, category, barcode FROM inventory_items
      WHERE sitename = ? AND status = 'active' ORDER BY name}, { Slice => {} }, $site );
my @food = grep { ( $_->{category} // '' ) =~ /food|grocery|produce|pantry|herb|spice|beverage|supplement/i } @$items;

my $ci = $s->storage->connect_info->[0];
print STDERR 'DSN: ', ( ref $ci eq 'HASH' ? $ci->{dsn} : $ci ), "\nMODE: ", ( $apply ? 'APPLY' : 'DRY RUN (no writes)' ),
    "\nsite=$site active items=", scalar(@$items), ' food=', scalar(@food), "\n\n";

my ( %count, @plan );
for my $it (@food) {
    my $brand = $hk->brand_code( $it->{name} );
    my $p = $hk->classify_sourcing( { name => $it->{name}, category => $it->{category}, brand => $brand } );
    $count{ $p->{confidence} }++;
    push @plan, { %$it, brand => $brand, %$p };
}

if ($csv) {
    print join( ',', 'id', 'name', 'brand', 'barcode', @F, 'confidence', 'notes' ), "\n";
    for my $r (@plan) {
        my $notes = join '; ', map { "$_=$r->{why}{$_}" } sort keys %{ $r->{why} };
        print join( ',', map { my $v = $_ // ''; $v =~ s/"/""/g; $v =~ /[,"]/ ? qq{"$v"} : $v }
            $r->{id}, $r->{name}, $r->{brand}, $r->{barcode}, @$r{@F}, $r->{confidence}, $notes ), "\n";
    }
}
else {
    printf "%-4s %-40s %-5s %-12s %-17s %-10s %-6s %-16s %s\n", qw(id name brand category production raising catch gmo conf);
    for my $r (@plan) {
        printf "%-4s %-40.40s %-5s %-12s %-17s %-10s %-6s %-16s %s\n", $r->{id}, $r->{name}, $r->{brand} // '-',
            map( { $_ // '-' } @$r{@F} ), $r->{confidence};
    }
}
printf STDERR "\nexplicit=%d inferred-only=%d unknown=%d\n", map { $count{$_} || 0 } qw(explicit inferred unknown);

exit 0 unless $apply;

# ---- APPLY ----
# Writes Accounting::InventoryItemAttributes (inventory_item_attributes); food
# category is stored as an inventory_categories id from the shared tree.
my $ok = eval { $s->resultset('Accounting::InventoryItemAttributes')->search( {}, { rows => 1 } )->first; 1 };
die "inventory_item_attributes table not present; run Admin > Schema Compare (Accounting::InventoryItemAttributes) first. Nothing written.\n" unless $ok;
require Comserv::Util::CategoryManager;
my $cm = Comserv::Util::CategoryManager->new;
my $rs = $s->resultset('Accounting::InventoryItemAttributes');
my ( $ins, $upd ) = ( 0, 0 );
$s->txn_do( sub {
    my %cat_id = map { $_->{path} => $_->{id} } @{ $cm->options_for_site( $s, $site, { brew => 1, '3d' => 1 } ) };
    for my $r (@plan) {
        next if $r->{confidence} eq 'unknown';
        next if !$include_inferred && $r->{confidence} ne 'explicit';
        my %set = map { $_ => $r->{$_} } grep { $_ ne 'food_category' && defined $r->{$_} } @F;
        if ( defined $r->{food_category} ) {
            my $path = $cm->path_for_food_key( $r->{food_category} );
            $set{food_category_id} = $cat_id{$path} if $path && $cat_id{$path};
        }
        next unless %set;
        my $row = $rs->search( { item_id => $r->{id} } )->single;
        if ($row) {
            my %fill = map { $_ => $set{$_} } grep { !defined $row->get_column($_) } keys %set;
            if (%fill) { $row->update( \%fill ); $upd++ }
        }
        else {
            $rs->create( { sitename => $site, item_id => $r->{id}, %set } );
            $ins++;
        }
    }
} );
print STDERR "APPLIED: created $ins, filled $upd inventory_item_attributes row(s)\n";
