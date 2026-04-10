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
        data_type => 'integer',
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

1;
