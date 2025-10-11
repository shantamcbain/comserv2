package Comserv::Model::Schema::Ency::Result::Pallet;
use base 'DBIx::Class::Core';

__PACKAGE__->table('pallets');
__PACKAGE__->add_columns(
    id => {
        data_type => 'int',
        is_auto_increment => 1,
    },
    yard_id => {
        data_type => 'int',
        is_foreign_key => 1,
    },
    size => {
        data_type => 'int',
    },
    date_added => {
        data_type => 'datetime',
    },
);
__PACKAGE__->set_primary_key('id');
__PACKAGE__->belongs_to(
    yard => 'Comserv::Model::Schema::Ency::Result::Yard',
    'yard_id',
);

1;