package Comserv::Model::Schema::Ency::Result::Accounting::FounderRoyaltyConfig;
use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->table('founder_royalty_config');

__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    founder_username => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 0,
    },
    royalty_percent => {
        data_type     => 'decimal',
        size          => [5, 2],
        default_value => '5.00',
        is_nullable   => 0,
    },
    active => {
        data_type     => 'tinyint',
        default_value => 1,
        is_nullable   => 0,
    },
    note => {
        data_type   => 'text',
        is_nullable => 1,
    },
    created_at => {
        data_type     => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP',
        is_nullable   => 0,
    },
    updated_at => {
        data_type     => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP',
        is_nullable   => 0,
    },
);

__PACKAGE__->set_primary_key('id');

1;
