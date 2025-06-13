package Comserv::Model::Schema::Ency::Result::InternalLinksTb;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->table('internal_links_tb');

__PACKAGE__->add_columns(
    'id' => {
        data_type => 'integer',
        is_auto_increment => 1,
        is_nullable => 0,
    },
    'category' => {
        data_type => 'varchar',
        size => 50,
        is_nullable => 0,
    },
    'sitename' => {
        data_type => 'varchar',
        size => 50,
        is_nullable => 0,
    },
    'name' => {
        data_type => 'varchar',
        size => 100,
        is_nullable => 0,
    },
    'url' => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 0,
    },
    'target' => {
        data_type => 'varchar',
        size => 20,
        is_nullable => 1,
        default_value => '_self',
    },
    'description' => {
        data_type => 'text',
        is_nullable => 1,
    },
    'link_order' => {
        data_type => 'integer',
        is_nullable => 1,
        default_value => 0,
    },
    'status' => {
        data_type => 'integer',
        is_nullable => 1,
        default_value => 1,
    },
    'created_at' => {
        data_type => 'datetime',
        is_nullable => 1,
        default_value => \'CURRENT_TIMESTAMP',
    },
    'updated_at' => {
        data_type => 'datetime',
        is_nullable => 1,
        default_value => \'CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP',
    },
);

__PACKAGE__->set_primary_key('id');

sub primary_columns {
    return ('id');
}

sub columns_info {
    return {
        'id' => {
            data_type => 'integer',
            is_auto_increment => 1,
            is_nullable => 0,
        },
        'category' => {
            data_type => 'varchar',
            size => 50,
            is_nullable => 0,
        },
        'sitename' => {
            data_type => 'varchar',
            size => 50,
            is_nullable => 0,
        },
        'name' => {
            data_type => 'varchar',
            size => 100,
            is_nullable => 0,
        },
        'url' => {
            data_type => 'varchar',
            size => 255,
            is_nullable => 0,
        },
        'target' => {
            data_type => 'varchar',
            size => 20,
            is_nullable => 1,
            default_value => '_self',
        },
        'description' => {
            data_type => 'text',
            is_nullable => 1,
        },
        'link_order' => {
            data_type => 'integer',
            is_nullable => 1,
            default_value => 0,
        },
        'status' => {
            data_type => 'integer',
            is_nullable => 1,
            default_value => 1,
        },
        'created_at' => {
            data_type => 'datetime',
            is_nullable => 1,
            default_value => \'CURRENT_TIMESTAMP',
        },
        'updated_at' => {
            data_type => 'datetime',
            is_nullable => 1,
            default_value => \'CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP',
        },
    };
}

1;