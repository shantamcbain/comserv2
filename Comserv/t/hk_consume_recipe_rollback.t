use strict; use warnings; use lib 'lib';
use Test::More;
use Comserv::Util::HealthKitchen;
my $HK = 'Comserv::Util::HealthKitchen';

our %STORE;
{ package FTx; sub new { bless {}, shift }
  sub txn_do { my ($s,$code)=@_; my %snap = %main::STORE; my @r = eval { $code->() };
    if ($@) { %main::STORE = %snap; die $@ } @r }
  sub resultset { FRecRS->new } }
{ package FLine; sub new { my ($c,%a)=@_; bless {%a}, $c } our $AUTOLOAD;
  sub AUTOLOAD { my $s=shift; (my $n=$AUTOLOAD)=~s/.*:://; return if $n eq 'DESTROY'; $s->{$n} } }
{ package FRecipe; sub new { bless {}, shift } sub id { 1 } sub name { 'Test recipe' } sub recipe_code { 'R1' }
  sub lines { map { FLine->new(%$_) } @main::LINES } }
{ package FRecRS; sub new { bless {}, shift } sub search { $_[0] } sub single { FRecipe->new } sub next { FRecipe->new } }
{ package FC; sub new { bless {}, shift } sub model { FTx->new } sub config { {} }
  sub session { { username => 'Shanta', user_id => 178 } } sub stash { {} } }
our @LINES;

no warnings 'redefine';
*Comserv::Util::HealthKitchen::recipe_ready       = sub { 1 };
*Comserv::Util::HealthKitchen::site_has_inventory = sub { 0 };
*Comserv::Util::HealthKitchen::sitename           = sub { 'Shanta' };
*Comserv::Util::HealthKitchen::logging            = sub { bless {}, 'FLog' };
{ package FLog; sub log_with_details {} }
our $MODE = 'return';
*Comserv::Util::HealthKitchen::_deduct_pantry = sub {
  my ($self, $c, $name, $need) = @_;
  return { ok => 0, error => 'No pantry row named ' . $name } if $name eq 'Missing' && $MODE eq 'return';
  die "DB exploded\n" if $name eq 'Missing';
  $main::STORE{$name} -= $need; return { ok => 1 };
};
my $hk = bless {}, $HK;

@LINES = ( { name_raw => 'Oats', quantity => 2, unit => 'cup' }, { name_raw => 'Missing', quantity => 1, unit => 'x' } );
%STORE = ( Oats => 10 );
my $r = $hk->consume_recipe(FC->new, 1, 1);
ok !$r->{ok}, 'failure on line 2 => not ok';
ok $r->{rolled_back}, 'reported as rolled back';
is $STORE{Oats}, 10, 'line 1 deduction undone';
is_deeply $r->{deducted}, [], 'UI gets nothing deducted';
like $r->{error}, qr/Nothing deducted .*Missing: No pantry row/, 'error names the failing line';

$MODE = 'die'; %STORE = ( Oats => 10 );
$r = $hk->consume_recipe(FC->new, 1, 1);
ok !$r->{ok} && $STORE{Oats} == 10, 'helper die on line 2 also rolls back line 1';

@LINES = ( { name_raw => 'Oats', quantity => 2, unit => 'cup' }, { name_raw => 'Salt', quantity => undef } );
%STORE = ( Oats => 10 );
$r = $hk->consume_recipe(FC->new, 1, 3);
ok $r->{ok}, 'all deductions ok => ok';
is $STORE{Oats}, 4, 'batches applied (2 x 3)';
is $r->{skipped}[0]{reason}, 'no numeric quantity', 'no-quantity line reported, not a failure';

my $js = do { local $/; open my $h,'<','root/static/js/healthkitchen/recipe-confirm.js' or die; <$h> };
like $js, qr/All-or-nothing: a failed make deducts nothing/, 'UI shows all-or-nothing failure';
done_testing;
