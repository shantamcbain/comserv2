package Comserv::Model::Schema::Ency::Result::HealthKitchen::InventoryEncyLink;
use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('hk_inventory_ency_link');

# Many-to-many: one pantry/inventory item -> many ENCY entities.
# item_kind: 'inventory' (inventory_items.id) or 'pantry' (hk_user_pantry_qty.id).
# entity_type: 'herb' (ency_herb_tb), 'animal' (ency_animal_tb), 'constituent' (ency_constituent_tb).
# Supersedes the single-row hk_inventory_ency_map (kept for back-compat reads).
__PACKAGE__->add_columns(
    id                => { data_type => 'integer', is_auto_increment => 1, is_nullable => 0 },
    sitename          => { data_type => 'varchar', size => 255, is_nullable => 0 },
    item_kind         => { data_type => 'varchar', size => 20,  is_nullable => 0 },
    item_id           => { data_type => 'integer', is_nullable => 0 },
    entity_type       => { data_type => 'varchar', size => 20,  is_nullable => 0 },
    entity_id         => { data_type => 'integer', is_nullable => 0 },
    added_by_user_id  => { data_type => 'integer', is_nullable => 1 },
    notes             => { data_type => 'text', is_nullable => 1 },
    created_at        => { data_type => 'datetime', is_nullable => 1, set_on_create => 1 },
    updated_at        => { data_type => 'datetime', is_nullable => 1, set_on_create => 1, set_on_update => 1 },
);
__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint(
    hk_link_unique => [qw/sitename item_kind item_id entity_type entity_id/] );
1;
