package Comserv::Model::Schema::Ency::Result::Accounting::PointPackage;
use base 'DBIx::Class::Core';

__PACKAGE__->table('point_packages');
__PACKAGE__->add_columns(
    id => {
        data_type         => 'int',
        is_auto_increment => 1,
    },
    name => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 0,
    },
    description => {
        data_type   => 'text',
        is_nullable => 1,
    },
    points => {
        data_type   => 'bigint',
        is_nullable => 0,
    },
    price_cad => {
        data_type   => 'decimal',
        size        => [10, 2],
        is_nullable => 0,
    },
    package_type => {
        data_type     => 'varchar',
        size          => 20,
        is_nullable   => 0,
        default_value => 'one_time',
    },
    paypal_plan_id => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
    },
    is_active => {
        data_type     => 'tinyint',
        size          => 1,
        is_nullable   => 0,
        default_value => 1,
    },
    sort_order => {
        data_type     => 'int',
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

__PACKAGE__->has_many(
    payment_transactions => 'Comserv::Model::Schema::Ency::Result::Accounting::PaymentTransaction',
    sub {
        my $args = shift;
        return (
            {
                "$args->{foreign_alias}.payable_id"   => { -ident => "$args->{self_alias}.id" },
                "$args->{foreign_alias}.payable_type" => 'point_purchase',
            },
            $args->{self_rowobj} && {
                "$args->{foreign_alias}.payable_id"   => $args->{self_rowobj}->id,
                "$args->{foreign_alias}.payable_type" => 'point_purchase',
            },
        );
    },
);

1;
