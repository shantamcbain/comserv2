package Comserv::Model::Schema::Ency::Result::HealthKitchen::UserHealthPlan;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('hk_user_health_plan');

# Generated wellness plan header. Not the inventory meal plan (hk_meal_plan).
# Create the table via schema-compare. The app does not diagnose.

__PACKAGE__->add_columns(
    id            => { data_type => 'integer', is_auto_increment => 1, is_nullable => 0 },
    user_id       => { data_type => 'integer', is_nullable => 0 },
    sitename      => { data_type => 'varchar', size => 255, is_nullable => 0 },
    source        => { data_type => 'varchar', size => 20, is_nullable => 0, default_value => 'util',
                       comment => 'util | ai' },
    trust_summary => { data_type => 'text', is_nullable => 1 },
    body_json     => { data_type => 'text', is_nullable => 1 },
    created_at    => { data_type => 'datetime', is_nullable => 1, set_on_create => 1 },
    updated_at    => { data_type => 'datetime', is_nullable => 1, set_on_create => 1, set_on_update => 1 },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->has_many(
    meal_slots => 'Comserv::Model::Schema::Ency::Result::HealthKitchen::UserMealSlot',
    { 'foreign.health_plan_id' => 'self.id' },
    { cascade_delete => 1 },
);
__PACKAGE__->has_many(
    activities => 'Comserv::Model::Schema::Ency::Result::HealthKitchen::UserHealthActivity',
    { 'foreign.health_plan_id' => 'self.id' },
    { cascade_delete => 1 },
);

1;
