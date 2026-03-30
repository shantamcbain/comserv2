package Comserv::Model::Schema::Forager::Result::ApisYardsTb;
use base 'DBIx::Class::Core';

__PACKAGE__->table('apis_yards_tb');
__PACKAGE__->add_columns(
    accumulated_time => {
        data_type => 'float',
        default_value => '0',
    },
    client_name => {
        data_type => 'varchar(50)',
    },
    comments => {
        data_type => 'text',
        is_nullable => 1,
    },
    current => {
        data_type => 'tinyint(4)',
        default_value => '0',
    },
    date_time_posted => {
        data_type => 'varchar(30)',
    },
    developer_name => {
        data_type => 'varchar(50)',
    },
    due_date => {
        data_type => 'date',
        default_value => '0000-00-00',
    },
    group_of_poster => {
        data_type => 'varchar(30)',
    },
    record_id => {
        data_type => 'int(11)',
        is_auto_increment => 1,
    },
    sitename => {
        data_type => 'varchar(20)',
    },
    status => {
        data_type => 'varchar(30)',
    },
    total_yard_size => {
        data_type => 'tinyint(4)',
        default_value => '0',
    },
    username_of_poster => {
        data_type => 'varchar(30)',
    },
    yard_code => {
        data_type => 'varchar(50)',
    },
    yard_name => {
        data_type => 'varchar(100)',
    },
    yard_size => {
        data_type => 'varchar(25)',
    }
);

__PACKAGE__->set_primary_key('record_id', 'yard_code');

# Add relationships here
# Example:
# __PACKAGE__->belongs_to(
#     'related_table',
#     'Comserv::Model::Schema::Forager::Result::RelatedTable',
#     'foreign_key_column'
# );

1;
