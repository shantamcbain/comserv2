package Comserv::Model::Schema::Ency::Result::PageTb;
use base 'DBIx::Class::Core';

__PACKAGE__->table('page_tb');
__PACKAGE__->add_columns(
    created_at => {
        data_type => 'datetime',
        is_nullable => 1,
        default_value => 'current_timestamp()',
    },
    description => {
        data_type => 'text',
        is_nullable => 1,
    },
    id => {
        data_type => 'int',
        size => 11,
        is_auto_increment => 1,
    },
    link_order => {
        data_type => 'int',
        size => 11,
        is_nullable => 1,
        default_value => '0',
    },
    menu => {
        data_type => 'varchar',
        size => 50,
    },
    name => {
        data_type => 'varchar',
        size => 100,
    },
    sitename => {
        data_type => 'varchar',
        size => 50,
    },
    status => {
        data_type => 'int',
        size => 11,
        is_nullable => 1,
        default_value => '1',
    },
    target => {
        data_type => 'varchar',
        size => 20,
        is_nullable => 1,
        default_value => '_self',
    },
    updated_at => {
        data_type => 'datetime',
        is_nullable => 1,
        default_value => 'current_timestamp()',
    },
    url => {
        data_type => 'varchar',
        size => 255,
    },
);
__PACKAGE__->set_primary_key('id');

1;
