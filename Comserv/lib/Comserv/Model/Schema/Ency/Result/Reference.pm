# In Comserv/lib/Comserv/Model/Schema/Ency/Result/Reference.pm
package Comserv::Model::Schema::Ency::Result::Reference;
use base 'DBIx::Class::Core';

__PACKAGE__->table('references');
__PACKAGE__->add_columns(
    reference_id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    reference_system => {
        data_type => 'varchar',
        size => 255,
    },
);
__PACKAGE__->set_primary_key('reference_id');

1;