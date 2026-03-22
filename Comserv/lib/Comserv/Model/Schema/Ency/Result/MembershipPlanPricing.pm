package Comserv::Model::Schema::Ency::Result::MembershipPlanPricing;
use base 'DBIx::Class::Core';
use warnings FATAL => 'all';

__PACKAGE__->table('membership_plan_pricing');

__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
    },
    plan_id => {
        data_type      => 'integer',
        is_foreign_key => 1,
        is_nullable    => 0,
    },
    region_code => {
        data_type   => 'varchar',
        size        => 10,
        is_nullable => 0,
        documentation => 'ISO 3166-1 alpha-2 country code, or DEFAULT for fallback',
    },
    price_monthly => {
        data_type   => 'decimal',
        size        => [10, 2],
        is_nullable => 0,
    },
    price_annual => {
        data_type   => 'decimal',
        size        => [10, 2],
        is_nullable => 0,
    },
    currency => {
        data_type     => 'varchar',
        size          => 10,
        default_value => 'USD',
        is_nullable   => 0,
    },
    created_at => {
        data_type     => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP',
        is_nullable   => 0,
    },
);

__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint(['plan_id', 'region_code']);

__PACKAGE__->belongs_to(
    plan => 'Comserv::Model::Schema::Ency::Result::MembershipPlan',
    'plan_id'
);

1;
