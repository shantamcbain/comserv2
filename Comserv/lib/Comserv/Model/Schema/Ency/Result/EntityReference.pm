package Comserv::Model::Schema::Ency::Result::EntityReference;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('ency_entity_reference');
__PACKAGE__->add_columns(
    id => {
        data_type         => 'int',
        size              => 11,
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    entity_type => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 0,
    },
    entity_id => {
        data_type   => 'int',
        size        => 11,
        is_nullable => 0,
    },
    reference_id => {
        data_type   => 'int',
        size        => 11,
        is_nullable => 0,
    },
);
__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint(['entity_type', 'entity_id', 'reference_id']);

__PACKAGE__->belongs_to(
    reference => 'Comserv::Model::Schema::Ency::Result::Reference',
    'reference_id',
);

1;
