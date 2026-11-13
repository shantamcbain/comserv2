use strict; use warnings; use lib 'lib', 't/lib';
use Test::More;
use HKFake;
use DateTime;
use Comserv::Util::HealthKitchen::MealLog;
use Comserv::Util::UserPreferences;
use Comserv::Util::AppTime;
my $ML = 'Comserv::Util::HealthKitchen::MealLog';
no warnings 'redefine', 'once';
local *Comserv::Util::UserPreferences::get = sub { undef };
my $NOW = DateTime->new(year => 2026, month => 11, day => 9, hour => 10, minute => 5);
local *Comserv::Util::AppTime::now_user_dt = sub { $NOW->clone };

%HKFake::DB = ( Recipe => [ HKFake::Row->new(id => 2, name => 'Oats', sitename => 'Shanta', username_of_poster => 'Shanta', _lines => []) ],
  'HealthKitchen::MealPlanEntry' => [ HKFake::Row->new(id => 11, plan_date => '2026-11-09', meal_slot => 'breakfast', recipe_id => 2, user_id => 178, sitename => 'Shanta', status => 'draft') ],
  'HealthKitchen::IntakeLog' => [] );
my $c = HKFake::C->new(session => { user_id => 178, username => 'Shanta', SiteName => 'Shanta' });
my $log = $HKFake::DB{'HealthKitchen::IntakeLog'};

my $r = $ML->slot_action($c, 'start', 'breakfast');
ok $r->{ok}, 'start ok';
my $row = $log->[-1];
is_deeply [ @$row{qw(user_id sitename log_date kind slot_key recipe_id meal_plan_entry_id food_name source started_at)} ],
  [ 178, 'Shanta', '2026-11-09', 'meal', 'breakfast', 2, 11, 'Oats', 'slot', '2026-11-09 10:05:00' ], 'start row scoped + recipe from own plan';
# DBIC would inflate; emulate
$row->{started_at} = $NOW->clone;
ok $ML->slot_action($c, 'start', 'breakfast')->{already}, 'second start reuses open row';
$NOW->add(minutes => 22);
ok $ML->slot_action($c, 'stop', 'breakfast')->{ok}, 'stop ok';
is $row->{duration_min}, 22, 'duration minutes';
is $row->{ended_at}, '2026-11-09 10:27:00', 'ended_at';
ok !$ML->slot_action($c, 'stop', 'breakfast')->{ok}, 'stop without start refused';
ok $ML->slot_action($c, 'done', 'coffee_1')->{ok}, 'done without start = instant row';
is $log->[-1]{duration_min}, 0, 'instant done duration 0';
is $log->[-1]{food_name}, 'Coffee', 'no own Coffee recipe -> label';
ok !$ML->slot_action($c, 'start', 'nope')->{ok}, 'unknown slot';
ok !$ML->slot_action($c, 'delete', 'breakfast')->{ok}, 'unknown action';
my $n = @$log;
ok $ML->slot_action($c, 'start', 'supper', { recipe_id => 999 })->{ok}, 'forged recipe id';
is $log->[-1]{recipe_id}, undef, 'forged recipe id not stored';

$r = $ML->drink_out($c, { what => 'Coffee', location => 'Cafe <x>' });
ok $r->{ok}, 'drink out';
is_deeply [ @{ $log->[-1] }{qw(kind source food_name location)} ], [ 'drink', 'drink_out', 'Coffee (out)', 'Cafe <x>' ], 'drink out row (escaped at render)';
my $hook = 0; local *Comserv::Util::HealthKitchen::MealLog::nutrition_estimate_hook = sub { $hook++ };
ok !$ML->meal_out($c, { description => '   ' })->{ok}, 'empty meal refused';
$r = $ML->meal_out($c, { description => "Salmon, rice\x07 and salad", location => 'Bistro' });
ok $r->{ok}, 'meal out';
is_deeply [ @{ $log->[-1] }{qw(kind source description location)} ], [ 'meal', 'meal_out', 'Salmon, rice and salad', 'Bistro' ], 'meal out stored, control chars stripped';
is $hook, 1, 'nutrition hook called';
$c->{session}{user_id} = undef;
ok !$ML->drink_out($c, {})->{ok}, 'logged out refused';
$c->{session}{user_id} = 178;
local $HKFake::CREATE_DIE = "Unknown column 'kind'\n";
ok !$ML->slot_action($c, 'done', 'coffee_2')->{ok}, 'missing columns -> clean error';
my $hk = do { local $/; open my $h, '<', 'lib/Comserv/Util/HealthKitchen/MealLog.pm' or die; <$h> };
unlike $hk, qr/->consume_recipe\(|InventoryStock|->_deduct/, 'quick adds never touch inventory';
done_testing;
