package Comserv::Model::Schema::Ency::Result::Printing_3d_models;
use base 'DBIx::Class::Core';

__PACKAGE__->table('printing_3d_models');
__PACKAGE__->add_columns(
    added_by => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 1,
    },
    created_at => {
        data_type => 'datetime',
        is_nullable => 1,
        default_value => 'current_timestamp()',
    },
    description => {
        data_type => 'text',
        is_nullable => 1,
    },
    file_id => {
        data_type => 'int',
        size => 11,
        is_nullable => 1,
    },
    file_type => {
        data_type => 'varchar',
        size => 20,
        is_nullable => 1,
    },
    id => {
        data_type => 'int',
        size => 11,
        is_auto_increment => 1,
    },
    is_active => {
        data_type => 'tinyint',
        size => 4,
        default_value => '1',
    },
    name => {
        data_type => 'varchar',
        size => 255,
    },
    nfs_path => {
        data_type => 'text',
        is_nullable => 1,
    },
    sitename => {
        data_type => 'varchar',
        size => 100,
    },
    source => {
        data_type => 'varchar',
        size => 20,
        default_value => 'filemanager',
    },
    source_url => {
        data_type => 'text',
        is_nullable => 1,
    },
    tags => {
        data_type => 'text',
        is_nullable => 1,
    },
    thumbnail_url => {
        data_type => 'text',
        is_nullable => 1,
    },
);
__PACKAGE__->set_primary_key('id');

1;
