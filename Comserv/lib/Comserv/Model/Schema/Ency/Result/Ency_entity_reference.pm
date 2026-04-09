package Comserv::Model::Schema::Ency::Result::Ency_entity_reference;
use base 'DBIx::Class::Core';

__PACKAGE__->table('ency_entity_reference');
__PACKAGE__->add_columns(
    entity_id => {
        data_type => 'int',
        size => 11,
    },
    entity_type => {
        data_type => 'varchar',
        size => 50,
    },
    id => {
        data_type => 'int',
        size => 11,
        is_auto_increment => 1,
    },
    reference_id => {
        data_type => 'int',
        size => 11,
    },
);
__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint('ency_entity_reference_entity_type_entity_id_reference_id' => ['entity_type', 'entity_id', 'reference_id']);

1;
