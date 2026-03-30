package Comserv::Model::Schema::Ency::Result::HealthDisease;
use base 'DBIx::Class::Core';

__PACKAGE__->table('health_diseases');
__PACKAGE__->add_columns(
    id => {
        data_type         => 'int',
        is_auto_increment => 1,
    },
    name => {
        data_type => 'varchar',
        size      => 255,
    },
    description => {
        data_type   => 'text',
        is_nullable => 1,
    },
    icd_code => {
        data_type   => 'varchar',
        size        => 20,
        is_nullable => 1,
    },
    natural_approach => {
        data_type   => 'text',
        is_nullable => 1,
    },
    allopathic_notes => {
        data_type   => 'text',
        is_nullable => 1,
    },
    sitename => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    created_at => {
        data_type   => 'datetime',
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->has_many(
    'symptom_maps' => 'Comserv::Model::Schema::Ency::Result::HealthSymptomDiseaseMap',
    'disease_id',
);

__PACKAGE__->has_many(
    'practitioner_maps' => 'Comserv::Model::Schema::Ency::Result::HealthDiseasePractitioner',
    'disease_id',
);

__PACKAGE__->has_many(
    'member_plans' => 'Comserv::Model::Schema::Ency::Result::HealthMemberPlan',
    'disease_id',
);

1;
