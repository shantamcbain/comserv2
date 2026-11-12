use strict; use warnings;
use Test::More;
use lib 'lib';
use Comserv::Util::HealthKitchen::WeekPlan;
my $W = 'Comserv::Util::HealthKitchen::WeekPlan';
no strict 'refs';
my @R = @{"${W}::RECIPES"}; my %ING = %{"${W}::ING"}; my %LABEL = %{"${W}::LABEL"}; my @WEEK = @{"${W}::WEEK"};
my %code = map { $_->{code} => 1 } @R;
ok @R >= 10 && @R <= 14, 'ten to fourteen recipes';
for my $r (@R) {
    ok $ING{ $_->[0] } && $LABEL{ $_->[0] }, "$r->{code}: ingredient $_->[0] known" for @{ $r->{ing} };
}
is scalar @WEEK, 7, 'seven days';
for my $d (@WEEK) {
    for my $s (qw(breakfast lunch dinner)) {
        ok( ( $_ eq 'MORNING' || $code{$_} ), "slot $s -> $_" ) for ref $d->{$s} ? @{ $d->{$s} } : $d->{$s};
    }
    is( ( ref $d->{breakfast} ? $d->{breakfast}[0] : '' ), 'MORNING', 'morning beverage daily' );
}
my $items = [ { id => 1, name => 'BLK Oats Reg Rolled Org' }, { id => 2, name => 'Potatoes' }, { id => 3, name => 'FRA Sweet Potato Churro Org' },
              { id => 4, name => 'PRO Onions Yellow/White (TILL)' }, { id => 5, name => 'Pasta Sauce (various)' } ];
is $W->can('match_item')->( 'oats', $items )->{id}, 1, 'oats matched';
is $W->can('match_item')->( 'potatoes', $items )->{id}, 2, 'potatoes not churro';
is $W->can('match_item')->( 'onion', $items )->{id}, 4, 'onion';
my ( $m, $gaps ) = $W->can('plan_ingredients')->($items);
my %g = map { $_->{key} => $_ } @$gaps;
ok $g{tuna} && !$g{tuna}{optional}, 'tuna is a required gap';
ok $g{garlic} && $g{garlic}{optional}, 'garlic only optional';
ok !$g{oats}, 'oats not a gap';
my ($bank) = grep { $_->{name} =~ /Potatoes/ } @{"${W}::FOOD_BANK"};
ok 'Potatoes' =~ $bank->{match} && 'FRA Sweet Potato Churro Org' !~ $bank->{match}, 'food bank potato match';
done_testing;
