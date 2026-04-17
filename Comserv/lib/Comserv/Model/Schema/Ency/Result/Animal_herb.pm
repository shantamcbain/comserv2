package Comserv::Model::Schema::Ency::Result::Animal_herb;
use base 'DBIx::Class::Core';

__PACKAGE__->table('animal_herb');
__PACKAGE__->add_columns(
    animal_id => {
        data_type => 'int',
        size => 11,
    },
    herb_id => {
        data_type => 'int',
        size => 11,
    },
    id => {
        data_type => 'int',
        size => 11,
        is_auto_increment => 1,
    },
    interaction_type => {
        data_type => 'varchar',
        size => 50,
        is_nullable => 1,
    },
    notes => {
        data_type => 'text',
        is_nullable => 1,
    },
);
__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint('animal_herb_animal_id_herb_id_interaction_type' => ['animal_id', 'herb_id', 'interaction_type']);

1;
