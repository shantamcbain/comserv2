package Comserv::Model::Schema::Forager::Result::PageTb;
use base 'DBIx::Class::Core';

__PACKAGE__->table('page_tb');
__PACKAGE__->add_columns(
    app_title => {
        data_type => 'text',
    },
    body => {
        data_type => 'text',
    },
    comments => {
        data_type => 'text',
    },
    company_code => {
        data_type => 'varchar(30)',
    },
    date_time_posted => {
        data_type => 'varchar(30)',
    },
    description => {
        data_type => 'text',
        is_nullable => 1,
    },
    developer => {
        data_type => 'varchar(50)',
    },
    group_of_poster => {
        data_type => 'varchar(30)',
    },
    keywords => {
        data_type => 'varchar(80)',
    },
    last_mod_by => {
        data_type => 'varchar(50)',
    },
    last_mod_date => {
        data_type => 'varchar(50)',
    },
    lastupdate => {
        data_type => 'varchar(20)',
    },
    link_order => {
        data_type => 'tinyint(4)',
        default_value => '0',
    },
    linkedin => {
        data_type => 'varchar(150)',
    },
    mailchimp => {
        data_type => 'varchar(100)',
    },
    menu => {
        data_type => 'varchar(30)',
    },
    news => {
        data_type => 'varchar(5)',
    },
    newsletter => {
        data_type => 'varchar(100)',
    },
    page_code => {
        data_type => 'varchar(30)',
    },
    page_site => {
        data_type => 'varchar(100)',
    },
    pageheader => {
        data_type => 'varchar(250)',
    },
    record_id => {
        data_type => 'int(11)',
        is_auto_increment => 1,
    },
    share => {
        data_type => 'varchar(10)',
    },
    sitename => {
        data_type => 'varchar(30)',
    },
    status => {
        data_type => 'varchar(25)',
    },
    username_of_poster => {
        data_type => 'varchar(30)',
    },
    view_name => {
        data_type => 'varchar(80)',
    }
);

__PACKAGE__->set_primary_key('record_id');

# Add relationships here
# Example:
# __PACKAGE__->belongs_to(
#     'related_table',
#     'Comserv::Model::Schema::Forager::Result::RelatedTable',
#     'foreign_key_column'
# );

1;
