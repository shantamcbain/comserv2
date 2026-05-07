package Comserv::Model::Schema::Ency::Result::Ency::Author;

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
    credentials => {
        data_type   => 'varchar',
        size        => 500,
        is_nullable => 1,
    },
    affiliation => {
        data_type   => 'varchar',
        size        => 500,
        is_nullable => 1,
    },
    specialty => {
        data_type   => 'varchar',
        size        => 500,
        is_nullable => 1,
    },
    born_year => {
        data_type   => 'smallint',
        is_nullable => 1,
    },
    died_year => {
        data_type   => 'smallint',
        is_nullable => 1,
    },
    nationality => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
    },
    bio => {
        data_type   => 'text',
        is_nullable => 1,
    },
    notes => {
        data_type   => 'text',
        is_nullable => 1,
    },
    url => {
        data_type   => 'text',
        is_nullable => 1,
    },
    sitename => {
        data_type     => 'varchar',
        size          => 100,
        is_nullable   => 1,
        default_value => 'ENCY',
    },
    username_of_poster => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 1,
    },
    date_time_posted => {
        data_type   => 'varchar',
        size        => 30,
        is_nullable => 1,
    },
);
__PACKAGE__->set_primary_key('author_id');

__PACKAGE__->has_many(
    reference_authors => 'Comserv::Model::Schema::Ency::Result::Ency::ReferenceAuthor',
    'author_id',
);

__PACKAGE__->many_to_many(
    references => 'reference_authors', 'reference',
);

1;
