package Comserv::Model::Schema::Ency::Result::MarketplaceCategory;
use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('marketplace_categories');

__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    sitename => {
        data_type     => 'varchar',
        size          => 255,
        is_nullable   => 0,
        default_value => 'CSC',
    },
    name => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
    },
    slug => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
    },
    sort_order => {
        data_type     => 'integer',
        is_nullable   => 0,
        default_value => 0,
    },
    active => {
        data_type     => 'tinyint',
        is_nullable   => 0,
        default_value => 1,
    },
    created_at => {
        data_type     => 'timestamp',
        is_nullable   => 0,
        set_on_create => 1,
    },
);

__PACKAGE__->set_primary_key('id');
__PACKAGE__->has_many(
    listings => 'Comserv::Model::Schema::Ency::Result::MarketplaceListing',
    { 'foreign.category_id' => 'self.id' }
);

1;
