package Comserv::Model::Schema::Forager::Result::ApisPalletTb;
use base 'DBIx::Class::Core';

__PACKAGE__->table('apis_pallet_tb');
__PACKAGE__->add_columns(
    client_name => {
        data_type => 'varchar(50)',
    },
    comments => {
        data_type => 'text',
        is_nullable => 1,
    },
    current => {
        data_type => 'tinyint(4)',
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
    hivetype => {
        data_type => 'varchar(20)',
    },
    pallet_code => {
        data_type => 'varchar(20)',
    },
    pallet_name => {
        data_type => 'varchar(100)',
    },
    pallet_size => {
        data_type => 'varchar(25)',
    },
    queen_code => {
        data_type => 'varchar(20)',
    },
    record_id => {
        data_type => 'int(11)',
        is_auto_increment => 1,
    },
    sitename => {
        data_type => 'varchar(20)',
        is_nullable => 1,
    },
    status => {
        data_type => 'varchar(30)',
    },
    username_of_poster => {
        data_type => 'varchar(30)',
    },
    yard_code => {
        data_type => 'varchar(50)',
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
