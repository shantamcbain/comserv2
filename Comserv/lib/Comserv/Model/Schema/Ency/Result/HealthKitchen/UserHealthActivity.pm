package Comserv::Model::Schema::Ency::Result::HealthKitchen::UserHealthActivity;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('hk_user_health_activity');

# One activity on a generated health plan. done is the member's check-off, not a clinical order.
# Create the table via schema-compare.

__PACKAGE__->add_columns(
    id             => { data_type => 'integer', is_auto_increment => 1, is_nullable => 0 },
    health_plan_id => { data_type => 'integer', is_nullable => 0 },
    plan_date      => { data_type => 'date', is_nullable => 1 },
    activity_text  => { data_type => 'text', is_nullable => 0 },
    done           => { data_type => 'tinyint', is_nullable => 0, default_value => 0 },
    created_at     => { data_type => 'datetime', is_nullable => 1, set_on_create => 1 },
    updated_at     => { data_type => 'datetime', is_nullable => 1, set_on_create => 1, set_on_update => 1 },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->belongs_to(
    health_plan => 'Comserv::Model::Schema::Ency::Result::HealthKitchen::UserHealthPlan',
    'health_plan_id',
    { is_foreign_key_constraint => 0 },
);

1;
