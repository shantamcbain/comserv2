package Comserv::Model::Schema::Ency::Result::HealthPractitionerType;
use base 'DBIx::Class::Core';

__PACKAGE__->table('health_practitioner_types');
__PACKAGE__->add_columns(
    id => {
        data_type         => 'int',
        is_auto_increment => 1,
    },
    name => {
        data_type => 'varchar',
        size      => 100,
    },
    description => {
        data_type   => 'text',
        is_nullable => 1,
    },
    sitename => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->has_many(
    'disease_maps' => 'Comserv::Model::Schema::Ency::Result::HealthDiseasePractitioner',
    'practitioner_type_id',
);

1;
