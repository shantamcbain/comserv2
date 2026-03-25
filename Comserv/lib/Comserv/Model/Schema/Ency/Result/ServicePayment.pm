package Comserv::Model::Schema::Ency::Result::ServicePayment;
use base 'DBIx::Class::Core';

__PACKAGE__->table('service_payments');
__PACKAGE__->add_columns(
    id => {
        data_type         => 'bigint',
        is_auto_increment => 1,
    },
    payer_user_id => {
        data_type   => 'int',
        is_nullable => 0,
    },
    payee_user_id => {
        data_type   => 'int',
        is_nullable => 0,
    },
    points => {
        data_type   => 'bigint',
        is_nullable => 0,
    },
    service_description => {
        data_type   => 'varchar',
        size        => 500,
        is_nullable => 0,
    },
    reference_type => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 1,
    },
    reference_id => {
        data_type   => 'int',
        is_nullable => 1,
    },
    status => {
        data_type     => 'varchar',
        size          => 30,
        is_nullable   => 0,
        default_value => 'completed',
    },
    payer_tx_id => {
        data_type   => 'bigint',
        is_nullable => 1,
    },
    payee_tx_id => {
        data_type   => 'bigint',
        is_nullable => 1,
    },
    created_at => {
        data_type     => 'timestamp',
        is_nullable   => 0,
        default_value => \'CURRENT_TIMESTAMP',
    },
);
__PACKAGE__->set_primary_key('id');

__PACKAGE__->belongs_to(
    payer => 'Comserv::Model::Schema::Ency::Result::User',
    'payer_user_id',
);

__PACKAGE__->belongs_to(
    payee => 'Comserv::Model::Schema::Ency::Result::User',
    'payee_user_id',
);

1;
