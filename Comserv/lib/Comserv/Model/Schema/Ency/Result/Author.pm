package Comserv::Model::Schema::Ency::Result::Author;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('ency_author_tb');
__PACKAGE__->add_columns(
    author_id => {
        data_type         => 'integer',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    full_name => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
    },
    affiliation => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    url => {
        data_type   => 'text',
        is_nullable => 1,
    },
);
__PACKAGE__->set_primary_key('author_id');

__PACKAGE__->has_many(
    reference_authors => 'Comserv::Model::Schema::Ency::Result::ReferenceAuthor',
    'author_id',
);

1;
