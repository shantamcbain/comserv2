use strict; use warnings;
use Test::More;
use lib 'lib';
use Comserv::Util::CategoryManager;
my $cm = Comserv::Util::CategoryManager->new;
my @flat = ( { id => 1, name => 'Food' }, { id => 2, name => 'Meat', parent_id => 1 },
    { id => 3, name => 'Beef', parent_id => 2 }, { id => 4, name => 'Brewing' }, { id => 5, name => 'Hop', parent_id => 4 },
    { id => 6, name => '3D Printing' }, { id => 7, name => 'Other', sort_order => 9 } );
my $o = $cm->path_options( \@flat, {} );
is_deeply [ map { $_->{path} } @$o ], [ 'Food', 'Food > Meat', 'Food > Meat > Beef', 'Other' ], 'brewing/3d hidden without modules';
$o = $cm->path_options( \@flat, { brew => 1 } );
ok( ( grep { $_->{path} eq 'Brewing > Hop' } @$o ), 'brewing visible with brew module' );
ok( !( grep { $_->{path} eq '3D Printing' } @$o ), '3d still hidden' );
ok( ( grep { $_->{path} eq '3D Printing' } @{ $cm->path_options( \@flat, { '3d' => 1 } ) } ), '3d visible with 3d module' );
is $cm->food_key_for_path('Food > Meat > Beef'), 'beef', 'beef key';
is $cm->food_key_for_path('Food > Dairy > Yogurt'), 'dairy', 'yogurt -> dairy';
is $cm->food_key_for_path('Supplements > Herbal Oil'), undef, 'non-food no key';
is $cm->path_for_food_key('beef'), 'Food > Meat > Beef', 'key -> path';
is $cm->path_for_food_key('fish_other'), 'Food > Seafood', 'fish_other -> first match';
is $cm->path_for_food_key('leafy_greens'), 'Food > Produce > Leafy Greens', 'greens path';
require Comserv::Util::HealthKitchen;
my $hk = Comserv::Util::HealthKitchen->new;
is $hk->barcode_type_for('620365041595'), 'upc', '12 -> upc';
is $hk->barcode_type_for('0620365041595'), 'ean', '13 -> ean';
my ( $v, $e ) = $hk->validate_sourcing( { food_category_id => '12', production => 'organic_certified' } );
is $v->{food_category_id}, 12, 'category id accepted';
( $v, $e ) = $hk->validate_sourcing( { food_category_id => '1; drop' } );
ok $e, 'bad category id rejected';
done_testing;
