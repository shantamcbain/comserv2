package Comserv::Model::Schema::Forager::Result::Page;

use strict;
use warnings;

use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp', 'EncodedColumn');
__PACKAGE__->table('page');

__PACKAGE__->add_columns(
    'record_id',
    {
        data_type         => 'integer',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    'sitename',
    {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
    },
    'menu',
    {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
    },
    'page_code',
    {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
    },
    'page_site',
    {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
    },
    'app_title',
    {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
    },
    'view_name',
    {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
    },
    'body',
    {
        data_type   => 'text',
        is_nullable => 0,
    },
    'newsletter',
    {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
    },
    'linkedin',
    {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
    },
    'description',
    {
        data_type   => 'text',
        is_nullable => 0,
    },
    'keywords',
    {
        data_type   => 'text',
        is_nullable => 0,
    },
    'link_order',
    {
        data_type   => 'integer',
        is_nullable => 0,
    },
    'news',
    {
        data_type   => 'integer',
        is_nullable => 0,
    },
    'status',
    {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
    },
    'share',
    {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
    },
    'username_of_poster',
    {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
    },
    'mailchimp',
    {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
    },
    'lastupdate',
    {
        data_type     => 'datetime',
        set_on_create => 1,
        set_on_update => 1,
    },
    'last_mod_by',
    {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
    },
    'last_mod_date',
    {
        data_type     => 'datetime',
        set_on_create => 1,
        set_on_update => 1,
    },
    'comments',
    {
        data_type   => 'text',
        is_nullable => 0,
    },
);

__PACKAGE__->set_primary_key('record_id');
__PACKAGE__->add_unique_constraint(['page_code']);

1;