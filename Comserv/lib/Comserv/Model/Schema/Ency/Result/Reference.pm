package Comserv::Model::Schema::Ency::Result::Reference;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
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
    }publisher_id => {
        data_type => 'int(11)',
        size => 11,
        is_nullable => 1,
    },
    publication_date => {
        data_type   => 'date',
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
        data_type => 'varchar(500)',
        size => 500,
        is_nullable => 1,
    },
    publisher => {
        data_type => 'varchar(255)',
        size => 255,
        is_nullable => 1,
    }
);
__PACKAGE__->set_primary_key('reference_id');

__PACKAGE__->belongs_to(
    publisher => 'Comserv::Model::Schema::Ency::Result::Publisher',
    'publisher_id',
);

__PACKAGE__->has_many(
    reference_authors => 'Comserv::Model::Schema::Ency::Result::ReferenceAuthor',
    'reference_id',
);

1;
