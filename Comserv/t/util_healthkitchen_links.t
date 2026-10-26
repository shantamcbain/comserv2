use strict;
use warnings;
use Test::More;
use lib 'lib';
use Comserv::Util::HealthKitchen;

my $hk = Comserv::Util::HealthKitchen->new;

# --- UPC / barcode ---
is $hk->normalize_upc('8 36676 00001 9'), '836676000019', 'UPC with spaces normalized';
is $hk->normalize_upc('836676-000019'),   '836676000019', 'UPC with dash';
is $hk->normalize_upc('12345'),           '',             'too short rejected';
is $hk->normalize_upc('ABC123456789'),    '',             'letters rejected';
is $hk->normalize_upc(undef),             '',             'undef';
is $hk->upc_check_ok('836676000019'), 1, 'Joy of the Mountain UPC check digit valid';
is $hk->upc_check_ok('836676000018'), 0, 'bad check digit';
is $hk->upc_check_ok('4006381333931'), 1, 'EAN-13 valid';

# --- size ---
is_deeply [ $hk->parse_size('10 ml') ], [ 10, 'ml' ], '10 ml';
is_deeply [ $hk->parse_size('10ml') ],  [ 10, 'ml' ], '10ml';
is_deeply [ $hk->parse_size('1.5 L') ], [ 1.5, 'l' ], '1.5 L';
is_deeply [ $hk->parse_size('2') ],     [ 2, undef ], 'bare number';
is_deeply [ $hk->parse_size('big') ],   [],           'garbage';

# --- link validation ---
my ( $a, $e ) = $hk->validate_link_args(
    { item_kind => 'inventory', item_id => '42', entity_type => 'Herb', entity_id => '7' } );
is $e, undef, 'valid herb link';
is_deeply $a, { item_kind => 'inventory', item_id => 42, entity_type => 'herb', entity_id => 7 }, 'cleaned';
( $a, $e ) = $hk->validate_link_args( { item_kind => 'pantry', item_id => 3, entity_type => 'animal', entity_id => 9 } );
ok !$e, 'pantry -> animal ok';
( $a, $e ) = $hk->validate_link_args( { item_kind => 'pantry', item_id => 3, entity_type => 'constituent', entity_id => 9 } );
ok !$e, 'constituent ok';
( undef, $e ) = $hk->validate_link_args( { item_kind => 'x', item_id => 1, entity_type => 'herb', entity_id => 1 } );
like $e, qr/item kind/, 'bad kind';
( undef, $e ) = $hk->validate_link_args( { item_kind => 'pantry', item_id => 1, entity_type => 'drug', entity_id => 1 } );
like $e, qr/ENCY type/, 'bad type';
( undef, $e ) = $hk->validate_link_args( { item_kind => 'pantry', item_id => 'x', entity_type => 'herb', entity_id => 1 } );
like $e, qr/Item id/, 'bad item id';
( undef, $e ) = $hk->validate_link_args( { item_kind => 'pantry', item_id => 1, entity_type => 'herb' } );
like $e, qr/Pick/, 'missing entity';

# --- symptom dedupe ---
my $list = [
    { id => 1, name => 'Headache',  common_name => '' },
    { id => 2, name => 'Pyrexia',   common_name => 'Fever' },
];
is $hk->normalize_symptom_name("  Sore   throat "), 'Sore throat', 'normalize whitespace';
is $hk->find_symptom_dup( 'headache', $list )->{id}, 1, 'case-insensitive name match';
is $hk->find_symptom_dup( ' FEVER ', $list )->{id}, 2, 'common_name match';
is $hk->find_symptom_dup( 'Head', $list ), undef, 'no partial match';
is $hk->find_symptom_dup( '', $list ), undef, 'empty';

done_testing;
