package Comserv::Model::Schema::Ency::Result::HealthInventoryItem;
use base 'DBIx::Class::Core';

__PACKAGE__->table('health_inventory_items');
__PACKAGE__->add_columns(
    id => {
        data_type         => 'int',
        is_auto_increment => 1,
    },
    sitename => {
        data_type => 'varchar',
        size      => 255,
    },
    item_name => {
        data_type => 'varchar',
        size      => 255,
    },
    item_type => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 1,
    },
    herb_record_id => {
        data_type   => 'int',
        is_nullable => 1,
    },
    quantity => {
        data_type     => 'decimal',
        size          => [10, 2],
        default_value => '0.00',
        is_nullable   => 1,
    },
    unit => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 1,
    },
    low_stock_threshold => {
        data_type     => 'decimal',
        size          => [10, 2],
        default_value => '0.00',
        is_nullable   => 1,
    },
    reorder_quantity => {
        data_type     => 'decimal',
        size          => [10, 2],
        default_value => '0.00',
        is_nullable   => 1,
    },
    notes => {
        data_type   => 'text',
        is_nullable => 1,
    },
    updated_at => {
        data_type   => 'datetime',
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key('id');

1;
