package Comserv::Model::Schema::Ency::Result::WorkshopResource;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('TimeStamp');
__PACKAGE__->table('workshop_resource');

__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
    },
    file_name => {
        data_type => 'varchar',
        size      => 255,
    },
    file_path => {
        data_type => 'varchar',
        size      => 500,
    },
    file_type => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
    },
    file_ext => {
        data_type   => 'varchar',
        size        => 20,
        is_nullable => 1,
    },
    file_size => {
        data_type   => 'bigint',
        is_nullable => 1,
    },
    description => {
        data_type   => 'text',
        is_nullable => 1,
    },
    uploaded_by => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    sitename => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
    },
    access_level => {
        data_type     => 'enum',
        default_value => 'site_only',
        extra         => { list => ['all_leaders', 'site_only', 'workshop_specific'] },
    },
    workshop_id => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    created_at => {
        data_type     => 'timestamp',
        set_on_create => 1,
        default_value => \'CURRENT_TIMESTAMP',
    },
    updated_at => {
        data_type     => 'timestamp',
        set_on_create => 1,
        set_on_update => 1,
        default_value => \'CURRENT_TIMESTAMP',
    },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->belongs_to(
    uploader => 'Comserv::Model::Schema::Ency::Result::User',
    { 'foreign.id' => 'self.uploaded_by' },
    { join_type => 'LEFT' },
);

__PACKAGE__->belongs_to(
    workshop => 'Comserv::Model::Schema::Ency::Result::WorkShop',
    { 'foreign.id' => 'self.workshop_id' },
    { join_type => 'LEFT' },
);

1;
