use strict;
use warnings;
use Test::More;
use lib 'lib';
use Comserv::Util::HealthKitchen;

my $hk = Comserv::Util::HealthKitchen->new;
sub cl { $hk->classify_sourcing( { name => $_[0], category => 'food', brand => $hk->brand_code( $_[0] ) } ) }

my $r = cl('BLK Oats Reg Rolled Org');
is $r->{food_category}, 'grains', 'oats -> grains';
is $r->{production}, 'organic_certified', 'Org -> organic';
is $r->{gmo}, 'non_gmo_verified', 'organic implies non-GMO';
is $r->{confidence}, 'explicit', 'explicit';

$r = cl('Grass Fed Beef Hamburger');
is_deeply [ @$r{qw(food_category animal_raising)} ], [ 'beef', 'grass_fed' ], 'grass fed beef';
$r = cl('Pasture Raised Eggs');
is_deeply [ @$r{qw(food_category animal_raising)} ], [ 'eggs', 'pasture' ], 'pasture eggs';
is cl('Free-Range Chicken Thighs')->{animal_raising}, 'free_range', 'free range';
is cl('Cage Free Eggs')->{animal_raising}, undef, 'cage-free is not caged';
is cl('Wild Sockeye Salmon')->{catch_method}, 'wild', 'wild salmon';
is cl('Farmed Atlantic Salmon')->{catch_method}, 'farmed', 'farmed salmon';
$r = cl('RAIN Sardines Spring Water');
is_deeply [ @$r{qw(food_category catch_method confidence)} ], [ 'fish_other', 'wild', 'inferred' ], 'sardines inferred wild';
is cl('Salmon Fillet')->{catch_method}, undef, 'salmon without label stays unknown';

$r = cl('Eggs Organic Feed');
is $r->{production}, undef, 'organic feed is not certified organic';
like $r->{why}{production_note}, qr/feed/, 'noted';
$r = cl('Eggs Non-GMO Feed');
is $r->{gmo}, 'non_gmo_verified', 'non-GMO';
is $r->{why}{gmo}, 'inferred', 'feed-only -> inferred';

is cl('YOGG Coconut Yogurt Original')->{food_category}, undef, 'coconut yogurt not dairy';
is cl('SAUG Yogurt Org')->{food_category}, 'dairy', 'yogurt dairy';
is cl('SOD CM Vanilla Bean')->{food_category}, undef, 'vanilla bean not legume';
is cl('EO Oats 1/2 & 1/2 Alternative')->{food_category}, undef, 'oat creamer not grains';
is cl('FRA Sweet Potato Churro Org')->{food_category}, undef, 'processed snack: no category';
is cl('FRA Sweet Potato Churro Org')->{production}, 'organic_certified', 'but organic still detected';
is cl('Sweet Potatoes')->{food_category}, undef, 'sweet potato is not potatoes factor';
is cl('YORK Chicken Pot Pie ORG')->{food_category}, undef, 'pot pie processed';
is cl('ORGM Ice Cream Chocolate')->{production}, undef, 'ORGM brand code is not "org"';
$r = cl('O Groc');
is $r->{confidence}, 'unknown', 'unclear -> unknown';
ok !grep( { defined $r->{$_} } qw(food_category production animal_raising catch_method gmo) ), 'all undef';

is $hk->brand_code('BLK Oats'), 'BLK', 'brand code';
is $hk->brand_code('Eggs Organic Feed'), undef, 'no brand';
is $hk->brand_code('O Meat'), undef, 'single letter not a brand';

# every proposed value is a valid enum
my $enum = $hk->sourcing_enums;
for my $n ( 'Grass Fed Beef', 'Wild Salmon', 'Organic Kale', 'Feedlot beef', 'Battery caged eggs', 'Non-GMO Tofu' ) {
    my $p = cl($n);
    for my $f ( keys %$enum ) {
        next unless defined $p->{$f};
        ok( ( grep { $_ eq $p->{$f} } @{ $enum->{$f} } ), "$n: $f=$p->{$f} valid" );
    }
}
done_testing;
