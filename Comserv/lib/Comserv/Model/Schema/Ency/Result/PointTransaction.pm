package Comserv::Model::Schema::Ency::Result::PointTransaction;
use base 'DBIx::Class::Core';

__PACKAGE__->table('point_transactions');
__PACKAGE__->add_columns(
    id => {
        data_type         => 'bigint',
        is_auto_increment => 1,
    },
    user_id => {
        data_type   => 'int',
        is_nullable => 0,
    },
    amount => {
        data_type   => 'bigint',
        is_nullable => 0,
    },
    balance_after => {
        data_type   => 'bigint',
        is_nullable => 0,
    },
    type => {
        data_type => 'varchar',
        size      => 50,
        is_nullable => 0,
    },
    status => {
        data_type     => 'varchar',
        size          => 30,
        is_nullable   => 0,
        default_value => 'completed',
    },
    reference_type => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 1,
    },
    reference_id => {
        data_type   => 'bigint',
        is_nullable => 1,
    },
    description => {
        data_type     => 'varchar',
        size          => 500,
        is_nullable   => 0,
        default_value => '',
    },
    created_by => {
        data_type   => 'int',
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
    user => 'Comserv::Model::Schema::Ency::Result::User',
    'user_id',
);

__PACKAGE__->belongs_to(
    created_by_user => 'Comserv::Model::Schema::Ency::Result::User',
    'created_by',
    { join_type => 'left', on_delete => 'set null' },
);

1;
