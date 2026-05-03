package Comserv::Model::Schema::Ency::Result::File;
use base 'DBIx::Class::Core';

__PACKAGE__->table('files');
__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    workshop_id => {
        data_type => 'integer',
        is_nullable => 1,
    },

    file_name => {
        data_type => 'varchar',
        size => 255,
    },
    file_type => {
        data_type => 'varchar',
        size => 255,
    },
    file_data => {
        data_type => 'blob',
    },
    site_id => {
        data_type => 'integer',
    },
    reference_id => {
        data_type => 'integer',
    },
    category_id => {
        data_type => 'integer',
    },
    share_id => {
        data_type => 'integer',
    },
    description => {
        data_type => 'text',
    },
    upload_date => {
        data_type => 'datetime',
    },
    file_size => {
        data_type => 'bigint',
    },
    file_path => {
        data_type => 'varchar',
        size => 255,
    },
    file_url => {
        data_type => 'varchar',
        size => 255,
    },
    file_status => {
        data_type => 'varchar',
        size => 255,
    },
    file_format => {
        data_type => 'varchar',
        size => 255,
    },
    user_id => {
        data_type => 'integer',
    },
    nfs_path => {
        data_type   => 'varchar',
        size        => 1000,
        is_nullable => 1,
    },
    external_url => {
        data_type   => 'varchar',
        size        => 1000,
        is_nullable => 1,
    },
    access_level => {
        data_type     => 'varchar',
        size          => 50,
        is_nullable   => 1,
        default_value => 'site_only',
    },
    source_type => {
        data_type     => 'varchar',
        size          => 20,
        is_nullable   => 1,
        default_value => 'nfs',
    },
    sitename => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
    },
    is_duplicate => {
        data_type     => 'tinyint',
        is_nullable   => 1,
        default_value => 0,
    },
    duplicate_of => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    file_hash => {
        data_type   => 'varchar',
        size        => 64,
        is_nullable => 1,
    },
);
__PACKAGE__->set_primary_key('id');
__PACKAGE__->belongs_to(
    'workshop' => 'Comserv::Model::Schema::Ency::Result::WorkShop',
    'workshop_id'
);
__PACKAGE__->belongs_to(
    'name' => 'Comserv::Model::Schema::Ency::Result::Site',
    'site_id'
);
__PACKAGE__->belongs_to(
    'reference' => 'Comserv::Model::Schema::Ency::Result::Ency::Reference',
    'reference_id'
);
__PACKAGE__->belongs_to(
    'category' => 'Comserv::Model::Schema::Ency::Result::Category',
    'category_id'
);

# Add relationships if needed...

1;