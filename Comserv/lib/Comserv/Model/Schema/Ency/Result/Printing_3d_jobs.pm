package Comserv::Model::Schema::Ency::Result::Printing_3d_jobs;
use base 'DBIx::Class::Core';

__PACKAGE__->table('printing_3d_jobs');
__PACKAGE__->add_columns(
    admin_notes => {
        data_type => 'text',
        is_nullable => 1,
    },
    completed_at => {
        data_type => 'datetime',
        is_nullable => 1,
    },
    created_at => {
        data_type => 'datetime',
        is_nullable => 1,
        default_value => 'current_timestamp()',
    },
    electricity_cost => {
        data_type => 'decimal',
        size => 10,2,
        is_nullable => 1,
    },
    filament_color => {
        data_type => 'varchar',
        size => 100,
        is_nullable => 1,
    },
    filament_cost => {
        data_type => 'decimal',
        size => 10,2,
        is_nullable => 1,
    },
    filament_item_id => {
        data_type => 'int',
        size => 11,
        is_nullable => 1,
    },
    filament_quantity => {
        data_type => 'decimal',
        size => 10,3,
        is_nullable => 1,
        default_value => '1.000',
    },
    filament_type => {
        data_type => 'varchar',
        size => 100,
        is_nullable => 1,
    },
    id => {
        data_type => 'int',
        size => 11,
        is_auto_increment => 1,
    },
    inventory_reserved => {
        data_type => 'tinyint',
        size => 4,
        default_value => '0',
    },
    model_id => {
        data_type => 'int',
        size => 11,
    },
    notes => {
        data_type => 'text',
        is_nullable => 1,
    },
    print_hours => {
        data_type => 'decimal',
        size => 6,2,
        is_nullable => 1,
    },
    printer_cost => {
        data_type => 'decimal',
        size => 10,2,
        is_nullable => 1,
    },
    printer_id => {
        data_type => 'int',
        size => 11,
        is_nullable => 1,
    },
    quantity => {
        data_type => 'int',
        size => 11,
        default_value => '1',
    },
    sitename => {
        data_type => 'varchar',
        size => 100,
    },
    started_at => {
        data_type => 'datetime',
        is_nullable => 1,
    },
    status => {
        data_type => 'varchar',
        size => 20,
        default_value => 'queued',
    },
    total_cost => {
        data_type => 'decimal',
        size => 10,2,
        is_nullable => 1,
    },
    user_id => {
        data_type => 'int',
        size => 11,
    },
    username => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 1,
    },
);
__PACKAGE__->set_primary_key('id');

1;
