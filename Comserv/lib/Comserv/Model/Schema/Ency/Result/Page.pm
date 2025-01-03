package Comserv::Model::Schema::Ency::Result::Page;

use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp', 'EncodedColumn');
__PACKAGE__->table('pages');

__PACKAGE__->add_columns(
    'id' => {
        data_type         => 'integer',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    'title' => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 0,
    },
    'content_id' => {
        data_type => 'integer',
        is_nullable => 1,
        is_foreign_key => 1,
    },
    'page_code' => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
    },
    'status' => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
    },
    'share' => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,  # Could be enum('public', 'private', 'user')
    },
    'link_order' => {
        data_type   => 'integer',
        is_nullable => 0,
    },
    'news' => {
        data_type   => 'integer',
        is_nullable => 0,
    },
    'last_modified_by' => {
        data_type => 'integer',
        is_nullable => 1,
        is_foreign_key => 1,
    },
    'last_modified_at' => {
        data_type => 'datetime',
        set_on_update => 1,
    },
    'social_media' => {
        data_type => 'text',
        is_nullable => 1,
        serializer_class => 'JSON',
    },
    'created_at' => {
        data_type => 'datetime',
        set_on_create => 1,
        set_on_update => 1,
    },
);

__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint(['page_code']);

__PACKAGE__->belongs_to(
    'content',
    'Comserv::Model::Schema::Ency::Result::Content',
    'content_id'
);

__PACKAGE__->belongs_to(
    'last_modifier' => 'Comserv::Model::Schema::Ency::Result::User::User',
    'last_modified_by'
);

__PACKAGE__->has_many(
    'page_navigations',
    'Comserv::Model::Schema::Ency::Result::Navigation',
    'page_id'
);

1;
