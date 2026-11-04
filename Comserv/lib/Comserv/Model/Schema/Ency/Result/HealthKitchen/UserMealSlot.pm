package Comserv::Model::Schema::Ency::Result::HealthKitchen::UserMealSlot;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('hk_user_meal_slot');

# One slot on a generated health plan. formula_id -> usbm_formula_tb.record_id, or free_text.
# inventory_ids is a JSON array of inventory item ids used. Create via schema-compare.

__PACKAGE__->add_columns(
    id             => { data_type => 'integer', is_auto_increment => 1, is_nullable => 0 },
    health_plan_id => { data_type => 'integer', is_nullable => 0 },
    plan_date      => { data_type => 'date', is_nullable => 1 },
    meal_slot      => { data_type => 'varchar', size => 20, is_nullable => 0, default_value => 'dinner',
                        comment => 'breakfast | lunch | dinner | tea | snack' },
    formula_id     => { data_type => 'integer', is_nullable => 1 },
    free_text      => { data_type => 'varchar', size => 255, is_nullable => 1 },
    inventory_ids  => { data_type => 'text', is_nullable => 1 },
    created_at     => { data_type => 'datetime', is_nullable => 1, set_on_create => 1 },
    updated_at     => { data_type => 'datetime', is_nullable => 1, set_on_create => 1, set_on_update => 1 },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->belongs_to(
    health_plan => 'Comserv::Model::Schema::Ency::Result::HealthKitchen::UserHealthPlan',
    'health_plan_id',
    { is_foreign_key_constraint => 0 },
);
__PACKAGE__->belongs_to(
    formula => 'Comserv::Model::Schema::Ency::Result::Ency::Formula',
    { 'foreign.record_id' => 'self.formula_id' },
    { is_foreign_key_constraint => 0, join_type => 'LEFT' },
);

1;
