package Comserv::Model::Schema::Forager::Result::ApisInventoryTb;
use base 'DBIx::Class::Core';

__PACKAGE__->table('apis_inventory_tb');
__PACKAGE__->add_columns(
    Discription => {
        data_type => 'text',
    },
    client_name => {
        data_type => 'varchar(20)',
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
    details => {
        data_type => 'text',
        is_nullable => 1,
    },
    end_time => {
        data_type => 'varchar(10)',
        default_value => '0.00',
    },
    group_of_poster => {
        data_type => 'varchar(30)',
    },
    honey_box_foundation => {
        data_type => 'tinyint(4)',
        default_value => '0',
    },
    honey_box_removed => {
        data_type => 'tinyint(4)',
        default_value => '0',
    },
    honey_removed => {
        data_type => 'varchar(50)',
        default_value => '0',
    },
    item_code => {
        data_type => 'varchar(30)',
    },
    item_name => {
        data_type => 'varchar(80)',
    },
    last_mod_by => {
        data_type => 'varchar(50)',
    },
    last_mod_date => {
        data_type => 'varchar(50)',
    },
    location => {
        data_type => 'varchar(20)',
    },
    number => {
        data_type => 'tinyint(4)',
        default_value => '0',
    },
    owner => {
        data_type => 'varchar(30)',
    },
    price => {
        data_type => 'decimal(5,2)',
        default_value => '0.00',
    },
    project_code => {
        data_type => 'varchar(20)',
    },
    queen_code => {
        data_type => 'varchar(30)',
    },
    record_id => {
        data_type => 'int(11)',
        is_auto_increment => 1,
    },
    sitename => {
        data_type => 'varchar(20)',
    },
    start_date => {
        data_type => 'varchar(30)',
    },
    start_day => {
        data_type => 'date',
        default_value => '0000-00-00',
    },
    start_time => {
        data_type => 'decimal(4,2)',
        default_value => '0.00',
    },
    status => {
        data_type => 'varchar(25)',
    },
    username_of_poster => {
        data_type => 'varchar(30)',
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
