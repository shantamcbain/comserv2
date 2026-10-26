package Comserv::Model::Schema::Ency::Result::Accounting::InventoryItemAttributes;
use strict;
use warnings;
use base 'DBIx::Class::Core';

# 1:1 sourcing/production attributes for an inventory item (organic, grass-fed,
# wild/farmed, GMO, distance, certifier). Kept out of inventory_items so that
# table stays lean; read by HealthKitchen, shop, POs and labels.
# Allowed values are enforced in Comserv::Util::HealthKitchen (%SOURCING_ENUM).
__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('inventory_item_attributes');
__PACKAGE__->add_columns(
    id               => { data_type => 'integer', is_auto_increment => 1, is_nullable => 0 },
    item_id          => { data_type => 'integer', is_nullable => 0 },
    sitename         => { data_type => 'varchar', size => 255, is_nullable => 0 },
    food_category_id => { data_type => 'integer', is_nullable => 1 },   # inventory_categories.id
    production       => { data_type => 'varchar', size => 30,  is_nullable => 1 },
    animal_raising   => { data_type => 'varchar', size => 30,  is_nullable => 1 },
    catch_method     => { data_type => 'varchar', size => 20,  is_nullable => 1 },
    gmo              => { data_type => 'varchar', size => 30,  is_nullable => 1 },
    local_km         => { data_type => 'integer', is_nullable => 1 },
    certifier        => { data_type => 'varchar', size => 100, is_nullable => 1 },
    cert_verified    => { data_type => 'tinyint', is_nullable => 1 },
    created_at       => { data_type => 'datetime', is_nullable => 1, set_on_create => 1 },
    updated_at       => { data_type => 'datetime', is_nullable => 1, set_on_create => 1, set_on_update => 1 },
);
__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint( inventory_item_attributes_item => ['item_id'] );
__PACKAGE__->belongs_to( item => 'Comserv::Model::Schema::Ency::Result::Accounting::InventoryItem', 'item_id' );
__PACKAGE__->belongs_to( food_category => 'Comserv::Model::Schema::Ency::Result::Accounting::InventoryCategory',
    'food_category_id', { join_type => 'left' } );
1;
