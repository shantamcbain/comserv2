package Comserv::Model::Schema::Ency::Result::Publisher;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('ency_publisher_tb');
__PACKAGE__->add_columns(
    publisher_id => {
        data_type         => 'integer',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    name => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
    },
    location => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    url => {
        data_type   => 'text',
        is_nullable => 1,
    },
);
__PACKAGE__->set_primary_key('publisher_id');

__PACKAGE__->has_many(
    reference_records => 'Comserv::Model::Schema::Ency::Result::Reference',
    'publisher_id',
);

1;
