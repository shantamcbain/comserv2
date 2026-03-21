package Comserv::Model::Schema::Ency::Result::Reference;
use base 'DBIx::Class::Core';

__PACKAGE__->table('reference');
__PACKAGE__->add_columns(
    reference_id => {
        data_type => 'int',
        size => 11,
        is_auto_increment => 1,
    },
    reference_system => {
        data_type => 'char',
        size => 255,
        is_nullable => 1,
    },
);
__PACKAGE__->set_primary_key('reference_id');
__PACKAGE__->add_unique_constraint('reference_id' => ['reference_id']);

1;
