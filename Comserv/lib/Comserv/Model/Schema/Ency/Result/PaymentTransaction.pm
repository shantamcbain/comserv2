package Comserv::Model::Schema::Ency::Result::PaymentTransaction;
use base 'DBIx::Class::Core';

__PACKAGE__->table('payment_transactions');
__PACKAGE__->add_columns(
    id => {
        data_type         => 'bigint',
        is_auto_increment => 1,
    },
    user_id => {
        data_type   => 'int',
        is_nullable => 0,
    },
    payable_type => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 0,
    },
    payable_id => {
        data_type   => 'int',
        is_nullable => 1,
    },
    amount => {
        data_type   => 'decimal',
        size        => [10, 2],
        is_nullable => 0,
    },
    currency => {
        data_type     => 'char',
        size          => 3,
        is_nullable   => 0,
        default_value => 'CAD',
    },
    amount_cad => {
        data_type   => 'decimal',
        size        => [10, 2],
        is_nullable => 0,
    },
    provider => {
        data_type   => 'varchar',
        size        => 30,
        is_nullable => 0,
    },
    provider_transaction_id => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    status => {
        data_type     => 'varchar',
        size          => 30,
        is_nullable   => 0,
        default_value => 'pending',
    },
    description => {
        data_type   => 'varchar',
        size        => 500,
        is_nullable => 1,
    },
    points_credited => {
        data_type     => 'decimal',
        size          => [14, 4],
        is_nullable   => 0,
        default_value => '0',
    },
    point_ledger_id => {
        data_type   => 'bigint',
        is_nullable => 1,
    },
    metadata => {
        data_type   => 'text',
        is_nullable => 1,
    },
    ip_address => {
        data_type   => 'varchar',
        size        => 45,
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

__PACKAGE__->belongs_to(
    point_ledger_entry => 'Comserv::Model::Schema::Ency::Result::PointLedger',
    'point_ledger_id',
    { join_type => 'left' },
);

1;
