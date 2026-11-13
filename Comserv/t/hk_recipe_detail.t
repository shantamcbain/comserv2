use strict;
use warnings;
use lib 'lib', 't/lib';
use Test::More;
use Comserv::Util::HealthKitchen::RecipeDetail;

my $RD = 'Comserv::Util::HealthKitchen::RecipeDetail';

is_deeply $RD->steps_from_text(undef), [], 'empty steps';
is_deeply $RD->steps_from_text('   '), [], 'blank steps';
is_deeply $RD->steps_from_text(
    "Brown hamburger with onion, drain fat. Layer noodles; bake covered 45 min."
), [
    'Brown hamburger with onion, drain fat.',
    'Layer noodles',
    'bake covered 45 min.',
], 'sentence and semicolon split';
is_deeply $RD->steps_from_text("1. Toast the bread\n2. Top with sardines"),
    [ 'Toast the bread', 'Top with sardines' ], 'numbered lines';

is_deeply [ $RD->plant_form('Rolled oats') ], [ 'oats', 'rolled' ], 'rolled oats is oats, rolled';
is_deeply [ $RD->plant_form('Hemp hearts') ], [ 'hemp', 'hearts' ], 'hemp hearts is hemp, hulled';
is_deeply [ $RD->plant_form('Spinach') ], [], 'a plain plant is not a process';
ok grep { $_ eq 'oats' || $_ eq 'oat' } $RD->name_queries('Rolled oats'), 'rolled oats also searches the plant';
ok grep { $_ eq 'hemp' } $RD->name_queries('Hemp hearts'), 'hemp hearts also searches hemp';
is_deeply [ $RD->name_queries('Dried oregano or basil') ],
    [ 'Dried oregano or basil', 'oregano', 'basil', 'oregano or basil' ], 'or-split and dried stripped on the parts';
is_deeply [ $RD->name_queries('Hamburger (lean ground beef)') ],
    [ 'Hamburger (lean ground beef)', 'Hamburger', 'lean ground beef', 'hamburger lean beef' ], 'parenthetical keys';

ok $RD->token_eq('Spinach, garden', 'spinach'), 'comma token matches';
ok !$RD->token_eq('Coriander', 'corn'), 'substring is not a match';

my $hit = $RD->pick_match(
    ['spinach'],
    [ { id => 4, type => 'herb', common_names => 'Spinach, garden' },
      { id => 9, type => 'herb', common_names => 'Coriander' } ]
);
is $hit->{id}, 4, 'exact herb token wins';

ok !$RD->pick_match(
    [ 'oregano', 'basil' ],
    [ { id => 1, type => 'herb', common_names => 'Oregano' },
      { id => 2, type => 'herb', common_names => 'Basil' } ]
), 'two different hits are not auto-linked';

ok !$RD->pick_match( ['pasta'], [ { id => 3, type => 'herb', common_names => 'Pasta sauce' } ] ),
    'pasta does not match pasta sauce';

done_testing;
