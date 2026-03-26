package Comserv::Model::Schema::Ency::Result::Point_packages;
use base 'DBIx::Class::Core';

__PACKAGE__->table('point_packages');
__PACKAGE__->add_columns(
    created_at => {
        data_type => 'timestamp',
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
    is_active => {
        data_type => 'tinyint',
        size => 1,
        default_value => '1',
    },
    name => {
        data_type => 'varchar',
        size => 100,
    },
    package_type => {
        data_type => 'varchar',
        size => 20,
        default_value => 'one_time',
    },
    paypal_plan_id => {
        data_type => 'varchar',
        size => 100,
        is_nullable => 1,
    },
    points => {
        data_type => 'decimal',
        size => 14,4,
    },
    price_cad => {
        data_type => 'decimal',
        size => 10,2,
    },
    sort_order => {
        data_type => 'int',
        size => 11,
        default_value => '0',
    },
    updated_at => {
        data_type => 'timestamp',
        default_value => 'current_timestamp()',
    },
);
__PACKAGE__->set_primary_key('id');

1;
