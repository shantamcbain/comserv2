#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use JSON::MaybeXS qw(encode_json decode_json);
use IO::File;

BEGIN {
    eval { require DBD::SQLite; 1 } or plan skip_all => 'DBD::SQLite not installed';
}

use Comserv::Util::Logging;
{
    no warnings 'redefine';
    *Comserv::Util::Logging::log_with_details = sub { 1 };
}

{
    package T::Schema; use base 'DBIx::Class::Schema';
    package T::Result::Item; use base 'DBIx::Class::Core';
    __PACKAGE__->table('inventory_items');
    __PACKAGE__->add_columns(
        id => { data_type => 'integer', is_auto_increment => 1 },
        map { $_ => { data_type => 'text', is_nullable => 1 } } qw(
            sitename sku name description category item_origin is_assemblable is_consumable
            unit_of_measure unit_cost unit_price selling_price barcode barcode_type notes
            image_path reorder_point reorder_quantity status inventory_accno_id income_accno_id
            expense_accno_id returns_accno_id show_in_shop hide_stock_count list_in_marketplace
            created_by created_at updated_at updated_by
        )
    );
    __PACKAGE__->set_primary_key('id');
    package T::Result::Product; use base 'DBIx::Class::Core';
    __PACKAGE__->table('hk_item_product');
    __PACKAGE__->add_columns(
        id => { data_type => 'integer', is_auto_increment => 1 },
        map { $_ => { data_type => 'text', is_nullable => 1 } } qw(
            sitename item_kind item_id brand upc size_value size_unit ingredients_text ingredients_source
        )
    );
    __PACKAGE__->set_primary_key('id');
    package T::Result::Link; use base 'DBIx::Class::Core';
    __PACKAGE__->table('hk_inventory_ency_link');
    __PACKAGE__->add_columns(
        id => { data_type => 'integer', is_auto_increment => 1 },
        map { $_ => { data_type => 'text', is_nullable => 1 } } qw(
            sitename item_kind item_id entity_type entity_id added_by_user_id notes
        )
    );
    __PACKAGE__->set_primary_key('id');
    __PACKAGE__->add_unique_constraint(hk_link_unique => [qw/sitename item_kind item_id entity_type entity_id/]);
    package T::Result::Constituent; use base 'DBIx::Class::Core';
    __PACKAGE__->table('ency_constituent_tb');
    __PACKAGE__->add_columns(
        record_id => { data_type => 'integer', is_auto_increment => 1 },
        map { $_ => { data_type => 'text', is_nullable => 1 } } qw(
            name common_name therapeutic_action pharmacological_effects found_in_foods
        )
    );
    __PACKAGE__->set_primary_key('record_id');
    package T::Result::Herb; use base 'DBIx::Class::Core';
    __PACKAGE__->table('ency_herb_tb');
    __PACKAGE__->add_columns(
        record_id => { data_type => 'integer', is_auto_increment => 1 },
        map { $_ => { data_type => 'text', is_nullable => 1 } } qw(key_name botanical_name common_names)
    );
    __PACKAGE__->set_primary_key('record_id');
}
T::Schema->register_class('Accounting::InventoryItem' => 'T::Result::Item');
T::Schema->register_class('HealthKitchen::ItemProduct' => 'T::Result::Product');
T::Schema->register_class('HealthKitchen::InventoryEncyLink' => 'T::Result::Link');
T::Schema->register_class('Ency::Constituent' => 'T::Result::Constituent');
T::Schema->register_class('Ency::Herb' => 'T::Result::Herb');
my $schema = T::Schema->connect('dbi:SQLite:dbname=:memory:', '', '', { RaiseError => 1, sqlite_unicode => 1 });
$schema->deploy;
$schema->register_extra_source(InventoryItem => $schema->source('Accounting::InventoryItem'));

my $items = $schema->resultset('Accounting::InventoryItem');
my $oat = $items->create({
    sitename => 'Shanta', sku => 'HK-0042', name => 'Oat milk', description => undef,
    category => 'Food', barcode => '012345678905', barcode_type => 'UPC',
    unit_of_measure => 'each', unit_cost => '2.10', unit_price => '3.50', selling_price => '3.50',
    status => 'active', notes => undef, image_path => '/static/inventory_images/Shanta/42.jpg',
});
$schema->resultset('HealthKitchen::ItemProduct')->create({
    sitename => 'Shanta', item_kind => 'inventory', item_id => $oat->id,
    brand => 'Oatly', size_value => 1, size_unit => 'l',
    ingredients_text => 'oat base (water, oats 10%), rapeseed oil, sea salt',
    ingredients_source => 'open_food_facts',
});
my $con = $schema->resultset('Ency::Constituent')->create({
    name => 'Beta-glucan', common_name => 'beta glucan',
    therapeutic_action => 'soluble fibre', pharmacological_effects => 'lowers cholesterol',
    found_in_foods => 'oats, barley',
});
$schema->resultset('HealthKitchen::InventoryEncyLink')->create({
    sitename => 'Shanta', item_kind => 'inventory', item_id => $oat->id,
    entity_type => 'constituent', entity_id => $con->record_id,
});
$items->create({
    sitename => 'Other', sku => 'OTHER-1', name => 'Hidden', category => 'Food',
    barcode => '012345678905', status => 'active',
});
$items->create({
    sitename => 'Shanta', sku => 'SKU-ONLY', name => 'Sku only', category => 'Spice',
    barcode => '999', status => 'active', unit_price => '1.00', selling_price => '1.00',
});

{
    package FakeReq;
    sub new { bless { address => '203.0.113.9', method => 'GET', headers => {}, q => {}, json => undef, %{ $_[1] || {} } }, $_[0] }
    sub address { $_[0]{address} }
    sub method { $_[0]{method} }
    sub header { $_[0]{headers}{lc $_[1]} }
    sub params { $_[0]{q} }
    sub query_parameters { $_[0]{q} }
    sub param { $_[0]{q}{$_[1]} }
    sub body_parameters { {} }
    sub body {
        my $s = shift;
        return undef unless defined $s->{json};
        my $fh = IO::File->new_tmpfile;
        print $fh $s->{json};
        $fh->flush; seek($fh, 0, 0);
        return $fh;
    }
    sub upload { undef }
    package FakeRes;
    sub new { bless { status => 200 }, shift }
    sub status { $_[0]{status} = $_[1] if @_ > 1; $_[0]{status} }
    sub body { $_[0]{body} = $_[1] if @_ > 1; $_[0]{body} }
    sub content_type { 1 }
    package FakeModel;
    sub new { bless { schema => $_[1] }, $_[0] }
    sub resultset { $_[0]{schema}->resultset($_[1]) }
    sub source { $_[0]{schema}->source($_[1]) }
    sub txn_do { my ($self, $code) = @_; $self->{schema}->txn_do($code) }
    package FakeC;
    sub new {
        my ($c, %a) = @_;
        my $self = bless {
            session => $a{session} || {},
            stash => { %{ $a{stash} || {} } },
            schema => $schema,
        }, $c;
        $self->{req} = FakeReq->new($a{req} || {});
        $self->{res} = FakeRes->new;
        $self->{controllers}{Inventory} = bless { logging => Comserv::Util::Logging->instance }, 'Comserv::Controller::Inventory';
        return $self;
    }
    sub req { $_[0]{req} }
    sub request { $_[0]{req} }
    sub res { $_[0]{res} }
    sub session { $_[0]{session} }
    sub stash { $_[0]{stash} }
    sub model { FakeModel->new($_[0]{schema}) }
    sub controller { $_[0]{controllers}{$_[1]} }
    sub detach { die { detach => 1 } }
}

require Comserv::Controller::Api;
require Comserv::Controller::Inventory;
my $api = bless { logging => Comserv::Util::Logging->instance }, 'Comserv::Controller::Api';
my $inv = bless { logging => Comserv::Util::Logging->instance }, 'Comserv::Controller::Inventory';

sub call {
    my ($obj, $m, $c) = @_;
    eval { $obj->$m($c); 1 } or do { die $@ unless ref $@ eq 'HASH' && $@->{detach} };
    my $body = $c->res->body // '';
    my $j = eval { decode_json($body) };
    return ($c->res->status, $j, $body);
}
sub ctx {
    my (%a) = @_;
    return FakeC->new(
        session => $a{session},
        stash => $a{stash} || {},
        req => {
            method => $a{method} || 'GET',
            headers => $a{headers} || {},
            q => $a{q} || {},
            json => (ref $a{body} ? encode_json($a{body}) : $a{body}),
        },
    );
}

my $admin = { user_id => 9, username => 'Shanta', roles => ['admin'], SiteName => 'Shanta' };
my $hdr = { 'x-sitename' => 'Shanta' };

# 401 without a session
{
    my ($st, $j) = call($api, 'api_inventory_item_by_barcode', ctx(q => { barcode => '012345678905' }));
    is($st, 401, 'by_barcode without session is 401');
    is($j->{code}, 'not_authenticated', '401 code');
    is($j->{error}, 'Not authenticated. Please log in first.', '401 message');
}

# found 1
{
    my ($st, $j) = call($api, 'api_inventory_item_by_barcode', ctx(
        session => $admin, stash => { SiteName => 'Shanta' },
        headers => $hdr, q => { barcode => '012345678905' },
    ));
    is($st, 200, 'by_barcode found status');
    is($j->{found}, 1, 'found 1');
    is($j->{item}{sku}, 'HK-0042', 'sku');
    is_deeply($j->{item}{ingredients}, ['oat base (water, oats 10%)', 'rapeseed oil', 'sea salt'], 'ingredients split');
    is($j->{item}{product}{brand}, 'Oatly', 'product brand');
    is($j->{item}{ency_links}[0]{label}, 'Beta-glucan', 'ency link label');
    is($j->{item}{ency_links}[0]{therapeutic_action}, 'soluble fibre', 'constituent effect');
    ok(!(grep { $_ eq 'ingredients' } @{ $j->{missing} }), 'ingredients not missing');
}

# found 0 and normalised spaced code
{
    my ($st, $j) = call($api, 'api_inventory_item_by_barcode', ctx(
        session => $admin, stash => { SiteName => 'Shanta' },
        headers => $hdr, q => { barcode => '0000000000000' },
    ));
    is($j->{found}, 0, 'unknown barcode is found 0');
    is($j->{success}, 1, 'found 0 is still success');
    ($st, $j) = call($api, 'api_inventory_item_by_barcode', ctx(
        session => $admin, stash => { SiteName => 'Shanta' },
        headers => $hdr, q => { barcode => '0 12345 67890 5' },
    ));
    is($j->{found}, 1, 'spaced barcode matches normalised row');
    is($j->{item}{id}, $oat->id, 'same item');
}

# site isolation: header site does not see the other site's copy, and query sitename is ignored
{
    my ($st, $j) = call($api, 'api_inventory_item_by_barcode', ctx(
        session => { user_id => 3, username => 'clerk', roles => ['admin'], SiteName => 'Shanta' },
        stash => { SiteName => 'Shanta' },
        headers => $hdr,
        q => { barcode => '012345678905', sitename => 'Other' },
    ));
    is($j->{item}{sku}, 'HK-0042', 'query sitename does not switch site');
}

# create: barcode before SKU, SKU match, new item
{
    my ($st, $j) = call($inv, 'api_item_create', ctx(
        session => $admin, method => 'POST',
        body => { sku => 'NEW-1', name => 'Dup', barcode => '0 12345 67890 5', sitename => 'Shanta' },
    ));
    is($j->{existing}, 1, 'barcode match is existing');
    is($j->{matched_on}, 'barcode', 'matched on barcode before sku');
    is($j->{sku}, 'HK-0042', 'returned the barcode owner');
    ok(!$j->{created}, 'barcode match is not created');

    ($st, $j) = call($inv, 'api_item_create', ctx(
        session => $admin, method => 'POST',
        body => { sku => 'SKU-ONLY', name => 'Again', sitename => 'Shanta' },
    ));
    is($j->{matched_on}, 'sku', 'sku match');

    ($st, $j) = call($inv, 'api_item_create', ctx(
        session => $admin, method => 'POST',
        body => { sku => 'TEST-OAT-9', name => 'New oat', barcode => '7394376616037', barcode_type => 'EAN13', sitename => 'Shanta' },
    ));
    is($j->{created}, 1, 'new item created');
    my $made = $items->find($j->{item_id});
    is($made->barcode, '7394376616037', 'stored barcode');
}

# update saves barcode, product, ingredients; 409 if the code is taken
{
    my $target = $items->find({ sku => 'TEST-OAT-9' });
    my ($st, $j) = call($inv, 'api_item_update', ctx(
        session => $admin, method => 'POST',
        body => {
            sku => 'TEST-OAT-9', barcode => '012345678905',
        },
    ));
    is($st, 409, 'barcode in use is 409');
    is($j->{code}, 'barcode_in_use', 'barcode_in_use');
    is($j->{item_id}, $oat->id, 'other item id');

    ($st, $j) = call($inv, 'api_item_update', ctx(
        session => $admin, method => 'POST',
        body => {
            item_id => $target->id,
            barcode => '7394376616037',
            brand => 'Oatly',
            size => '1 l',
            ingredients => ['oat base', 'rapeseed oil', 'sea salt'],
            ingredients_source => 'open_food_facts',
        },
    ));
    is($st, 200, 'update ok') or diag($j->{error} || '');
    ok((grep { $_ eq 'ingredients_text' } @{ $j->{updated} || [] }), 'ingredients_text updated');
    my $prod = $schema->resultset('HealthKitchen::ItemProduct')->search({
        item_kind => 'inventory', item_id => $target->id,
    })->single;
    is($prod->brand, 'Oatly', 'brand saved');
    is($prod->ingredients_text, 'oat base, rapeseed oil, sea salt', 'ingredients joined');
}

# api_items fields, filters, sitename ignored for a non-CSC admin
{
    my ($st, $j, $body) = call($inv, 'api_items', ctx(
        session => { username => 'clerk', roles => ['admin'], SiteName => 'Shanta' },
        q => { barcode => '012345678905', sitename => 'Other' },
    ));
    my $rows = decode_json($body);
    is(ref $rows, 'ARRAY', 'items is a bare array');
    is(scalar @$rows, 1, 'barcode filter returns one row');
    is($rows->[0]{sku}, 'HK-0042', 'non-admin query sitename ignored');
    is($rows->[0]{barcode}, '012345678905', 'barcode field present');
    ok(exists $rows->[0]{image_path}, 'image_path field present');
    ok(exists $rows->[0]{selling_price}, 'selling_price field present');

    ($st, $j, $body) = call($inv, 'api_items', ctx(
        session => { username => 'clerk', roles => ['admin'], SiteName => 'Shanta' },
        q => { category => 'food' },
    ));
    $rows = decode_json($body);
    ok((grep { $_->{sku} eq 'HK-0042' } @$rows), 'category filter is case-insensitive');
    ok(!(grep { $_->{sku} eq 'SKU-ONLY' } @$rows), 'spice row excluded from Food');
}

done_testing;
