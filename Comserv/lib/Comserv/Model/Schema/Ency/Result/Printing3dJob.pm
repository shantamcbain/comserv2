package Comserv::Model::Schema::Ency::Result::Printing3dJob;
use base 'DBIx::Class::Core';

__PACKAGE__->table('printing_3d_jobs');

__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
    },
    sitename => {
        data_type => 'varchar',
        size      => 100,
    },
    model_id => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    consignment_id => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    consignment_line_id => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    item_name => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    user_id => {
        data_type => 'integer',
    },
    username => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    printer_id => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    status => {
        data_type     => 'varchar',
        size          => 20,
        default_value => 'queued',
    },
    filament_color => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
    },
    filament_type => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
    },
    quantity => {
        data_type     => 'integer',
        default_value => 1,
    },
    notes => {
        data_type   => 'text',
        is_nullable => 1,
    },
    admin_notes => {
        data_type   => 'text',
        is_nullable => 1,
    },
    filament_item_id => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    filament_quantity => {
        data_type     => 'decimal',
        size          => [10, 3],
        is_nullable   => 1,
        default_value => '1.000',
    },
    inventory_reserved => {
        data_type     => 'tinyint',
        is_nullable   => 0,
        default_value => 0,
    },
    print_hours => {
        data_type   => 'decimal',
        size        => [6, 2],
        is_nullable => 1,
    },
    filament_cost => {
        data_type   => 'decimal',
        size        => [10, 2],
        is_nullable => 1,
    },
    printer_cost => {
        data_type   => 'decimal',
        size        => [10, 2],
        is_nullable => 1,
    },
    electricity_cost => {
        data_type   => 'decimal',
        size        => [10, 2],
        is_nullable => 1,
    },
    total_cost => {
        data_type   => 'decimal',
        size        => [10, 2],
        is_nullable => 1,
    },
    created_at => {
        data_type     => 'datetime',
        default_value => \'CURRENT_TIMESTAMP',
        is_nullable   => 1,
    },
    started_at => {
        data_type   => 'datetime',
        is_nullable => 1,
    },
    completed_at => {
        data_type   => 'datetime',
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->belongs_to(
    model => 'Comserv::Model::Schema::Ency::Result::Printing3dModel',
    'model_id',
    { join_type => 'left' }
);

__PACKAGE__->belongs_to(
    printer => 'Comserv::Model::Schema::Ency::Result::Printing3dPrinter',
    'printer_id',
    { join_type => 'left' }
);

__PACKAGE__->belongs_to(
    user => 'Comserv::Model::Schema::Ency::Result::User',
    'user_id',
    { join_type => 'left' }
);

__PACKAGE__->belongs_to(
    filament_item => 'Comserv::Model::Schema::Ency::Result::InventoryItem',
    'filament_item_id',
    { join_type => 'left' }
);

__PACKAGE__->belongs_to(
    consignment => 'Comserv::Model::Schema::Ency::Result::InventoryConsignment',
    'consignment_id',
    { join_type => 'left' }
);

1;
