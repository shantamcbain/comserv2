package Comserv::Model::Schema::Ency::Result::HealthKitchen::ItemProduct;
use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('hk_item_product');

# Product details for a pantry/inventory item (brand, UPC, package size).
# For inventory items the UPC falls back to inventory_items.barcode on read;
# inventory_items itself is not modified by HealthKitchen.
__PACKAGE__->add_columns(
    id         => { data_type => 'integer', is_auto_increment => 1, is_nullable => 0 },
    sitename   => { data_type => 'varchar', size => 255, is_nullable => 0 },
    item_kind  => { data_type => 'varchar', size => 20,  is_nullable => 0 },
    item_id    => { data_type => 'integer', is_nullable => 0 },
    brand      => { data_type => 'varchar', size => 255, is_nullable => 1 },
    upc        => { data_type => 'varchar', size => 32,  is_nullable => 1 },
    size_value => { data_type => 'decimal', size => [12, 3], is_nullable => 1 },
    size_unit  => { data_type => 'varchar', size => 20,  is_nullable => 1 },
    # Sourcing attributes (20261018_healthkitchen_sourcing.sql). Allowed values enforced in Util::HealthKitchen.
    food_category  => { data_type => 'varchar', size => 30,  is_nullable => 1 },
    production     => { data_type => 'varchar', size => 30,  is_nullable => 1 },
    animal_raising => { data_type => 'varchar', size => 30,  is_nullable => 1 },
    catch_method   => { data_type => 'varchar', size => 20,  is_nullable => 1 },
    gmo            => { data_type => 'varchar', size => 30,  is_nullable => 1 },
    local_km       => { data_type => 'integer', is_nullable => 1 },
    certifier      => { data_type => 'varchar', size => 100, is_nullable => 1 },
    cert_verified  => { data_type => 'tinyint', is_nullable => 1 },
    created_at => { data_type => 'datetime', is_nullable => 1, set_on_create => 1 },
    updated_at => { data_type => 'datetime', is_nullable => 1, set_on_create => 1, set_on_update => 1 },
);
__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint( hk_product_item => [qw/sitename item_kind item_id/] );
1;
