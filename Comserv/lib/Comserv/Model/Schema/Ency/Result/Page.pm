package Comserv::Model::Schema::Ency::Result::Page;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp', 'EncodedColumn');
__PACKAGE__->table('pages_content');

__PACKAGE__->add_columns(
    'id' => {
        data_type         => 'integer',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    'sitename' => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
    },
    'menu' => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
    },
    'page_code' => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
    },
    'title' => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 0,
    },
    'body' => {
        data_type   => 'text',
        is_nullable => 0,
    },
    'description' => {
        data_type   => 'text',
        is_nullable => 1,
    },
    'keywords' => {
        data_type   => 'text',
        is_nullable => 1,
    },
    'link_order' => {
        data_type   => 'integer',
        is_nullable => 0,
        default_value => 0,
    },
    'status' => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 0,
        default_value => 'active',
    },
    'roles' => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
        default_value => 'public',
    },
    'created_by' => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 0,
    },
    'created_at' => {
        data_type => 'datetime',
        set_on_create => 1,
    },
    'updated_at' => {
        data_type => 'datetime',
        set_on_create => 1,
        set_on_update => 1,
    },
);

__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint(['page_code']);

# Add indexes for common queries
__PACKAGE__->resultset_attributes({
    order_by => ['sitename', 'menu', 'link_order']
});

1;
