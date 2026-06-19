package Comserv::Model::Schema::Ency::Result::NavSubmenuTb;
use base 'DBIx::Class::Core';

__PACKAGE__->table('nav_submenu_tb');
__PACKAGE__->add_columns(
    category => {
        data_type => 'varchar',
        size => 50,
    },
    created_at => {
        data_type => 'datetime',
        is_nullable => 1,
        default_value => 'current_timestamp()',
    },
    header_url => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 1,
        default_value => '',
    },
    icon => {
        data_type => 'varchar',
        size => 64,
        is_nullable => 1,
        default_value => '',
    },
    id => {
        data_type => 'int',
        size => 11,
        is_auto_increment => 1,
    },
    is_system => {
        data_type => 'tinyint',
        size => 1,
        default_value => '0',
    },
    label => {
        data_type => 'varchar',
        size => 120,
    },
    section_order => {
        data_type => 'int',
        size => 11,
        default_value => '0',
    },
    sitename => {
        data_type => 'varchar',
        size => 50,
        default_value => 'All',
    },
    status => {
        data_type => 'tinyint',
        size => 1,
        default_value => '1',
    },
    submenu_id => {
        data_type => 'varchar',
        size => 64,
    },
    template_slot => {
        data_type => 'varchar',
        size => 64,
        is_nullable => 1,
        default_value => '',
    },
    updated_at => {
        data_type => 'datetime',
        is_nullable => 1,
        default_value => 'current_timestamp()',
    },
);
__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint('uq_nav_submenu_scope' => ['category', 'sitename', 'submenu_id']);

1;
