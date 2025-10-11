package Comserv::Model::Schema::Ency::Result::Documentation;
use base 'DBIx::Class::Core';

__PACKAGE__->table('documentation');

__PACKAGE__->add_columns(
    'id' => {
        data_type => 'integer',
        is_auto_increment => 1,
        is_nullable => 0,
    },
    'title' => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 0,
    },
    'content' => {
        data_type => 'text',
        is_nullable => 0,
    },
    'section' => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 0,
    },
    'version' => {
        data_type => 'varchar',
        size => 50,
        is_nullable => 0,
    },
    'created_at' => {
        data_type => 'datetime',
        set_on_create => 1,
    },
    'updated_at' => {
        data_type => 'datetime',
        set_on_create => 1,
        set_on_update => 1,
    },
    'created_by' => {
        data_type => 'integer',
        is_nullable => 0,
    },
    'updated_by' => {
        data_type => 'integer',
        is_nullable => 0,
    },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->belongs_to(
    'creator' => 'Comserv::Model::Schema::Ency::Result::User::User',
    'created_by'
);

__PACKAGE__->belongs_to(
    'updater' => 'Comserv::Model::Schema::Ency::Result::User::User',
    'updated_by'
);

1;
