package Comserv::Model::Schema::Ency::Result::PointLedger;
use base 'DBIx::Class::Core';

__PACKAGE__->table('point_ledger');
__PACKAGE__->add_columns(
    id => {
        data_type         => 'bigint',
        is_auto_increment => 1,
    },
    from_user_id => {
        data_type   => 'int',
        is_nullable => 1,
    },
    to_user_id => {
        data_type   => 'int',
        is_nullable => 1,
    },
    amount => {
        data_type   => 'decimal',
        size        => [14, 4],
        is_nullable => 0,
    },
    transaction_type => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 0,
    },
    description => {
        data_type     => 'varchar',
        size          => 500,
        is_nullable   => 0,
        default_value => '',
    },
    reference_type => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
    },
    reference_id => {
        data_type   => 'bigint',
        is_nullable => 1,
    },
    balance_after => {
        data_type   => 'decimal',
        size        => [14, 4],
        is_nullable => 0,
    },
    created_at => {
        data_type     => 'timestamp',
        is_nullable   => 0,
        default_value => \'CURRENT_TIMESTAMP',
    },
);
__PACKAGE__->set_primary_key('id');

__PACKAGE__->belongs_to(
    from_user => 'Comserv::Model::Schema::Ency::Result::User',
    'from_user_id',
    { join_type => 'left' },
);

__PACKAGE__->belongs_to(
    to_user => 'Comserv::Model::Schema::Ency::Result::User',
    'to_user_id',
    { join_type => 'left' },
);

1;
