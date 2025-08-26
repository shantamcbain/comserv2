package Comserv::Model::Schema::Ency::Result::Participant;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components("TimeStamp");
__PACKAGE__->table('participant');

__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    workshop_id => {
        data_type => 'integer',
    },
    name => {
        data_type => 'varchar',
        size => 255,
    },
);

__PACKAGE__->belongs_to(
    workshop => 'Comserv::Model::Schema::Ency::Result::WorkShop',
    { 'foreign.id' => 'self.workshop_id' },
);

1;