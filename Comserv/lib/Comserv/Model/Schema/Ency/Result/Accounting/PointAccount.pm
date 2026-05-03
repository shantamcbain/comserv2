package Comserv::Model::Schema::Ency::Result::Accounting::PointAccount;
use base 'DBIx::Class::Core';

__PACKAGE__->table('point_accounts');
__PACKAGE__->add_columns(
    id => {
        data_type         => 'int',
        is_auto_increment => 1,
    },
    user_id => {
        data_type   => 'int',
        is_nullable => 0,
    },
    balance => {
        data_type     => 'decimal',
        size          => [14, 4],
        is_nullable   => 0,
        default_value => '0.0000',
    },
    lifetime_earned => {
        data_type     => 'decimal',
        size          => [14, 4],
        is_nullable   => 0,
        default_value => '0.0000',
    },
    lifetime_spent => {
        data_type     => 'decimal',
        size          => [14, 4],
        is_nullable   => 0,
        default_value => '0.0000',
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
__PACKAGE__->add_unique_constraint('uq_point_accounts_user' => ['user_id']);

__PACKAGE__->belongs_to(
    user => 'Comserv::Model::Schema::Ency::Result::User',
    'user_id',
);

__PACKAGE__->has_many(
    credits_received => 'Comserv::Model::Schema::Ency::Result::Accounting::PointLedger',
    { 'foreign.to_user_id' => 'self.user_id' },
);

__PACKAGE__->has_many(
    debits_sent => 'Comserv::Model::Schema::Ency::Result::Accounting::PointLedger',
    { 'foreign.from_user_id' => 'self.user_id' },
);

1;
