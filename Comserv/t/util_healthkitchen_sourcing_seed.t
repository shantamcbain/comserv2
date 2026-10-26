use strict;
use warnings;
use Test::More;
use lib 'lib';
use Comserv::Util::HealthKitchen;
use Comserv::Util::HealthKitchen::SourcingSeed;

my $hk   = Comserv::Util::HealthKitchen->new;
my $seed = Comserv::Util::HealthKitchen::SourcingSeed::rows();

is scalar(@$seed), 21, '21 seed rows';
ok !( grep { !$_->{citation} } @$seed ), 'every row cited';
my %k; $k{ join '|', @$_{qw(food_category attribute attr_value)} }++ for @$seed;
is scalar( keys %k ), 21, 'unique keys';
my %enum = %{ $hk->sourcing_enums };
for my $r (@$seed) {
    next if $r->{attribute} eq 'local';
    ok( ( grep { $_ eq $r->{attr_value} } @{ $enum{ $r->{attribute} } } ), "enum ok: $r->{attribute}=$r->{attr_value}" );
    ok( $r->{food_category} eq 'any' || grep( { $_ eq $r->{food_category} } @{ $enum{food_category} } ),
        "category ok: $r->{food_category}" );
}

is scalar( @{ $hk->missing_seed_rows( [], $seed ) } ), 21, 'empty table -> all missing';
is scalar( @{ $hk->missing_seed_rows( $seed, $seed ) } ), 0, 'full table -> none';
my $m = $hk->missing_seed_rows( [ { food_category => 'BEEF', attribute => 'animal_raising', attr_value => 'grass_fed' } ], $seed );
is scalar(@$m), 20, 'key match is case-insensitive';

# --- ensure_sourcing_seed with a mock schema ---
{
    package MockRow;  sub new { bless { %{ $_[1] } }, $_[0] } sub get_columns { %{ $_[0] } }
    package MockRS;
    sub new { bless { rows => $_[1], creates => 0 }, $_[0] }
    sub search { $_[0] } sub count { scalar @{ $_[0]{rows} } }
    sub first { $_[0]{rows}[0] }
    sub all { map { MockRow->new($_) } @{ $_[0]{rows} } }
    sub find_or_create { my ( $s, $r ) = @_; push @{ $s->{rows} }, {%$r}; $s->{creates}++; MockRow->new($r) }
    package MockModel; sub new { bless { rs => $_[1] }, $_[0] } sub resultset { $_[0]{rs} }
    sub source { 1 } sub schema { $_[0] }
    package MockC;
    sub new { bless { m => $_[1], stash => {} }, $_[0] } sub model { $_[0]{m} } sub stash { $_[0]{stash} }
    sub session { {} }
}
no warnings 'redefine';
local *Comserv::Util::HealthKitchen::factor_ready = sub { 1 };
local *Comserv::Util::HealthKitchen::logging = sub { bless {}, 'MockLog' };
{ package MockLog; sub log_with_details { } }

my $rs = MockRS->new( [ { food_category => 'beef', attribute => 'animal_raising', attr_value => 'grass_fed', ethics_score => 5 } ] );
my $c  = MockC->new( MockModel->new($rs) );
$Comserv::Util::HealthKitchen::SOURCING_SEEDED = 0;
my $r = $hk->ensure_sourcing_seed($c);
ok $r->{ok}, 'seed ok';
is $r->{inserted}, 20, 'inserted only the 20 missing rows';
is scalar( @{ $rs->{rows} } ), 21, 'table now complete';
is $rs->{rows}[0]{ethics_score}, 5, 'existing row not overwritten';
$r = $hk->ensure_sourcing_seed($c);
is $r->{inserted}, 0, 'second call is a no-op';

$Comserv::Util::HealthKitchen::SOURCING_SEEDED = 0;
local *Comserv::Util::HealthKitchen::factor_ready = sub { 0 };
$r = $hk->ensure_sourcing_seed($c);
is $r->{skipped}, 'table missing', 'no table -> no writes, not marked seeded';
is $Comserv::Util::HealthKitchen::SOURCING_SEEDED, 0, 'will retry later';

done_testing;
