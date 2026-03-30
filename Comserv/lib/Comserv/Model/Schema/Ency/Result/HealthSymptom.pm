package Comserv::Model::Schema::Ency::Result::HealthSymptom;
use base 'DBIx::Class::Core';

__PACKAGE__->table('health_symptoms');
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
    category => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
    },
    sitename => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    created_at => {
        data_type     => 'datetime',
        is_nullable   => 1,
    },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->has_many(
    'disease_maps' => 'Comserv::Model::Schema::Ency::Result::HealthSymptomDiseaseMap',
    'symptom_id',
);

1;
