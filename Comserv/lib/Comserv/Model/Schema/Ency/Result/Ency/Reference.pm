package Comserv::Model::Schema::Ency::Result::Ency::Reference;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->table('reference');
__PACKAGE__->add_columns(reference_id => {
        data_type         => 'int',
        size              => 11,
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    reference_system => {
        data_type   => 'char',
        size        => 255,
        is_nullable => 1,
    },
    title => {
        data_type   => 'varchar',
        size        => 500,
        is_nullable => 1,
    },
    publisher_id => {
        data_type   => 'int',
        size        => 11,
        is_nullable => 1,
    },
    publication_date => {
        data_type   => 'varchar',
        size        => 30,
        is_nullable => 1,
    },
    isbn => {
        data_type   => 'varchar',
        size        => 30,
        is_nullable => 1,
    },
    url => {
        data_type   => 'text',
        is_nullable => 1,
    },
    notes => {
        data_type   => 'text',
        is_nullable => 1,
    },
    sitename => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
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
    author => {
        data_type   => 'varchar',
        size        => 500,
        is_nullable => 1,
    },
    publisher => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    edition => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 1,
    },
    format => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 1,
    },
    physical_location => {
        data_type   => 'varchar',
        size        => 500,
        is_nullable => 1,
    },
    digital_path => {
        data_type   => 'varchar',
        size        => 500,
        is_nullable => 1,
    },
    share => {
        data_type     => 'tinyint',
        size          => 1,
        is_nullable   => 0,
        default_value => 1,
    },
);
__PACKAGE__->set_primary_key('reference_id');

__PACKAGE__->belongs_to(
    publisher_record => 'Comserv::Model::Schema::Ency::Result::Ency::Publisher',
    'publisher_id',
);

__PACKAGE__->has_many(
    reference_authors => 'Comserv::Model::Schema::Ency::Result::Ency::ReferenceAuthor',
    'reference_id',
);

1;
