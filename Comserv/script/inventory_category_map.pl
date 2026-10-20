#!/usr/bin/env perl
# Map existing free-text inventory_items.category values onto the shared category tree.
#   perl script/inventory_category_map.pl                 # DRY RUN, all sites (read-only)
#   perl script/inventory_category_map.pl --sitename X    # DRY RUN, one site
# Read-only: prints the proposed path per distinct (site, category). No --apply yet;
# applying needs the starter tree seeded (opening /Inventory/item/add does that) and approval.
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Getopt::Long;
use Comserv;
use Comserv::Util::CategoryManager;

my $site;
GetOptions( 'sitename=s' => \$site );
my $cm  = Comserv::Util::CategoryManager->new;
my $dbh = Comserv->model('DBEncy')->schema->storage->dbh;

# lc free-text pattern => tree path. First match wins.
my @RULES = (
    [ qr/^3d[_ ]?filament|filament/i      => '3D Printing > Filament' ],
    [ qr/^3d[_ ]?printer$/i               => '3D Printing > Printer' ],
    [ qr/^3d[_ ]?printed|\bprinted\b/i                => '3D Printing > Printed Item' ],
    [ qr/^3d/i                            => '3D Printing > Supply' ],
    [ qr/brew.*grain|malt/i               => 'Brewing > Grain' ],
    [ qr/hop/i                            => 'Brewing > Hop' ],
    [ qr/yeast/i                          => 'Brewing > Yeast' ],
    [ qr/brew.*(bottle|keg|pack)/i        => 'Brewing > Packaging' ],
    [ qr/brew.*kit/i                      => 'Brewing > Kit' ],
    [ qr/^brew/i                          => 'Brewing > Adjunct' ],
    [ qr/herbal ?oil|essential oil/i      => 'Supplements > Herbal Oil' ],
    [ qr/vitamin/i                        => 'Supplements > Vitamins' ],
    [ qr/supplement|tincture|extract/i    => 'Supplements > Other Supplement' ],
    [ qr/^(herb|spice)s?$|herbs? ?& ?spice|culinary herb/i => 'Food > Herbs & Spices' ],
    [ qr/produce|vegetable|fruit/i        => 'Food > Produce > Other Produce' ],
    [ qr/dairy|milk|yogurt|cheese/i       => 'Food > Dairy' ],
    [ qr/meat|beef/i                      => 'Food > Meat' ],
    [ qr/fish|seafood/i                   => 'Food > Seafood' ],
    [ qr/beverage|drink|juice|tea|coffee/i => 'Food > Beverages' ],
    [ qr/snack|candy|sweet|ice ?cream/i   => 'Food > Snacks & Sweets' ],
    [ qr/grain|flour|cereal/i             => 'Food > Grains' ],
    [ qr/^food|grocer|pantry/i            => 'Food' ],
    [ qr/kitchen/i                        => 'Kitchen' ],
    [ qr/garden|seed|apiary|bee/i         => 'Garden' ],
    [ qr/hardware|tool|equipment|electronic/i => 'Hardware' ],
    [ qr/service/i                        => 'Services' ],
);

my $sql = q{SELECT sitename, COALESCE(category,'') AS category, COUNT(*) AS n FROM inventory_items }
        . ( $site ? q{WHERE sitename = ? } : '' ) . q{GROUP BY sitename, category ORDER BY sitename, n DESC};
my $rows = $dbh->selectall_arrayref( $sql, { Slice => {} }, ( $site ? $site : () ) );
my %tot;
printf "%-12s %-32s %5s  %s\n", qw(site category items proposed_path);
for my $r (@$rows) {
    my $cat  = $r->{category};
    my ($p)  = map { $_->[1] } grep { $cat =~ $_->[0] } @RULES;
    $p     //= length $cat ? 'Other' : '(blank -> Other)';
    $p       = "$p  [as-is: already a tree path]" if $cat =~ / > /;
    $tot{ $p =~ /^Other|blank/ ? 'other' : 'mapped' } += $r->{n};
    printf "%-12.12s %-32.32s %5d  %s\n", $r->{sitename}, $cat, $r->{n}, $p;
}
printf STDERR "\nDRY RUN (no writes). items mapped=%d, to Other/blank=%d, distinct values=%d\n",
    $tot{mapped} || 0, $tot{other} || 0, scalar @$rows;
