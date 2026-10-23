package Comserv::Model::Schema::Ency::Result::HealthKitchen::UserActiveSymptom;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('hk_user_active_symptom');

# User-owned overlay on ency_symptom_tb. Resolved rows drop out of planner input.

__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    user_id => {
        data_type   => 'integer',
        is_nullable => 0,
    },
    sitename => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
    },
    symptom_id => {
        data_type   => 'integer',
        is_nullable => 0,
    },
    severity => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 1,
    },
    status => {
        data_type     => 'varchar',
        size          => 20,
        is_nullable   => 0,
        default_value => 'active',
    },
    started_at => {
        data_type     => 'datetime',
        is_nullable   => 1,
        set_on_create => 1,
    },
    resolved_at => {
        data_type   => 'datetime',
        is_nullable => 1,
    },
    notes => {
        data_type   => 'text',
        is_nullable => 1,
    },
    created_at => {
        data_type     => 'datetime',
        is_nullable   => 1,
        set_on_create => 1,
    },
    updated_at => {
        data_type     => 'datetime',
        is_nullable   => 1,
        set_on_create => 1,
        set_on_update => 1,
    },
);

__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint(hk_symptom_user_site => [qw/user_id sitename symptom_id/]);

__PACKAGE__->belongs_to(
    symptom => 'Comserv::Model::Schema::Ency::Result::Ency::Symptom',
    { 'foreign.record_id' => 'self.symptom_id' },
    { is_foreign_key_constraint => 0, join_type => 'LEFT' },
);

1;
