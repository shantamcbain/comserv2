package Comserv::Model::Schema::Ency::Result::Page;
use base 'DBIx::Class::Core';
use strict;
use warnings;

__PACKAGE__->load_components(qw/InflateColumn::DateTime TimeStamp/);
__PACKAGE__->table('page');

__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    sitename => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
    },
    menu => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
    },
    page_code => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
    },
    title => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
    },
    body => {
        data_type   => 'text',
        is_nullable => 0,
    },
    description => {
        data_type   => 'text',
        is_nullable => 1,
    },
    keywords => {
        data_type   => 'text',
        is_nullable => 1,
    },
    link_order => {
        data_type     => 'integer',
        is_nullable   => 0,
        default_value => 0,
    },
    status => {
        data_type     => 'varchar',
        size          => 50,
        is_nullable   => 0,
        default_value => 'active',
    },
    roles => {
        data_type     => 'varchar',
        size          => 255,
        is_nullable   => 1,
        default_value => 'public',
    },
    share_with => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    # Known values: standard, newsletter, feature_guide (member how-to for newsletter inclusion)
    page_type => {
        data_type     => 'varchar',
        size          => 50,
        is_nullable   => 0,
        default_value => 'standard',
    },
    created_by => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
    },
    created_at => {
        data_type     => 'datetime',
        is_nullable   => 0,
        set_on_create => 1,
    },
    updated_at => {
        data_type     => 'datetime',
        is_nullable   => 0,
        set_on_create => 1,
        set_on_update => 1,
    },
);

__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint(unique_sitename_page_code => [qw/sitename page_code/]);

__PACKAGE__->resultset_attributes({
    order_by => [qw/sitename menu link_order/],
});

1;