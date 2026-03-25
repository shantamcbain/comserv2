package Comserv::Model::Schema::Ency::Result::PaypalSubscription;
use base 'DBIx::Class::Core';

__PACKAGE__->table('paypal_subscriptions');
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
        is_nullable => 0,
    },
    paypal_subscription_id => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 0,
    },
    status => {
        data_type     => 'varchar',
        size          => 30,
        is_nullable   => 0,
        default_value => 'active',
    },
    next_billing_date => {
        data_type   => 'date',
        is_nullable => 1,
    },
    points_per_cycle => {
        data_type   => 'bigint',
        is_nullable => 0,
    },
    price_per_cycle_cad => {
        data_type   => 'decimal',
        size        => [10, 2],
        is_nullable => 0,
    },
    started_at => {
        data_type     => 'timestamp',
        is_nullable   => 0,
        default_value => \'CURRENT_TIMESTAMP',
    },
    cancelled_at => {
        data_type   => 'timestamp',
        is_nullable => 1,
    },
    updated_at => {
        data_type     => 'timestamp',
        is_nullable   => 0,
        default_value => \'CURRENT_TIMESTAMP',
    },
);
__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint('uq_paypal_sub_id' => ['paypal_subscription_id']);

__PACKAGE__->belongs_to(
    user => 'Comserv::Model::Schema::Ency::Result::User',
    'user_id',
);

__PACKAGE__->belongs_to(
    package => 'Comserv::Model::Schema::Ency::Result::PointPackage',
    'package_id',
);

1;
