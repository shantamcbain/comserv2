package Comserv::Model::Schema::Ency::Result::Crypto_transactions;
use base 'DBIx::Class::Core';

__PACKAGE__->table('crypto_transactions');
__PACKAGE__->add_columns(
    amount_cad => {
        data_type => 'decimal',
        size => 10,2,
    },
    amount_coin => {
        data_type => 'decimal',
        size => 20,8,
    },
    coin => {
        data_type => 'varchar',
        size => 20,
    },
    confirmations => {
        data_type => 'int',
        size => 11,
        default_value => '0',
    },
    created_at => {
        data_type => 'timestamp',
        default_value => 'current_timestamp()',
    },
    expires_at => {
        data_type => 'timestamp',
        is_nullable => 1,
    },
    id => {
        data_type => 'bigint',
        size => 20,
        is_auto_increment => 1,
    },
    payment_transaction_id => {
        data_type => 'bigint',
        size => 20,
        is_nullable => 1,
    },
    points_to_credit => {
        data_type => 'decimal',
        size => 14,4,
        default_value => '0.0000',
    },
    required_confirmations => {
        data_type => 'int',
        size => 11,
        default_value => '3',
    },
    status => {
        data_type => 'varchar',
        size => 30,
        default_value => 'pending',
    },
    tx_hash => {
        data_type => 'varchar',
        size => 200,
        is_nullable => 1,
    },
    updated_at => {
        data_type => 'timestamp',
        default_value => 'current_timestamp()',
    },
    user_id => {
        data_type => 'int',
        size => 11,
    },
    wallet_address => {
        data_type => 'varchar',
        size => 200,
    },
);
__PACKAGE__->set_primary_key('id');

1;
