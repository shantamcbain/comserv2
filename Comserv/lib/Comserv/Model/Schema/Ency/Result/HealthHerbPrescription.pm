package Comserv::Model::Schema::Ency::Result::HealthHerbPrescription;
use base 'DBIx::Class::Core';

__PACKAGE__->table('health_herb_prescriptions');
__PACKAGE__->add_columns(
    id => {
        data_type         => 'int',
        is_auto_increment => 1,
    },
    plan_id => {
        data_type => 'int',
    },
    herb_record_id => {
        data_type   => 'int',
        is_nullable => 1,
    },
    herb_name => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    dosage => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    preparation => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    frequency => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
    },
    duration_weeks => {
        data_type   => 'int',
        is_nullable => 1,
    },
    priority => {
        data_type     => 'int',
        default_value => 1,
        is_nullable   => 1,
    },
    notes => {
        data_type   => 'text',
        is_nullable => 1,
    },
    created_at => {
        data_type   => 'datetime',
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->belongs_to(
    'member_plan' => 'Comserv::Model::Schema::Ency::Result::HealthMemberPlan',
    'plan_id',
);

1;
