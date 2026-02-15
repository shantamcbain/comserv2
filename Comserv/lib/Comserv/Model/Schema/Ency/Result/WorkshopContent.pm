package Comserv::Model::Schema::Ency::Result::WorkshopContent;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components("TimeStamp");
__PACKAGE__->table('workshop_content');

__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    workshop_id => {
        data_type => 'integer',
    },
    content_type => {
        data_type => 'enum',
        default_value => 'text',
        extra => {
            list => ['text', 'powerpoint', 'embedded']
        },
    },
    title => {
        data_type => 'varchar',
        size => 255,
    },
    content => {
        data_type => 'text',
        is_nullable => 1,
    },
    file_id => {
        data_type => 'integer',
        is_nullable => 1,
    },
    sort_order => {
        data_type => 'integer',
        default_value => 0,
    },
    created_at => {
        data_type => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP',
    },
    updated_at => {
        data_type => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP',
    },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->belongs_to(
    workshop => 'Comserv::Model::Schema::Ency::Result::WorkShop',
    { 'foreign.id' => 'self.workshop_id' },
);

__PACKAGE__->belongs_to(
    file => 'Comserv::Model::Schema::Ency::Result::File',
    { 'foreign.id' => 'self.file_id' },
    { join_type => 'left' },
);

1;
