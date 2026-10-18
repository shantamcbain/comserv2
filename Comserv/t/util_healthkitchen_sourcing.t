use strict;
use warnings;
use Test::More;
use lib 'lib';
use JSON qw(encode_json);
use Comserv::Util::HealthKitchen;

my $hk = Comserv::Util::HealthKitchen->new;

# --- validation via allowed enums ---
my ( $v, $e ) = $hk->validate_sourcing( { food_category => 'beef', production => 'Organic_Certified',
    animal_raising => 'grass_fed', catch_method => '', gmo => 'unknown', local_km => '45',
    certifier => 'Pro-Cert Organic', cert_verified => 'on' } );
is $e, undef, 'valid sourcing';
is $v->{production}, 'organic_certified', 'lower-cased enum';
is $v->{catch_method}, undef, 'empty -> undef';
is $v->{local_km}, 45, 'km numeric';
is $v->{cert_verified}, 1, 'checkbox on';
for my $bad ( { production => 'bio' }, { animal_raising => 'feedlot; DROP' }, { gmo => 'maybe' },
              { food_category => 'unicorn' }, { local_km => '-3' }, { local_km => '1e5' }, { local_km => 30000 },
              { certifier => '<b>x</b>' . ( 'a' x 120 ) }, { certifier => 'Cert"quote' } ) {
    ( undef, $e ) = $hk->validate_sourcing($bad);
    ok $e, 'rejected ' . join( ',', %$bad ) =~ s/[^\x20-\x7e]//gr;
}
( $v, $e ) = $hk->validate_sourcing( { certifier => '<i>USDA</i> Organic' } );
is $v->{certifier}, 'USDA Organic', 'certifier HTML stripped';

# --- prefs ---
( $v, $e ) = $hk->validate_prefs( {} );
is_deeply $v, { prefer_organic => 0, avoid_feedlot => 0, ethics_weight => 0 }, 'defaults: ethics weight 0';
( $v, $e ) = $hk->validate_prefs( { prefer_organic => 1, avoid_feedlot => 'on', ethics_weight => 3 } );
is_deeply $v, { prefer_organic => 1, avoid_feedlot => 1, ethics_weight => 3 }, 'prefs set';
( undef, $e ) = $hk->validate_prefs( { ethics_weight => 9 } );
like $e, qr/0-5/, 'weight range';

# --- factors ---
my @F = (
    { food_category => 'beef', attribute => 'animal_raising', attr_value => 'grass_fed',
      nutrient_adj_json => encode_json( { fat_g => -15, calories => -8, omega3 => 100 } ),
      antibiotic_risk => 'low', hormone_risk => 'low', ethics_score => 4, citation => 'Daley 2010' },
    { food_category => 'beef', attribute => 'animal_raising', attr_value => 'feedlot',
      nutrient_adj_json => encode_json( { fat_g => 10 } ), antibiotic_risk => 'med', hormone_risk => 'high',
      ethics_score => 1, citation => 'FDA' },
    { food_category => 'beef', attribute => 'production', attr_value => 'organic_certified',
      antibiotic_risk => 'low', ethics_score => 3, citation => 'NOP' },
    { food_category => 'any', attribute => 'local', attr_value => 'local', ethics_score => 4, citation => 'EJ' },
    { food_category => 'leafy_greens', attribute => 'production', attr_value => 'conventional',
      pesticide_risk => 'high', ethics_score => 2, citation => 'EWG' },
);
my $gf = { food_category => 'beef', animal_raising => 'grass_fed', production => 'organic_certified', local_km => 50 };
my $m = $hk->match_factors( $gf, \@F );
is scalar(@$m), 3, 'grass-fed organic local beef matches 3 factors';
is scalar( @{ $hk->match_factors( { food_category => 'pork', animal_raising => 'grass_fed' }, \@F ) } ), 0,
    'category must match';
is scalar( @{ $hk->match_factors( { food_category => 'pork', local_km => 500 }, \@F ) } ), 0, 'not local > 160km';

my $base = { calories => 250, protein_g => 26, fat_g => 15, carbs_g => 0, fiber_g => undef, sugar_g => 0, sodium_mg => 70 };
my %copy = %$base;
my $adj = $hk->adjust_nutrients( $base, $m );
is $adj->{fat_g}, 12.75, 'fat -15%';
is $adj->{calories}, 230, 'calories -8%';
is $adj->{protein_g}, 26, 'unadjusted nutrient kept';
is $adj->{fiber_g}, undef, 'undef base stays undef';
ok $adj->{estimate}, 'flagged estimate';
ok !exists $adj->{omega3}, 'non-base nutrient ignored';
is_deeply $base, \%copy, 'base never modified';
is $hk->adjust_nutrients( $base, [] ), undef, 'no factors -> no estimate';

my $sum = $hk->sourcing_summary($m);
is $sum->{risks}{antibiotic}, 'low', 'antibiotic low';
is $sum->{contamination}, 0, 'no contamination points';
is $sum->{ethics}, 3.7, 'mean ethics';
my $fl = { food_category => 'beef', animal_raising => 'feedlot' };
my $fsum = $hk->sourcing_summary( $hk->match_factors( $fl, \@F ) );
is $fsum->{contamination}, 3, 'feedlot: med antibiotic + high hormone = 3';

# --- scoring ---
is $hk->sourcing_score( $gf, $sum, {} ), 0, 'default prefs + no contamination -> neutral';
is $hk->sourcing_score( $fl, $fsum, {} ), -1.5, 'contamination penalty applies regardless of prefs';
cmp_ok $hk->sourcing_score( $gf, $sum, { ethics_weight => 5 } ), '>', 0, 'ethics weight rewards good ethics';
cmp_ok $hk->sourcing_score( $fl, $fsum, { ethics_weight => 5 } ), '<', -1.5, 'ethics weight penalises feedlot';
is $hk->sourcing_score( $fl, $fsum, { avoid_feedlot => 1 } ), -4.5, 'avoid feedlot';
is $hk->sourcing_score( { production => 'organic_certified' }, {}, { prefer_organic => 1 } ), 1, 'prefer organic';
is $hk->sourcing_score( { production => 'conventional' }, {}, { prefer_organic => 1 } ), -0.5, 'conventional';

is_deeply $hk->sourcing_badges( { %$gf, certifier => 'Pro-Cert' } ),
    [ 'Organic', 'Grass-fed', 'Local', 'Cert: Pro-Cert (unverified)' ], 'badges';

# --- meal plan ranking uses sourcing score as a nudge ---
my @recipes = (
    { id => 1, name => 'Feedlot stew', yield_amount => 1, lines => [ { name => 'Beef A', quantity => 1, unit => 'kg' } ] },
    { id => 2, name => 'Grassfed stew', yield_amount => 1, lines => [ { name => 'Beef B', quantity => 1, unit => 'kg' } ] },
);
my @pantry = (
    { name => 'Beef A', qty => 2, unit => 'kg', product => { score => -4.5, badges => ['Feedlot'] } },
    { name => 'Beef B', qty => 2, unit => 'kg', product => { score => 1, badges => ['Grass-fed'] } },
);
my $rank = $hk->rank_recipes_by_stock( \@recipes, \@pantry );
is $rank->[0]{name}, 'Grassfed stew', 'better-sourced recipe ranks first when stock equal';
is $rank->[1]{sourcing_score}, -4.5, 'score exposed';
my $plain = $hk->rank_recipes_by_stock( \@recipes, [ map { { %$_, product => undef } } @pantry ] );
is $plain->[0]{name}, 'Feedlot stew', 'no sourcing data -> original order (name)';

my $req = $hk->plan_requirements( [ { servings => 1, recipe => $recipes[1] } ], \@pantry );
is_deeply $req->{have}[0]{sourcing}, ['Grass-fed'], 'shopping/have list carries badges';

# --- AI prompt ---
my $foods = $hk->ai_stock_foods( [ { inventory_item_id => 5, name => 'Beef B', qty => 1, unit => 'kg',
                                     product => { badges => [ 'Grass-fed', 'Local' ], score => 1 } } ] );
is $foods->[0]{sourcing}, 'Grass-fed, Local', 'ai food carries sourcing';
my $p0 = $hk->ai_recipe_prompt( $foods, 2, {} );
like $p0, qr/sourcing=Grass-fed, Local/, 'sourcing listed';
unlike $p0, qr/sourcing_score|prefer/i, 'no preference text by default';
my $p1 = $hk->ai_recipe_prompt( $foods, 2, { prefer_organic => 1, avoid_feedlot => 1, ethics_weight => 2 } );
like $p1, qr/prefer certified organic/, 'organic pref in prompt';
like $p1, qr/Avoid items marked Feedlot/, 'feedlot pref in prompt';
like $p1, qr/sourcing_score=1/, 'score given when prefs on';

done_testing;
