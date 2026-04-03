package Comserv::Model::Schema::Ency::Result::Pages_content;
use base 'DBIx::Class::Core';

__PACKAGE__->table('pages_content');
__PACKAGE__->add_columns(
    body => {
        data_type => 'text',
    },
    created_at => {
        data_type => 'datetime',
        default_value => 'current_timestamp()',
    },
    created_by => {
        data_type => 'varchar',
        size => 255,
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
    keywords => {
        data_type => 'text',
        is_nullable => 1,
    },
    link_order => {
        data_type => 'int',
        size => 11,
        default_value => '0',
    },
    menu => {
        data_type => 'varchar',
        size => 255,
    },
    page_code => {
        data_type => 'varchar',
        size => 255,
    },
    roles => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 1,
        default_value => 'public',
    },
    sitename => {
        data_type => 'varchar',
        size => 255,
    },
    status => {
        data_type => 'varchar',
        size => 50,
        default_value => 'active',
    },
    title => {
        data_type => 'varchar',
        size => 255,
    },
    updated_at => {
        data_type => 'datetime',
        default_value => 'current_timestamp()',
    },
);
__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint('unique_page_code' => ['page_code']);

1;
