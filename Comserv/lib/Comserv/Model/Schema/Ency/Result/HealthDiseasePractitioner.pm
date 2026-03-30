package Comserv::Model::Schema::Ency::Result::HealthDiseasePractitioner;
use base 'DBIx::Class::Core';

__PACKAGE__->table('health_disease_practitioners');
__PACKAGE__->add_columns(
    id => {
        data_type         => 'int',
        is_auto_increment => 1,
    },
    disease_id => {
        data_type => 'int',
    },
    practitioner_type_id => {
        data_type => 'int',
    },
    priority => {
        data_type     => 'int',
        default_value => 1,
        is_nullable   => 1,
    },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->belongs_to(
    'disease' => 'Comserv::Model::Schema::Ency::Result::HealthDisease',
    'disease_id',
);

__PACKAGE__->belongs_to(
    'practitioner_type' => 'Comserv::Model::Schema::Ency::Result::HealthPractitionerType',
    'practitioner_type_id',
);

1;
