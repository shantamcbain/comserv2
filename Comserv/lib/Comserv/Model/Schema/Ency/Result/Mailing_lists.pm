package Comserv::Model::Schema::Ency::Result::Mailing_lists;
use base 'DBIx::Class::Core';

__PACKAGE__->table('mailing_lists');
__PACKAGE__->add_columns(
    created_at => {
        data_type => 'timestamp',
        default_value => 'current_timestamp()',
    },
    created_by => {
        data_type => 'int',
        size => 11,
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
    is_active => {
        data_type => 'tinyint',
        size => 4,
        default_value => '1',
    },
    is_software_only => {
        data_type => 'tinyint',
        size => 4,
        default_value => '1',
    },
    list_email => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 1,
    },
    name => {
        data_type => 'varchar',
        size => 255,
    },
    site_id => {
        data_type => 'int',
        size => 11,
    },
    updated_at => {
        data_type => 'timestamp',
        default_value => 'current_timestamp()',
    },
    virtualmin_list_id => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 1,
    },
);
__PACKAGE__->set_primary_key('id');

1;
