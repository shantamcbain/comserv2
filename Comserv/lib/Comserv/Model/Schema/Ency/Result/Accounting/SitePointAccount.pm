package Comserv::Model::Schema::Ency::Result::Accounting::SitePointAccount;
use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->table('site_point_accounts');

__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    sitename => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 0,
    },
    balance => {
        data_type     => 'decimal',
        size          => [15, 4],
        default_value => '0.0000',
        is_nullable   => 0,
    },
    lifetime_earned => {
        data_type     => 'decimal',
        size          => [15, 4],
        default_value => '0.0000',
        is_nullable   => 0,
    },
    lifetime_spent => {
        data_type     => 'decimal',
        size          => [15, 4],
        default_value => '0.0000',
        is_nullable   => 0,
    },
    notes => {
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
__PACKAGE__->add_unique_constraint(['sitename']);

1;
