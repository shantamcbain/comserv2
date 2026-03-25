package Comserv::Model::Schema::Ency::Result::Aimodelconfig;
use base 'DBIx::Class::Core';

__PACKAGE__->table('aimodelconfig');
__PACKAGE__->add_columns(
    id => {
        data_type => 'int',
        size => 11,
        is_auto_increment => 1,
    },
);
__PACKAGE__->set_primary_key('id');

1;
