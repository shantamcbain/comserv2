use strict;
use warnings;
use Test::More;
use lib 'lib';
use Comserv::Util::HealthKitchen;

my $hk = Comserv::Util::HealthKitchen->new;

my $data = {
    symptom_ids     => [1],
    pantry_herb_ids => [10, 20],
    herbs           => {
        10 => { name => 'Turmeric', contra_indications => '' },
        20 => { name => 'Willow',   contra_indications => 'ulcer' },
        30 => { name => 'Off-pantry mint', contra_indications => '' },
    },
    herb_symptoms => [
        { herb_id => 10, symptom_id => 1, relationship_type => 'treats' },
        { herb_id => 20, symptom_id => 1, relationship_type => 'contraindicated' },
        { herb_id => 30, symptom_id => 1, relationship_type => 'treats' },
    ],
    formulas => [
        { id => 1, name => 'Golden milk', herb_ids => [10] },
        { id => 2, name => 'Needs mint',  herb_ids => [10, 30] },
    ],
    drug_herb     => [ { herb_id => 10, drug_id => 99 } ],
    user_drug_ids => [],
};

my $got = $hk->match_candidates($data);
is( scalar @{ $got->{herbs} }, 1, 'only in-pantry treating herb' );
is( $got->{herbs}[0]{herb_id}, 10, 'turmeric kept' );
is( scalar @{ $got->{formulas} }, 1, 'formula requiring off-pantry herb dropped' );
is( $got->{formulas}[0]{formula_id}, 1, 'golden milk kept' );

$data->{user_drug_ids} = [99];
$got = $hk->match_candidates($data);
is( scalar @{ $got->{herbs} }, 0, 'drug-herb conflict drops turmeric' );
is( scalar @{ $got->{formulas} }, 0, 'formula dropped when herb blocked' );

$got = $hk->match_candidates({
    symptom_ids     => [1],
    pantry_herb_ids => [],
    herb_symptoms   => [ { herb_id => 10, symptom_id => 1, relationship_type => 'treats' } ],
    herbs           => { 10 => { name => 'Turmeric' } },
});
is( scalar @{ $got->{herbs} }, 0, 'empty pantry never invents stock' );

$got = $hk->match_for_symptoms( undef, { dataset => $data } );
is( ref $got->{herbs}, 'ARRAY', 'match_for_symptoms dataset passthrough' );

done_testing;
