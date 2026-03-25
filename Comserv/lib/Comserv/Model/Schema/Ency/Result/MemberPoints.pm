package Comserv::Model::Schema::Ency::Result::MemberPoints;
use base 'DBIx::Class::Core';

__PACKAGE__->table('member_points');
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
        data_type     => 'bigint',
        is_nullable   => 0,
        default_value => 0,
    },
    lifetime_earned => {
        data_type     => 'bigint',
        is_nullable   => 0,
        default_value => 0,
    },
    lifetime_spent => {
        data_type     => 'bigint',
        is_nullable   => 0,
        default_value => 0,
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
__PACKAGE__->add_unique_constraint('uq_member_points_user' => ['user_id']);

__PACKAGE__->belongs_to(
    user => 'Comserv::Model::Schema::Ency::Result::User',
    'user_id',
);

__PACKAGE__->has_many(
    transactions => 'Comserv::Model::Schema::Ency::Result::PointTransaction',
    { 'foreign.user_id' => 'self.user_id' },
);

1;
