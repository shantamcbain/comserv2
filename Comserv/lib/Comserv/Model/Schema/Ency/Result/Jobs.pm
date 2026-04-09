package Comserv::Model::Schema::Ency::Result::Jobs;
use base 'DBIx::Class::Core';

__PACKAGE__->table('jobs');
__PACKAGE__->add_columns(
    accept_points_payment => {
        data_type => 'tinyint',
        size => 1,
        default_value => '0',
    },
    cash_rate => {
        data_type => 'decimal',
        size => 14,4,
        is_nullable => 1,
    },
    created_at => {
        data_type => 'timestamp',
        default_value => 'current_timestamp()',
    },
    currency => {
        data_type => 'varchar',
        size => 10,
        default_value => 'CAD',
    },
    description => {
        data_type => 'text',
    },
    expires_at => {
        data_type => 'date',
        is_nullable => 1,
    },
    id => {
        data_type => 'int',
        size => 11,
        is_auto_increment => 1,
    },
    location => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 1,
    },
    payment_type => {
        data_type => 'varchar',
        size => 50,
        default_value => 'cash',
    },
    point_rate => {
        data_type => 'decimal',
        size => 14,4,
        is_nullable => 1,
    },
    posted_by_user_id => {
        data_type => 'int',
        size => 11,
        is_nullable => 1,
    },
    poster_email => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 1,
    },
    poster_name => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 1,
    },
    remote => {
        data_type => 'tinyint',
        size => 1,
        default_value => '0',
    },
    requirements => {
        data_type => 'text',
        is_nullable => 1,
    },
    sitename => {
        data_type => 'varchar',
        size => 255,
        default_value => 'CSC',
    },
    status => {
        data_type => 'varchar',
        size => 50,
        default_value => 'open',
    },
    title => {
        data_type => 'varchar',
        size => 255,
    },
    updated_at => {
        data_type => 'timestamp',
        default_value => 'current_timestamp()',
    },
);
__PACKAGE__->set_primary_key('id');

1;
