#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

BEGIN {
    eval { require DBD::SQLite; 1 } or plan skip_all => 'DBD::SQLite not installed';
}

use Comserv::Util::Logging;
{
    no warnings 'redefine';
    *Comserv::Util::Logging::log_with_details = sub { 1 };
}

{
    package E::Schema; use base 'DBIx::Class::Schema';
    package E::Item; use base 'DBIx::Class::Core';
    __PACKAGE__->table('inventory_items');
    __PACKAGE__->add_columns(id => { data_type => 'integer', is_auto_increment => 1 },
        map { $_ => { data_type => 'text', is_nullable => 1 } } qw(sitename sku name status));
    __PACKAGE__->set_primary_key('id');
    package E::Product; use base 'DBIx::Class::Core';
    __PACKAGE__->table('hk_item_product');
    __PACKAGE__->add_columns(id => { data_type => 'integer', is_auto_increment => 1 },
        map { $_ => { data_type => 'text', is_nullable => 1 } } qw(
            sitename item_kind item_id brand upc size_value size_unit ingredients_text ingredients_source));
    __PACKAGE__->set_primary_key('id');
    package E::Link; use base 'DBIx::Class::Core';
    __PACKAGE__->table('hk_inventory_ency_link');
    __PACKAGE__->add_columns(id => { data_type => 'integer', is_auto_increment => 1 },
        map { $_ => { data_type => 'text', is_nullable => 1 } } qw(
            sitename item_kind item_id entity_type entity_id added_by_user_id notes));
    __PACKAGE__->set_primary_key('id');
    __PACKAGE__->add_unique_constraint(hk_link_unique => [qw/sitename item_kind item_id entity_type entity_id/]);
    package E::Con; use base 'DBIx::Class::Core';
    __PACKAGE__->table('ency_constituent_tb');
    __PACKAGE__->add_columns(record_id => { data_type => 'integer', is_auto_increment => 1 },
        map { $_ => { data_type => 'text', is_nullable => 1 } } qw(
            name common_name therapeutic_action pharmacological_effects found_in_foods));
    __PACKAGE__->set_primary_key('record_id');
    package E::Herb; use base 'DBIx::Class::Core';
    __PACKAGE__->table('ency_herb_tb');
    __PACKAGE__->add_columns(record_id => { data_type => 'integer', is_auto_increment => 1 },
        map { $_ => { data_type => 'text', is_nullable => 1 } } qw(key_name botanical_name common_names));
    __PACKAGE__->set_primary_key('record_id');
}
E::Schema->register_class('Accounting::InventoryItem' => 'E::Item');
E::Schema->register_class('HealthKitchen::ItemProduct' => 'E::Product');
E::Schema->register_class('HealthKitchen::InventoryEncyLink' => 'E::Link');
E::Schema->register_class('Ency::Constituent' => 'E::Con');
E::Schema->register_class('Ency::Herb' => 'E::Herb');
my $schema = E::Schema->connect('dbi:SQLite:dbname=:memory:', '', '', { RaiseError => 1 });
$schema->deploy;
$schema->register_extra_source(InventoryItem => $schema->source('Accounting::InventoryItem'));

my $item = $schema->resultset('Accounting::InventoryItem')->create({
    sitename => 'Shanta', sku => 'OAT', name => 'Oats', status => 'active',
});
$schema->resultset('HealthKitchen::ItemProduct')->create({
    sitename => 'Shanta', item_kind => 'inventory', item_id => $item->id,
    ingredients_text => 'oats, sea salt', ingredients_source => 'manual',
});
my $beta = $schema->resultset('Ency::Constituent')->create({
    name => 'Beta-glucan', therapeutic_action => 'soluble fibre',
    pharmacological_effects => 'lowers cholesterol', found_in_foods => 'oats, barley',
});
my $salt = $schema->resultset('Ency::Constituent')->create({
    name => 'Sodium chloride', common_name => 'sea salt',
    therapeutic_action => 'electrolyte', pharmacological_effects => 'fluid balance',
});
my $herb = $schema->resultset('Ency::Herb')->create({
    key_name => 'avena', botanical_name => 'Avena sativa', common_names => 'oats',
});
$schema->resultset('HealthKitchen::InventoryEncyLink')->create({
    sitename => 'Shanta', item_kind => 'inventory', item_id => $item->id,
    entity_type => 'herb', entity_id => $herb->record_id,
});

{
    package EC;
    sub new { bless { stash => { SiteName => 'Shanta' }, session => { user_id => 9, SiteName => 'Shanta' } }, shift }
    sub stash { $_[0]{stash} }
    sub session { $_[0]{session} }
    sub model { bless { schema => $schema }, 'EM' }
    package EM;
    sub resultset { $_[0]{schema}->resultset($_[1]) }
    sub source { $_[0]{schema}->source($_[1]) }
}

require Comserv::Util::InventoryBarcode;
my $c = EC->new;
my $got = Comserv::Util::InventoryBarcode->ency_links($c, 'Shanta', $item->id);
my @oats = grep { $_->{ingredient} eq 'oats' } @{ $got->{suggestions} };
ok((grep { $_->{entity_type} eq 'constituent' && $_->{match} eq 'found_in_foods' } @oats), 'found_in_foods suggestion');
ok(!(grep { $_->{entity_type} eq 'herb' } @oats), 'already-linked herb is skipped');
ok((grep { $_->{ingredient} eq 'sea salt' && $_->{match} eq 'common_name' } @{ $got->{suggestions} }), 'constituent common name');

my $post = Comserv::Util::InventoryBarcode->ency_links_update($c, 'Shanta', {
    item_id => $item->id,
    confirm => [{ entity_type => 'constituent', entity_id => $beta->record_id }],
});
is($post->{ok}, 1, 'confirm ok') or diag($post->{error} || '');
ok($post->{added}[0], 'added a link id');
my $link = $schema->resultset('HealthKitchen::InventoryEncyLink')->find($post->{added}[0]);
is($link->entity_type, 'constituent', 'add_ency_link wrote the row');
my ($shown) = grep { $_->{entity_type} eq 'constituent' && $_->{entity_id} == $beta->record_id } @{ $post->{links} };
is($shown->{therapeutic_action}, 'soluble fibre', 'constituent effect returned');
is($shown->{pharmacological_effects}, 'lowers cholesterol', 'pharmacological effect returned');

done_testing;
