package Comserv::Model::Schema::Forager::Result::ApisQueenLogTb;
use base 'DBIx::Class::Core';

__PACKAGE__->table('apis_queen_log_tb');
__PACKAGE__->add_columns(
    abstract => {
        data_type => 'varchar(80)',
    },
    box_1_bees => {
        data_type => 'varchar(50)',
    },
    box_1_brood => {
        data_type => 'varchar(50)',
    },
    box_1_broodadded => {
        data_type => 'int(11)',
    },
    box_1_comb => {
        data_type => 'int(11)',
    },
    box_1_empty => {
        data_type => 'int(11)',
    },
    box_1_foundation => {
        data_type => 'tinyint(4)',
        default_value => '0',
    },
    box_1_honey => {
        data_type => 'int(11)',
    },
    box_2_bees => {
        data_type => 'tinyint(4)',
        default_value => '0',
    },
    box_2_brood => {
        data_type => 'tinyint(4)',
        default_value => '0',
    },
    box_2_brood_x => {
        data_type => 'int(11)',
    },
    box_2_broodadded => {
        data_type => 'int(11)',
    },
    box_2_comb => {
        data_type => 'int(11)',
    },
    box_2_empty => {
        data_type => 'int(11)',
    },
    box_2_foundation => {
        data_type => 'tinyint(4)',
        default_value => '0',
    },
    box_2_honey => {
        data_type => 'int(11)',
    },
    box_x_bees => {
        data_type => 'int(11)',
    },
    box_x_brood => {
        data_type => 'int(11)',
    },
    box_x_broodadded => {
        data_type => 'int(11)',
    },
    box_x_comb => {
        data_type => 'int(11)',
    },
    box_x_empty => {
        data_type => 'int(11)',
    },
    box_x_foundation => {
        data_type => 'int(11)',
    },
    box_x_honey => {
        data_type => 'int(11)',
    },
    brood_given => {
        data_type => 'varchar(30)',
    },
    brood_given_x => {
        data_type => 'int(11)',
    },
    comments => {
        data_type => 'text',
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
    honey_added => {
        data_type => 'int(11)',
    },
    honey_box => {
        data_type => 'tinyint(4)',
        default_value => '0',
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
    last_mod_by => {
        data_type => 'varchar(50)',
    },
    last_mod_date => {
        data_type => 'varchar(50)',
    },
    owner => {
        data_type => 'varchar(30)',
    },
    pallet_code => {
        data_type => 'varchar(20)',
    },
    queen_code => {
        data_type => 'varchar(30)',
    },
    queen_record_id => {
        data_type => 'int(11)',
        default_value => '0',
    },
    record_id => {
        data_type => 'int(11)',
        is_auto_increment => 1,
    },
    sitename => {
        data_type => 'varchar(30)',
    },
    start_date => {
        data_type => 'varchar(30)',
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
