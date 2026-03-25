package Comserv::Model::Schema::Ency::Result::PaypalTransaction;
use base 'DBIx::Class::Core';

__PACKAGE__->table('paypal_transactions');
__PACKAGE__->add_columns(
    id => {
        data_type         => 'bigint',
        is_auto_increment => 1,
    },
    user_id => {
        data_type   => 'int',
        is_nullable => 0,
    },
    package_id => {
        data_type   => 'int',
        is_nullable => 1,
    },
    paypal_order_id => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
    },
    paypal_subscription_id => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
    },
    paypal_payer_id => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
    },
    paypal_payer_email => {
        data_type   => 'varchar',
        size        => 255,
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
    points_credited => {
        data_type     => 'bigint',
        is_nullable   => 0,
        default_value => 0,
    },
    payment_type => {
        data_type     => 'varchar',
        size          => 20,
        is_nullable   => 0,
        default_value => 'one_time',
    },
    status => {
        data_type     => 'varchar',
        size          => 30,
        is_nullable   => 0,
        default_value => 'pending',
    },
    paypal_status => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 1,
    },
    ipn_verified => {
        data_type     => 'tinyint',
        size          => 1,
        is_nullable   => 0,
        default_value => 0,
    },
    raw_response => {
        data_type   => 'text',
        is_nullable => 1,
    },
    point_transaction_id => {
        data_type   => 'bigint',
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
    package => 'Comserv::Model::Schema::Ency::Result::PointPackage',
    'package_id',
    { join_type => 'left', on_delete => 'set null' },
);

1;
