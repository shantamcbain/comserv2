use strict;
use warnings;
use Test::More;
use Comserv::Util::HealthKitchen;

{ package MockCrypto;
  sub encrypt { my ( $cl, $v, $ns ) = @_; die "ns\n" unless $ns eq 'healthkitchen'; return 'ENC:' . reverse $v }
  sub decrypt { my ( $cl, $v ) = @_; $v =~ s/^ENC://; return scalar reverse $v } }
my $hk = Comserv::Util::HealthKitchen->new( crypto => 'MockCrypto' );

# encryption helpers
my $e = $hk->_enc('Hypertension');
like( $e, qr/^ENC:/, 'encrypted with ENC: prefix' );
unlike( $e, qr/Hypertension/, 'plaintext not stored' );
is( $hk->_dec($e), 'Hypertension', 'decrypt round trip' );
is( $hk->_dec('legacy plain'), 'legacy plain', 'plaintext fallback for legacy rows' );
is( $hk->_enc($e), $e, 'already-encrypted value not double-encrypted' );
ok( !defined $hk->_enc(''), 'empty stays empty' );
{ package BadCrypto; sub encrypt { undef } }
my $bad = Comserv::Util::HealthKitchen->new( crypto => 'BadCrypto' );
ok( !eval { $bad->_enc('secret'); 1 }, 'encryption failure dies instead of storing plaintext' );

# input cleaning: private by default
my $h = $hk->_clean_history_args( { entry_type => 'bogus', visibility => 'public', label => '  Gout ', ency_disease_id => 'x' } );
is( $h->{entry_type}, 'condition', 'unknown type -> condition' );
is( $h->{visibility}, 'private', 'visibility private unless site_admin' );
is( $h->{label}, 'Gout', 'label trimmed' );
ok( !defined $h->{ency_disease_id}, 'non-numeric id dropped' );
is( $hk->_clean_history_args( { visibility => 'site_admin' } )->{visibility}, 'site_admin', 'explicit share kept' );

# matching inputs
my $in = $hk->history_matching_inputs( [
    { entry_type => 'condition',  label => 'Liver disease', status => 'active',   use_for_matching => 1, ency_disease_id => 5 },
    { entry_type => 'medication', label => 'Warfarin',      status => 'active',   use_for_matching => 1, ency_drug_id => 9 },
    { entry_type => 'allergy',    label => 'Peanut',        status => 'active',   use_for_matching => 1 },
    { entry_type => 'condition',  label => 'Old flu',       status => 'resolved', use_for_matching => 1, ency_disease_id => 6 },
    { entry_type => 'condition',  label => 'Hidden',        status => 'active',   use_for_matching => 0, ency_disease_id => 7 },
], { allergies => 'Dairy, shellfish' } );
is_deeply( $in->{disease_ids}, [5], 'only active, opted-in conditions feed diseases' );
is_deeply( $in->{drug_ids}, [9], 'medication drug id collected' );
is_deeply( $in->{contra_terms}, [ 'liver disease', 'warfarin' ], 'contra terms from conditions/medications' );
is_deeply( $in->{allergens}, [ 'dairy', 'peanut', 'shellfish' ], 'allergens from history + profile' );

# match_candidates with history
my $m = $hk->match_candidates( {
    symptom_ids => [1], pantry_herb_ids => [ 1, 2, 3, 4 ],
    herb_symptoms => [ { herb_id => 1, symptom_id => 1 }, { herb_id => 2, symptom_id => 1 }, { herb_id => 3, symptom_id => 1 } ],
    herbs => { 1 => { name => 'Safe' }, 2 => { name => 'Risky', contra_indications => 'Avoid in liver disease' },
               3 => { name => 'Interacts' }, 4 => { name => 'Milk thistle' } },
    user_contra_terms => $in->{contra_terms}, user_drug_ids => $in->{drug_ids},
    drug_herb => [ { drug_id => 9, herb_id => 3 } ],
    disease_ids => $in->{disease_ids}, disease_herbs => [ { disease_id => 5, herb_id => 4 }, { disease_id => 6, herb_id => 1 } ],
} );
my %names = map { $_->{name} => $_ } @{ $m->{herbs} };
ok( $names{Safe}, 'safe herb kept' );
ok( !$names{Risky}, 'herb with caution matching history condition dropped' );
ok( !$names{Interacts}, 'herb interacting with recorded drug dropped' );
is( $names{'Milk thistle'}{disease_id}, 5, 'DiseaseHerb candidate from history added' );

# meal plan allergen filter
my ( $ok, $ex ) = $hk->filter_recipes_by_allergens(
    [ { name => 'PB toast', lines => [ { name => 'Peanut butter' }, { name => 'Bread' } ] },
      { name => 'Oats', lines => [ { name => 'Rolled oats' } ] } ], $in->{allergens} );
is( scalar @$ok, 1, 'allergen recipe removed' );
is_deeply( $ex->[0]{allergen_hits}, ['peanut'], 'allergen hit reported' );

# AI prompt: only non-identifying preferences
my $p = $hk->ai_recipe_prompt( [ { id => 1, name => 'Oats', qty => 1, unit => 'kg' } ], 2,
    { diet_flags => 'vegetarian, low-sodium', avoid => ['peanut'] } );
like( $p, qr/Dietary style: vegetarian, low-sodium/, 'diet flags included' );
like( $p, qr/Exclude these ingredients entirely: peanut/, 'allergens as plain exclusions' );
unlike( $p, qr/liver|warfarin|allerg/i, 'no conditions, medications or the word allergy in prompt' );

# CSV export escapes and blocks formula injection
my $csv = $hk->history_to_csv( [ { id => 1, label => '=HYPERLINK("x")', notes => 'a "b"' } ] );
like( $csv, qr/"'=HYPERLINK\(""x""\)"/, 'formula neutralised and quotes escaped' );

# real Comserv::Util::Encryption round trip (skips if no key on this box)
SKIP: {
    # Never generate a key from a test: only run when the healthkitchen key already exists.
    require Comserv::Util::Encryption;
    my $kf = eval { Comserv::Util::Encryption->_get_key_file_path('healthkitchen') };
    skip 'no healthkitchen encryption key provisioned', 2 unless $kf && -f $kf;
    my $real = Comserv::Util::HealthKitchen->new;
    my $enc = eval { $real->_enc('roundtrip-test') };
    skip "Comserv::Util::Encryption unavailable: $@", 2 unless $enc;
    like( $enc, qr/^ENC:/, 'real encryption prefix' );
    is( $real->_dec($enc), 'roundtrip-test', 'real decrypt round trip' );
}
done_testing;
