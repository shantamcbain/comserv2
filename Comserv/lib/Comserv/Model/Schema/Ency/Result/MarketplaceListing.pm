package Comserv::Model::Schema::Ency::Result::MarketplaceListing;
use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('marketplace_listings');

__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    seller_username => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
    },
    sitename => {
        data_type     => 'varchar',
        size          => 255,
        is_nullable   => 0,
        default_value => 'CSC',
    },
    title => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
    },
    description => {
        data_type   => 'text',
        is_nullable => 0,
    },
    price => {
        data_type     => 'decimal',
        size          => [10, 2],
        is_nullable   => 0,
        default_value => '0.00',
    },
    currency => {
        data_type     => 'varchar',
        size          => 10,
        is_nullable   => 0,
        default_value => 'CAD',
    },
    accepts_points => {
        data_type     => 'tinyint',
        is_nullable   => 0,
        default_value => 0,
    },
    order_url => {
        data_type   => 'text',
        is_nullable => 1,
    },
    status => {
        data_type     => 'enum',
        extra         => { list => [qw(active sold expired draft)] },
        is_nullable   => 0,
        default_value => 'active',
    },
    category_id => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    image_paths => {
        data_type   => 'text',
        is_nullable => 1,
    },
    views => {
        data_type     => 'integer',
        is_nullable   => 0,
        default_value => 0,
    },
    created_at => {
        data_type     => 'timestamp',
        is_nullable   => 0,
        set_on_create => 1,
    },
    updated_at => {
        data_type     => 'timestamp',
        is_nullable   => 0,
        set_on_create => 1,
        set_on_update => 1,
    },
    expires_at => {
        data_type   => 'date',
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key('id');
__PACKAGE__->belongs_to(
    category => 'Comserv::Model::Schema::Ency::Result::MarketplaceCategory',
    { 'foreign.id' => 'self.category_id' },
    { join_type => 'LEFT', on_delete => 'SET NULL', on_update => 'CASCADE' }
);

1;
