package Comserv::Model::Schema::Ency::Result::NfsDirectory;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components("TimeStamp");
__PACKAGE__->table('nfs_directory');

__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
    },
    sitename => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 0,
    },
    site_id => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    nfs_path => {
        data_type   => 'varchar',
        size        => 1000,
        is_nullable => 0,
    },
    description => {
        data_type   => 'text',
        is_nullable => 1,
    },
    created_by => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    created_at => {
        data_type     => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP',
        is_nullable   => 1,
    },
    updated_at => {
        data_type     => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP',
        is_nullable   => 1,
    },
    is_active => {
        data_type     => 'tinyint',
        default_value => 1,
        is_nullable   => 1,
    },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->belongs_to(
    site => 'Comserv::Model::Schema::Ency::Result::Site',
    { 'foreign.id' => 'self.site_id' },
    { join_type => 'left' },
);

__PACKAGE__->belongs_to(
    creator => 'Comserv::Model::Schema::Ency::Result::User',
    { 'foreign.id' => 'self.created_by' },
    { join_type => 'left' },
);

1;
