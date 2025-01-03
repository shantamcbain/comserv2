package Comserv::Model::Schema::Ency::Result::Content;
use base 'DBIx::Class::Core';

__PACKAGE__->table('content');

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
    'body' => {
        data_type => 'text',
        is_nullable => 0,
    },
    'meta_description' => {
        data_type => 'text',
        is_nullable => 1,
    },
    'meta_keywords' => {
        data_type => 'text',
        is_nullable => 1,
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
    'status' => {
        data_type => 'varchar',
        size => 20,
        default_value => 'draft',
    },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->has_many(
    'pages' => 'Comserv::Model::Schema::Ency::Result::Page',
    'content_id'
);

__PACKAGE__->belongs_to(
    'creator' => 'Comserv::Model::Schema::Ency::Result::User::User',
    'created_by'
);

__PACKAGE__->belongs_to(
    'updater' => 'Comserv::Model::Schema::Ency::Result::User::User',
    'updated_by'
);

1;
