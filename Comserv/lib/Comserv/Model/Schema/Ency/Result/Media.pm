package Comserv::Model::Schema::Ency::Result::Media;

use base 'DBIx::Class::Core';

__PACKAGE__->table('media');

__PACKAGE__->add_columns(
    'id' => {
        data_type         => 'integer',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    'filename' => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
    },
    'type' => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 0,
    },
    'content_id' => {
        data_type   => 'integer',
        is_nullable => 1,  # Nullable since not all media might be associated with content
    },
    # Add any other columns here
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->belongs_to(
    'content',
    'Comserv::Model::Schema::Ency::Result::Content',
    { 'foreign.id' => 'self.content_id' },
    { join_type => 'LEFT' }
);

1;