package Comserv::Model::Schema::Ency::Result::Point_accounts;
use base 'DBIx::Class::Core';

__PACKAGE__->table('point_accounts');
__PACKAGE__->add_columns(
    balance => {
        data_type => 'decimal',
        size => 14,4,
        default_value => '0.0000',
    },
    created_at => {
        data_type => 'timestamp',
        default_value => 'current_timestamp()',
    },
    id => {
        data_type => 'int',
        size => 11,
        is_auto_increment => 1,
    },
    lifetime_earned => {
        data_type => 'decimal',
        size => 14,4,
        default_value => '0.0000',
    },
    lifetime_spent => {
        data_type => 'decimal',
        size => 14,4,
        default_value => '0.0000',
    },
    updated_at => {
        data_type => 'timestamp',
        default_value => 'current_timestamp()',
    },
    user_id => {
        data_type => 'int',
        size => 11,
    },
);
__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint('uq_point_accounts_user' => ['user_id']);

1;
