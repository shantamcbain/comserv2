package Comserv::Model::Schema::Ency::Result::Printing3dJobFilament;
use base 'DBIx::Class::Core';

# One row per tool on a print, written at send time (or entered later to
# stand in for that send). grams is ONE plate, flush included. Complete
# multiplies by printing_3d_jobs.quantity. Do not add these columns to
# printing_3d_jobs — create this table from schema-compare.

__PACKAGE__->table('printing_3d_job_filaments');

__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
    },
    job_id => {
        data_type => 'integer',
    },
    sitename => {
        data_type => 'varchar',
        size      => 100,
    },
    sequence => {
        data_type => 'integer',
    },
    paint_index => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    filament_item_id => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    filament_type => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
    },
    filament_color => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
    },
    color_hex => {
        data_type   => 'varchar',
        size        => 7,
        is_nullable => 1,
    },
    grams => {
        data_type => 'decimal',
        size      => [10, 3],
    },
    ams_slot => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    created_at => {
        data_type     => 'datetime',
        default_value => \'CURRENT_TIMESTAMP',
        is_nullable   => 1,
    },
    updated_at => {
        data_type     => 'datetime',
        default_value => \'CURRENT_TIMESTAMP',
        is_nullable   => 1,
    },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->add_unique_constraint(job_sequence => [qw(job_id sequence)]);

__PACKAGE__->belongs_to(
    job => 'Comserv::Model::Schema::Ency::Result::Printing3dJob',
    'job_id',
);

__PACKAGE__->belongs_to(
    filament_item => 'Comserv::Model::Schema::Ency::Result::Accounting::InventoryItem',
    'filament_item_id',
    { join_type => 'left' },
);

1;
