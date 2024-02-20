package Comserv::Model::Schema::Ency::Result::WorkShop;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components("TimeStamp");
__PACKAGE__->table('workshop');
# Add your columns and relationships here

__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    site_id => {
        data_type => 'integer',
    },
    title => {
        data_type => 'varchar',
        size => 255,
    },
    description => {
        data_type => 'text',
    },
    date => {
        data_type => 'datetime',
    },
    location => {
        data_type => 'varchar',
        size => 255,
    },
    instructor => {
        data_type => 'varchar',
        size => 255,
    },
    max_participants => {
        data_type => 'integer',
    },
);

__PACKAGE__->belongs_to(
    site => 'Comserv::Model::Schema::Ency::Result::Site',
    { 'foreign.id' => 'self.site_id' },
);

1;