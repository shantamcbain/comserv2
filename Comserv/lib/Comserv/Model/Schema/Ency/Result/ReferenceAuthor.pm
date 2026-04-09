package Comserv::Model::Schema::Ency::Result::ReferenceAuthor;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('ency_reference_author');
__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    reference_id => {
        data_type   => 'integer',
        is_nullable => 0,
    },
    author_id => {
        data_type   => 'integer',
        is_nullable => 0,
    },
    author_order => {
        data_type     => 'integer',
        is_nullable   => 0,
        default_value => 1,
    },
);
__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint(['reference_id', 'author_id']);

__PACKAGE__->belongs_to(
    reference => 'Comserv::Model::Schema::Ency::Result::Reference',
    'reference_id',
);

__PACKAGE__->belongs_to(
    author => 'Comserv::Model::Schema::Ency::Result::Author',
    'author_id',
);

1;
