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
    sitename => {
        data_type => 'varchar',
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
    end_time => {
        data_type => 'time',
    },
    time => {
        data_type => 'time',
    },
    location => {
        data_type => 'varchar',
        size => 255,
    },
    instructor => {
        data_type => 'varchar',
        size => 255,
    },
    share => {
    data_type => 'enum',
    default_value => 'private',
    extra => {
        list => ['public', 'private']
    },
},
    max_participants => {
        data_type => 'integer',
    },
);
__PACKAGE__->set_primary_key('id');
__PACKAGE__->belongs_to(
    site => 'Comserv::Model::Schema::Ency::Result::Site',
    { 'foreign.id' => 'self.site_id' },
);
__PACKAGE__->has_many(
    'file' => 'Comserv::Model::Schema::Ency::Result::File',
    'workshop_id'
);
1;