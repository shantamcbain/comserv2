package Comserv::Model::Schema::Ency::Result::HealthSymptomDiseaseMap;
use base 'DBIx::Class::Core';

__PACKAGE__->table('health_symptom_disease_map');
__PACKAGE__->add_columns(
    id => {
        data_type         => 'int',
        is_auto_increment => 1,
    },
    symptom_id => {
        data_type => 'int',
    },
    disease_id => {
        data_type => 'int',
    },
    weight => {
        data_type     => 'decimal',
        size          => [5, 2],
        default_value => '1.00',
        is_nullable   => 1,
    },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->belongs_to(
    'symptom' => 'Comserv::Model::Schema::Ency::Result::HealthSymptom',
    'symptom_id',
);

__PACKAGE__->belongs_to(
    'disease' => 'Comserv::Model::Schema::Ency::Result::HealthDisease',
    'disease_id',
);

1;
