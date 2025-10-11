package Comserv::Model::Schema::Ency::Result::NetworkDevice;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components(qw/InflateColumn::DateTime Core/);
__PACKAGE__->table('network_devices');
__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
        is_nullable => 0,
    },
    device_name => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 0,
    },
    ip_address => {
        data_type => 'varchar',
        size => 45,
        is_nullable => 0,
    },
    mac_address => {
        data_type => 'varchar',
        size => 45,
        is_nullable => 1,
    },
    device_type => {
        data_type => 'varchar',
        size => 100,
        is_nullable => 1,
    },
    location => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 1,
    },
    purpose => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 1,
    },
    notes => {
        data_type => 'text',
        is_nullable => 1,
    },
    site_name => {
        data_type => 'varchar',
        size => 100,
        is_nullable => 0,
    },
    network_id => {
        data_type => 'varchar',
        size => 100,
        is_nullable => 1,
    },
    services => {
        data_type => 'text',
        is_nullable => 1,
    },
    created_at => {
        data_type => 'datetime',
        is_nullable => 1,
    },
    updated_at => {
        data_type => 'datetime',
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key('id');

# Define relationship with Site model
__PACKAGE__->belongs_to(
    'site',
    'Comserv::Model::Schema::Ency::Result::Site',
    { 'foreign.name' => 'self.site_name' },
    { join_type => 'LEFT', on_delete => 'CASCADE' }
);

sub primary_columns {
    return ('id');
}

sub columns_info {
    my $self = shift;
    return {
        id => {
            data_type => 'integer',
            is_auto_increment => 1,
            is_nullable => 0,
        },
        device_name => {
            data_type => 'varchar',
            size => 255,
            is_nullable => 0,
        },
        ip_address => {
            data_type => 'varchar',
            size => 45,
            is_nullable => 0,
        },
        mac_address => {
            data_type => 'varchar',
            size => 45,
            is_nullable => 1,
        },
        device_type => {
            data_type => 'varchar',
            size => 100,
            is_nullable => 1,
        },
        location => {
            data_type => 'varchar',
            size => 255,
            is_nullable => 1,
        },
        purpose => {
            data_type => 'varchar',
            size => 255,
            is_nullable => 1,
        },
        notes => {
            data_type => 'text',
            is_nullable => 1,
        },
        site_name => {
            data_type => 'varchar',
            size => 100,
            is_nullable => 0,
        },
        network_id => {
            data_type => 'varchar',
            size => 100,
            is_nullable => 1,
        },
        services => {
            data_type => 'text',
            is_nullable => 1,
        },
        created_at => {
            data_type => 'datetime',
            is_nullable => 1,
        },
        updated_at => {
            data_type => 'datetime',
            is_nullable => 1,
        },
    };
}

1;