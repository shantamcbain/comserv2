package Comserv::Model::Schema::Ency::Result::AiNavigationShortcut;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->table('ai_navigation_shortcuts');

__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    label => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 0,
    },
    url => {
        data_type   => 'varchar',
        size        => 512,
        is_nullable => 0,
    },
    trigger_phrases => {
        data_type   => 'text',
        is_nullable => 1,
        documentation => 'JSON array of phrases, e.g. ["open my bank","my bank account"]',
    },
    category => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 1,
        documentation => 'Menu category hint: Main_links, Member_links, Admin_links, Hosted_link',
    },
    sitename => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 0,
        default_value => 'All',
    },
    is_private => {
        data_type     => 'tinyint',
        size          => 1,
        is_nullable   => 0,
        default_value => 0,
    },
    owner_username => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
    },
    min_role => {
        data_type     => 'varchar',
        size          => 20,
        is_nullable   => 0,
        default_value => 'user',
        documentation => 'guest, user, or admin',
    },
    link_order => {
        data_type     => 'integer',
        is_nullable   => 1,
        default_value => 0,
    },
    status => {
        data_type     => 'tinyint',
        is_nullable   => 0,
        default_value => 1,
    },
    source => {
        data_type     => 'varchar',
        size          => 30,
        is_nullable   => 1,
        default_value => 'manual',
    },
    created_at => {
        data_type     => 'datetime',
        is_nullable   => 1,
        default_value => \'CURRENT_TIMESTAMP',
    },
    updated_at => {
        data_type     => 'datetime',
        is_nullable   => 1,
        default_value => \'CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP',
    },
);

__PACKAGE__->set_primary_key('id');

sub primary_columns {
    return ('id');
}

sub columns_info {
    return {
        id => {
            data_type         => 'integer',
            is_auto_increment => 1,
            is_nullable       => 0,
        },
        label => {
            data_type   => 'varchar',
            size        => 100,
            is_nullable => 0,
        },
        url => {
            data_type   => 'varchar',
            size        => 512,
            is_nullable => 0,
        },
        trigger_phrases => {
            data_type   => 'text',
            is_nullable => 1,
        },
        category => {
            data_type   => 'varchar',
            size        => 50,
            is_nullable => 1,
        },
        sitename => {
            data_type   => 'varchar',
            size        => 50,
            is_nullable => 0,
            default_value => 'All',
        },
        is_private => {
            data_type     => 'tinyint',
            size          => 1,
            is_nullable   => 0,
            default_value => 0,
        },
        owner_username => {
            data_type   => 'varchar',
            size        => 100,
            is_nullable => 1,
        },
        min_role => {
            data_type     => 'varchar',
            size          => 20,
            is_nullable   => 0,
            default_value => 'user',
        },
        link_order => {
            data_type     => 'integer',
            is_nullable   => 1,
            default_value => 0,
        },
        status => {
            data_type     => 'tinyint',
            is_nullable   => 0,
            default_value => 1,
        },
        source => {
            data_type     => 'varchar',
            size          => 30,
            is_nullable   => 1,
            default_value => 'manual',
        },
        created_at => {
            data_type     => 'datetime',
            is_nullable   => 1,
            default_value => \'CURRENT_TIMESTAMP',
        },
        updated_at => {
            data_type     => 'datetime',
            is_nullable   => 1,
            default_value => \'CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP',
        },
    };
}

1;