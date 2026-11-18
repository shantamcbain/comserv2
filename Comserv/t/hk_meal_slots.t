use strict; use warnings; use lib 'lib', 't/lib';
use Test::More;
use HKFake;
use Comserv::Util::HealthKitchen::MealSlots;
use Comserv::Util::UserPreferences;
my $MS = 'Comserv::Util::HealthKitchen::MealSlots';
no warnings 'redefine', 'once';

# --- validation
my $ok = $MS->clean_slots([ { key => 'b', kind => 'meal', label => 'B', start => '10:00', end => '10:30', plan_slots => ['breakfast'] },
                            { key => 'a', kind => 'drink', label => 'A', start => '05:00', end => '06:00', recipe_name => 'Morning beverage' } ]);
is_deeply [ map { $_->{key} } @$ok ], [qw(a b)], 'sorted by start';
ok !$MS->clean_slots($_->[1]), "reject $_->[0]" for
  [ 'empty', [] ], [ 'bad key', [ { key => 'Bad', kind => 'meal', label => 'x', start => '01:00', end => '02:00' } ] ],
  [ 'bad kind', [ { key => 'x', kind => 'snack', label => 'x', start => '01:00', end => '02:00' } ] ],
  [ 'end before start', [ { key => 'x', kind => 'meal', label => 'x', start => '05:00', end => '04:00' } ] ],
  [ 'bad time', [ { key => 'x', kind => 'meal', label => 'x', start => '25:00', end => '26:00' } ] ],
  [ 'html label', [ { key => 'x', kind => 'meal', label => '<b>', start => '01:00', end => '02:00' } ] ],
  [ 'dup key', [ map { { key => 'x', kind => 'meal', label => 'x', start => '01:00', end => '02:00' } } 1 .. 2 ] ],
  [ 'bad plan slot', [ { key => 'x', kind => 'meal', label => 'x', start => '01:00', end => '02:00', plan_slots => ['brunch'] } ] ];
ok $MS->valid_pref({ Shanta => $ok }), 'pref by site valid';
ok !$MS->valid_pref({ 'bad/site' => $ok }), 'bad site key';
ok !$MS->valid_pref([]), 'pref must be object';
ok( Comserv::Util::UserPreferences->new->validate_value('healthkitchen.meal_slots', { Shanta => $ok }), 'UserPreferences accepts key' );

# --- defaults = Shanta's schedule
my $c = HKFake::C->new(session => { user_id => 178, username => 'Shanta', SiteName => 'Shanta' });
local *Comserv::Util::UserPreferences::get = sub { undef };
my $d = $MS->slots_for($c);
is_deeply [ map { "$_->{key}\@$_->{start}" } @$d ], [qw(morning_beverage@05:00 coffee_1@06:00 coffee_2@06:15 breakfast@10:00 supper@16:00)], 'default slots';
local *Comserv::Util::UserPreferences::get = sub { { Shanta => [ { key => 'x', kind => 'meal', label => 'X', start => '07:00', end => '08:00' } ], Other => [] } };
is $MS->slots_for($c)->[0]{key}, 'x', 'user pref for this site used';
$c->{session}{SiteName} = 'CSC';
is $MS->slots_for($c)->[0]{key}, 'morning_beverage', 'other site -> defaults (site scoped)';
$c->{session}{SiteName} = 'Shanta';
local *Comserv::Util::UserPreferences::get = sub { undef };

# --- day(): recipes owner+site scoped, plan entries, logs, coffee count
%HKFake::DB = (
  Recipe => [
    HKFake::Row->new(id => 1, name => 'Morning beverage', sitename => 'Shanta', username_of_poster => 'Shanta', _lines => [ HKFake::Row->new(sort_order => 1, name_raw => 'Turmeric', quantity => 16, unit => 'g') ]),
    HKFake::Row->new(id => 2, name => 'Oats', sitename => 'Shanta', username_of_poster => 'Shanta', _lines => []),
    HKFake::Row->new(id => 3, name => 'Coffee', sitename => 'Shanta', username_of_poster => 'Mallory', _lines => []),
    HKFake::Row->new(id => 4, name => 'Stew', sitename => 'CSC', username_of_poster => 'Shanta', _lines => []),
  ],
  'HealthKitchen::MealPlanEntry' => [
    HKFake::Row->new(id => 11, plan_date => '2026-11-09', meal_slot => 'breakfast', recipe_id => 2, meal_plan_id => 7, user_id => 178, sitename => 'Shanta', status => 'draft'),
    HKFake::Row->new(id => 12, plan_date => '2026-11-09', meal_slot => 'dinner', recipe_id => 4, user_id => 178, sitename => 'Shanta', status => 'draft'),
    HKFake::Row->new(id => 13, plan_date => '2026-11-09', meal_slot => 'dinner', recipe_id => 2, user_id => 999, sitename => 'Shanta', status => 'draft'),
  ],
  'HealthKitchen::IntakeLog' => [
    HKFake::Row->new(id => 1, user_id => 178, sitename => 'Shanta', log_date => '2026-11-09', kind => 'drink', slot_key => 'coffee_1', food_name => 'Coffee', source => 'slot', started_at => '2026-11-09T06:02:00', ended_at => '2026-11-09T06:10:00', duration_min => 8),
    HKFake::Row->new(id => 2, user_id => 178, sitename => 'Shanta', log_date => '2026-11-09', kind => 'drink', food_name => 'Coffee (out)', source => 'drink_out', location => 'Cafe'),
    HKFake::Row->new(id => 3, user_id => 178, sitename => 'Shanta', log_date => '2026-11-09', kind => 'meal', slot_key => 'breakfast', food_name => 'Oats', source => 'slot', started_at => '2026-11-09T10:20:00'),
    HKFake::Row->new(id => 4, user_id => 999, sitename => 'Shanta', log_date => '2026-11-09', kind => 'drink', food_name => 'Coffee (out)', source => 'drink_out'),
  ],
);
$HKFake::WRITES = 0;
my $day = $MS->day($c, '2026-11-09');
my %s = map { $_->{key} => $_ } @{ $day->{slots} };
is $s{morning_beverage}{recipes}[0]{name}, 'Morning beverage', 'drink default recipe';
is_deeply $s{morning_beverage}{recipes}[0]{ingredients}, ['16 g Turmeric'], 'ingredients';
is scalar @{ $s{coffee_1}{recipes} }, 0, "other owner's Coffee recipe not used";
is $s{breakfast}{recipes}[0]{name}, 'Oats', 'breakfast from own plan';
is $s{breakfast}{title}, 'Oats', 'card title is the dish, not the slot label';
is $s{breakfast}{plan_url}, '/healthkitchen/mealplan/7', 'title links to that meal plan';
is $s{supper}{title}, 'Supper', 'no owned recipe keeps the slot label';
is scalar @{ $s{supper}{recipes} }, 0, 'cross-site recipe and other user plan ignored';
ok $s{coffee_1}{done} && $s{coffee_1}{duration} == 8, 'done + duration from log';
is $s{breakfast}{started}, '10:20', 'open start shown';
is $day->{coffees}, 2, 'coffees: slot done + out (not other user)';
is scalar @{ $day->{drinks_out} }, 1, 'own drinks out only';
ok $day->{timing_ready}, 'timing ready';
is $HKFake::WRITES, 0, 'day() wrote nothing';
local $HKFake::MISSING{'HealthKitchen::IntakeLog'} = 1;
ok !$MS->day($c, '2026-11-09')->{timing_ready}, 'timing_ready=0 when IntakeLog columns missing';

# --- time-shift suggestion
is $MS->median(5, 1, 3), 3, 'median odd'; is $MS->median(1, 2, 3, 4), 2, 'median even (floor)';
my $sl = [ { key => 'breakfast', label => 'Breakfast', start => '10:00' }, { key => 'supper', label => 'Supper', start => '16:00' } ];
my $sug = $MS->suggest_from_starts($sl, { breakfast => [qw(10:20 10:30 10:25 10:40)], supper => [qw(16:05 16:10 15:55)] });
is scalar @$sug, 1, 'only slots >= 15 min off';
is_deeply [ @{ $sug->[0] }{qw(key from to n)} ], [ 'breakfast', '10:00', '10:27', 4 ], 'breakfast -> 10:27 median';
is scalar @{ $MS->suggest_from_starts($sl, { breakfast => [qw(11:00 11:00)] }) }, 0, 'needs >= 3 logs';
done_testing;
