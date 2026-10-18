use strict; use warnings;
use Test::More;
use lib 'lib';
use Comserv::Util::Manufacturing::Costing;
my $C = 'Comserv::Util::Manufacturing::Costing';
my $s = $C->new->settings(undef);

is Comserv::Util::Manufacturing::Costing::ceil_to(1.00), 1.00, 'exact stays';
is Comserv::Util::Manufacturing::Costing::ceil_to(1.01), 1.05, 'up to .05';
is Comserv::Util::Manufacturing::Costing::ceil_to(1.051), 1.10, '1.051 -> 1.10';
is Comserv::Util::Manufacturing::Costing::ceil_to(12.345), 12.35, '12.345 -> 12.35';
is Comserv::Util::Manufacturing::Costing::ceil_to(0), 0, 'zero';

is Comserv::Util::Manufacturing::Costing::moving_average(0, 0, 1, 10), 10, 'first run';
is Comserv::Util::Manufacturing::Costing::moving_average(3, 4, 1, 8), 5, '(3*4+8)/4';
is Comserv::Util::Manufacturing::Costing::moving_average(2, undef, 2, 6), 6, 'no old cost ignores old qty';

cmp_ok abs(Comserv::Util::Manufacturing::Costing::with_scrap(9.5, 5) - 10), '<', 1e-9, 'yield 95%';
is Comserv::Util::Manufacturing::Costing::with_scrap(10, 0), 10, 'no scrap';

my $m = Comserv::Util::Manufacturing::Costing::labour_minutes($s, pre_sliced => 1, filament_changes => 2);
is $m->{slicing}, 0, 'pre-sliced skips slicing';
is $m->{filament_change}, 6, '2 changes x 3 min';
$m = Comserv::Util::Manufacturing::Costing::labour_minutes($s, actual => { collect_clean => 12 });
is $m->{collect_clean}, 12, 'logged minutes win';

my $b = Comserv::Util::Manufacturing::Costing::breakdown($s, quantity => 2, filament_cost => 1, machine_cost => 1,
    electricity_cost => 0, pre_sliced => 1);
is $b->{labour_total_minutes}, 12, 'default minutes: queue 2 + send 2 + maint 3 + clean 5';
cmp_ok abs($b->{total} - (2 + 12/60*38.46)/0.95), '<', 0.001, 'total with scrap';
cmp_ok abs($b->{unit_cost} - $b->{total}/2), '<', 0.0001, 'per unit';
is Comserv::Util::Manufacturing::Costing::selling_price($s, 10), 15.00, '50% markup';
is Comserv::Util::Manufacturing::Costing::selling_price($s, 10.01, 30), 13.05, 'item markup, round up';
done_testing;
