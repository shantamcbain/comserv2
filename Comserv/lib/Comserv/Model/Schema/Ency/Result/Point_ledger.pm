package Comserv::Model::Schema::Ency::Result::Point_ledger;
use base 'DBIx::Class::Core';

__PACKAGE__->table('point_ledger');
__PACKAGE__->add_columns(
    amount => {
        data_type => 'decimal',
        size => 14,4,
    },
    balance_after => {
        data_type => 'decimal',
        size => 14,4,
    },
    created_at => {
        data_type => 'timestamp',
        default_value => 'current_timestamp()',
    },
    description => {
        data_type => 'varchar',
        size => 500,
        default_value => '',
    },
    from_user_id => {
        data_type => 'int',
        size => 11,
        is_nullable => 1,
    },
    id => {
        data_type => 'bigint',
        size => 20,
        is_auto_increment => 1,
    },
    reference_id => {
        data_type => 'bigint',
        size => 20,
        is_nullable => 1,
    },
    reference_type => {
        data_type => 'varchar',
        size => 100,
        is_nullable => 1,
    },
    to_user_id => {
        data_type => 'int',
        size => 11,
        is_nullable => 1,
    },
    transaction_type => {
        data_type => 'varchar',
        size => 50,
    },
);
__PACKAGE__->set_primary_key('id');

1;
