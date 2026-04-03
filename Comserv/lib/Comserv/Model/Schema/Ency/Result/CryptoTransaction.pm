package Comserv::Model::Schema::Ency::Result::CryptoTransaction;
use base 'DBIx::Class::Core';

__PACKAGE__->table('crypto_transactions');
__PACKAGE__->add_columns(
    id => {
        data_type         => 'bigint',
        is_auto_increment => 1,
    },
    user_id => {
        data_type   => 'int',
        is_nullable => 0,
    },
    coin => {
        data_type   => 'varchar',
        size        => 20,
        is_nullable => 0,
    },
    wallet_address => {
        data_type   => 'varchar',
        size        => 200,
        is_nullable => 0,
    },
    tx_hash => {
        data_type   => 'varchar',
        size        => 200,
        is_nullable => 1,
    },
    amount_coin => {
        data_type   => 'decimal',
        size        => [20, 8],
        is_nullable => 0,
    },
    amount_cad => {
        data_type   => 'decimal',
        size        => [10, 2],
        is_nullable => 0,
    },
    points_credited => {
        data_type     => 'bigint',
        is_nullable   => 0,
        default_value => 0,
    },
    confirmations => {
        data_type     => 'int',
        is_nullable   => 0,
        default_value => 0,
    },
    required_confirmations => {
        data_type     => 'int',
        is_nullable   => 0,
        default_value => 3,
    },
    status => {
        data_type     => 'varchar',
        size          => 30,
        is_nullable   => 0,
        default_value => 'pending',
    },
    point_transaction_id => {
        data_type   => 'bigint',
        is_nullable => 1,
    },
    expires_at => {
        data_type   => 'timestamp',
        is_nullable => 1,
    },
    created_at => {
        data_type     => 'timestamp',
        is_nullable   => 0,
        default_value => \'CURRENT_TIMESTAMP',
    },
    updated_at => {
        data_type     => 'timestamp',
        is_nullable   => 0,
        default_value => \'CURRENT_TIMESTAMP',
    },
);
__PACKAGE__->set_primary_key('id');

__PACKAGE__->belongs_to(
    user => 'Comserv::Model::Schema::Ency::Result::User',
    'user_id',
);

1;
