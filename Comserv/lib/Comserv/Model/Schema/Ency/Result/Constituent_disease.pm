package Comserv::Model::Schema::Ency::Result::Constituent_disease;
use base 'DBIx::Class::Core';

__PACKAGE__->table('constituent_disease');
__PACKAGE__->add_columns(
    constituent_id => {
        data_type => 'int',
        size => 11,
    },
    disease_id => {
        data_type => 'int',
        size => 11,
    },
    evidence_level => {
        data_type => 'varchar',
        size => 50,
        is_nullable => 1,
    },
    id => {
        data_type => 'int',
        size => 11,
        is_auto_increment => 1,
    },
    notes => {
        data_type => 'text',
        is_nullable => 1,
    },
    relationship_type => {
        data_type => 'varchar',
        size => 50,
        is_nullable => 1,
    },
);
__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint('constituent_disease_constituent_id_disease_id_relationship_type' => ['constituent_id', 'disease_id', 'relationship_type']);

1;
