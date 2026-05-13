package Comserv::Model::Schema::Ency::Result::Printing3dModel;
use base 'DBIx::Class::Core';

__PACKAGE__->table('printing_3d_models');

__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
    },
    sitename => {
        data_type => 'varchar',
        size      => 100,
    },
    name => {
        data_type => 'varchar',
        size      => 255,
    },
    description => {
        data_type   => 'text',
        is_nullable => 1,
    },
    file_id => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    nfs_path => {
        data_type   => 'varchar',
        size        => 1000,
        is_nullable => 1,
    },
    file_type => {
        data_type   => 'varchar',
        size        => 20,
        is_nullable => 1,
    },
    tags => {
        data_type   => 'varchar',
        size        => 500,
        is_nullable => 1,
    },
    thumbnail_url => {
        data_type   => 'varchar',
        size        => 1000,
        is_nullable => 1,
    },
    source => {
        data_type     => 'varchar',
        size          => 20,
        default_value => 'filemanager',
    },
    source_url => {
        data_type   => 'varchar',
        size        => 1000,
        is_nullable => 1,
    },
    added_by => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    is_active => {
        data_type     => 'tinyint',
        default_value => 1,
    },
    created_at => {
        data_type     => 'datetime',
        default_value => \'CURRENT_TIMESTAMP',
        is_nullable   => 1,
    },
    item_id => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    stl_volume_cm3 => {
        data_type     => 'decimal',
        size          => [12, 4],
        is_nullable   => 1,
    },
    stl_weight_g => {
        data_type     => 'decimal',
        size          => [10, 3],
        is_nullable   => 1,
    },
    print_time_hours => {
        data_type     => 'decimal',
        size          => [8, 3],
        is_nullable   => 1,
    },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->has_many(
    jobs => 'Comserv::Model::Schema::Ency::Result::Printing3dJob',
    'model_id',
    { cascade_delete => 0 }
);

__PACKAGE__->belongs_to(
    inventory_item => 'Comserv::Model::Schema::Ency::Result::Accounting::InventoryItem',
    'item_id',
    { join_type => 'LEFT', on_delete => 'SET NULL', on_update => 'CASCADE' }
);

1;
