package Comserv::Model::Schema::Ency::Result::Currency_rates;
use base 'DBIx::Class::Core';

__PACKAGE__->table('currency_rates');
__PACKAGE__->add_columns(
    created_at => {
        data_type => 'timestamp',
        default_value => 'current_timestamp()',
    },
    currency_code => {
        data_type => 'char',
        size => 3,
    },
    currency_name => {
        data_type => 'varchar',
        size => 100,
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
    rate_to_cad => {
        data_type => 'decimal',
        size => 15,6,
    },
    source => {
        data_type => 'varchar',
        size => 100,
        is_nullable => 1,
    },
    symbol => {
        data_type => 'varchar',
        size => 10,
        default_value => '',
    },
    updated_at => {
        data_type => 'timestamp',
        default_value => 'current_timestamp()',
    },
);
__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint('uq_currency_code' => ['currency_code']);

1;
