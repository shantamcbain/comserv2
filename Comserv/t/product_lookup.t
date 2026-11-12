#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use JSON::MaybeXS qw(encode_json decode_json);

BEGIN {
    eval { require DBD::SQLite; 1 } or plan skip_all => 'DBD::SQLite not installed';
}

use Comserv::Util::Logging;
{
    no warnings 'redefine';
    *Comserv::Util::Logging::log_with_details = sub { 1 };
}

{
    package N::Schema; use base 'DBIx::Class::Schema';
    package N::Result::Food; use base 'DBIx::Class::Core';
    __PACKAGE__->table('hk_food_nutrient');
    __PACKAGE__->add_columns(
        id => { data_type => 'integer', is_auto_increment => 1 },
        map { $_ => { data_type => 'text', is_nullable => 1 } } qw(
            sitename name brand source source_ref inventory_item_id serving_size serving_unit
            calories protein_g carbs_g fat_g fiber_g sugar_g sodium_mg extra_json
        )
    );
    __PACKAGE__->set_primary_key('id');
}
N::Schema->register_class('HealthKitchen::FoodNutrient' => 'N::Result::Food');
my $schema = N::Schema->connect('dbi:SQLite:dbname=:memory:', '', '', { RaiseError => 1 });
$schema->deploy;

{
    package PC;
    sub new { bless { stash => {}, schema => $schema }, shift }
    sub stash { $_[0]{stash} }
    sub model { bless { schema => $schema }, 'PM' }
    package PM;
    sub resultset { $_[0]{schema}->resultset($_[1]) }
}

require Comserv::Util::ProductLookup;
require Comserv::Model::AI2::Search;
my $fetches = 0;
my $off = {
    status => 1,
    product => {
        product_name => 'Oat drink',
        brands => 'Oatly',
        quantity => '1 l',
        ingredients_text => 'oat base (water, oats 10%), rapeseed oil, sea salt',
        image_front_url => 'https://images.openfoodfacts.org/oat.jpg',
        nutriments => {
            'energy-kcal_100g' => 46,
            proteins_100g => 1.0,
            carbohydrates_100g => 6.7,
            fat_100g => 1.5,
            fiber_100g => 0.8,
            sugars_100g => 4.0,
            sodium_100g => 0.04,
        },
    },
};

sub fetcher {
    my ($mode) = @_;
    return sub {
        $fetches++;
        return { error => 'timeout' } if $mode eq 'timeout';
        return { status => 404, body => '{}' } if $mode eq 'miss';
        return { status => 200, body => encode_json($off) };
    };
}

my $c = PC->new;
ProductLookup_reset();

my $hit = Comserv::Util::ProductLookup->lookup($c, barcode => '7394376616037', fetcher => fetcher('hit'));
is($hit->{found}, 1, 'OFF hit found');
is($hit->{source}, 'open_food_facts', 'source');
is($hit->{name}, 'Oat drink', 'name');
is($hit->{brand}, 'Oatly', 'brand');
is($hit->{size_value}, 1, 'size value');
is($hit->{size_unit}, 'l', 'size unit');
is_deeply($hit->{ingredients}, ['oat base (water, oats 10%)', 'rapeseed oil', 'sea salt'], 'ingredients');
is($hit->{nutrients}{calories}, 46, 'calories');
is($hit->{nutrients}{sodium_mg}, 40, 'sodium mg');
is($fetches, 1, 'one fetch');

my $again = Comserv::Util::ProductLookup->lookup($c, barcode => '7394376616037', fetcher => fetcher('hit'));
is($again->{cached}, 1, 'second call is cached');
is($fetches, 1, 'cache did not fetch again');

ProductLookup_reset();
$fetches = 0;
{
    no warnings 'redefine';
    *Comserv::Model::AI2::Search::query = sub {
        return { success => 1, results => [{ title => 'Oat page', url => 'https://example.test/oat', content => 'oat' }], engine => 'searxng' };
    };
}
my $fb = Comserv::Util::ProductLookup->lookup($c, barcode => '4006381333931', fetcher => fetcher('miss'));
is($fb->{found}, 1, 'OFF 404 falls back');
is($fb->{source}, 'searxng', 'searxng source');
is($fb->{name}, 'Oat page', 'searxng title');
is_deeply($fb->{ingredients}, [], 'searxng ingredients empty');

ProductLookup_reset();
{
    no warnings 'redefine';
    *Comserv::Model::AI2::Search::query = sub { return { success => 0, error => 'down' } };
}
my $none = Comserv::Util::ProductLookup->lookup($c, barcode => '0000000000000', fetcher => fetcher('miss'));
is($none->{found}, 0, 'both miss');
is_deeply($none->{tried}, ['open_food_facts', 'searxng'], 'tried both');

ProductLookup_reset();
my $to = Comserv::Util::ProductLookup->lookup($c, barcode => '1111111111116', fetcher => fetcher('timeout'));
is($to->{found}, 0, 'timeout is found 0');
is($to->{errors}{open_food_facts}, 'timeout', 'timeout recorded');

ProductLookup_reset();
$fetches = 0;
my $saved = Comserv::Util::ProductLookup->lookup($c,
    barcode => '7394376616037', save => 1, fetcher => fetcher('hit'));
ok($saved->{saved_nutrient_id}, 'nutrient id returned');
my $n = $schema->resultset('HealthKitchen::FoodNutrient')->count;
is($n, 1, 'one nutrient row');
Comserv::Util::ProductLookup->lookup($c, barcode => '7394376616037', save => 1, fetcher => fetcher('hit'));
is($schema->resultset('HealthKitchen::FoodNutrient')->count, 1, 'second save does not insert again');
is($fetches, 1, 'save path also cached');
my $row = $schema->resultset('HealthKitchen::FoodNutrient')->first;
is($row->source, 'open_food_facts', 'source stored');
is($row->source_ref, '7394376616037', 'source_ref is the barcode');

sub ProductLookup_reset {
    Comserv::Util::ProductLookup->reset_cache;
}

done_testing;
