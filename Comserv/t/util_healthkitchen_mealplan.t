use strict;
use warnings;
use Test::More;
use Comserv::Util::HealthKitchen;

my $hk = Comserv::Util::HealthKitchen->new;
my $recipe = { id => 1, name => 'Oat bowl', yield_amount => 2, lines => [
    { name => 'Oats',  quantity => 200, unit => 'g', inventory_item_id => 10 },
    { name => 'Honey', quantity => 2,   unit => 'tbsp' },
    { name => 'Milk',  quantity => 500, unit => 'ml' },
] };
my $pantry = [
    { name => 'Rolled oats', qty => 1000, unit => 'g', inventory_item_id => 10 },
    { name => 'honey',       qty => 1,    unit => 'tbsp' },
    { name => 'Milk',        qty => 1,    unit => 'l' },
];
my $req = $hk->plan_requirements( [ { servings => 4, recipe => $recipe } ], $pantry );
my %buy  = map { $_->{name} => $_ } @{ $req->{buy} };
my %have = map { $_->{name} => $_ } @{ $req->{have} };
ok( $have{Oats}, 'oats matched by inventory_item_id and in stock' );
is( $have{Oats}{need}, 400, 'scaled by servings/yield' );
is( $buy{Honey}{buy}, 3, 'only the shortfall goes on the shopping list' );
ok( $have{Milk}{unit_mismatch}, 'unit mismatch flagged, not bought blindly' );
is( scalar @{ $req->{buy} }, 1, 'nothing in stock is on the shopping list' );

my $rank = $hk->rank_recipes_by_stock( [ $recipe, { id => 2, name => 'Saffron rice', lines => [ { name => 'Saffron', quantity => 1 } ] } ], $pantry );
is( $rank->[0]{name}, 'Oat bowl', 'recipe with most stock ranked first' );
done_testing;
