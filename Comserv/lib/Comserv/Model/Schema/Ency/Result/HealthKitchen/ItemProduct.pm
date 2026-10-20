package Comserv::Model::Schema::Ency::Result::HealthKitchen::ItemProduct;
use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('hk_item_product');

# Product details for a pantry/inventory item (brand, UPC, package size).
# upc is only used for personal pantry rows; site inventory items keep their
# barcode in inventory_items.barcode/barcode_type. Sourcing attributes live in
# Accounting::InventoryItemAttributes (inventory_item_attributes).
__PACKAGE__->add_columns(
    id         => { data_type => 'integer', is_auto_increment => 1, is_nullable => 0 },
    sitename   => { data_type => 'varchar', size => 255, is_nullable => 0 },
    item_kind  => { data_type => 'varchar', size => 20,  is_nullable => 0 },
    item_id    => { data_type => 'integer', is_nullable => 0 },
    brand      => { data_type => 'varchar', size => 255, is_nullable => 1 },
    upc        => { data_type => 'varchar', size => 32,  is_nullable => 1 },
    size_value => { data_type => 'decimal', size => [12, 3], is_nullable => 1 },
    size_unit  => { data_type => 'varchar', size => 20,  is_nullable => 1 },
    created_at => { data_type => 'datetime', is_nullable => 1, set_on_create => 1 },
    updated_at => { data_type => 'datetime', is_nullable => 1, set_on_create => 1, set_on_update => 1 },
);
__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint( hk_product_item => [qw/sitename item_kind item_id/] );
1;
