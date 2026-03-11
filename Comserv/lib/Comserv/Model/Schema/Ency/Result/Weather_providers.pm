package Comserv::Model::Schema::Ency::Result::Weather_providers;
use base 'DBIx::Class::Core';

__PACKAGE__->table('weather_providers');
__PACKAGE__->add_columns(
    api_base_url => {
        data_type => 'varchar',
        size => 255,
    },
    created_at => {
        data_type => 'timestamp',
        default_value => 'current_timestamp()',
    },
    documentation_url => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 1,
    },
    id => {
        data_type => 'int',
        size => 11,
        is_auto_increment => 1,
    },
    is_active => {
        data_type => 'enum',
        extra => { list => ['0','1'] },
        default_value => '1',
    },
    provider_name => {
        data_type => 'varchar',
        size => 50,
    },
    rate_limit_per_day => {
        data_type => 'int',
        size => 11,
        default_value => '1000',
    },
    rate_limit_per_minute => {
        data_type => 'int',
        size => 11,
        default_value => '60',
    },
    requires_api_key => {
        data_type => 'enum',
        extra => { list => ['0','1'] },
        default_value => '1',
    },
    supports_current => {
        data_type => 'enum',
        extra => { list => ['0','1'] },
        default_value => '1',
    },
    supports_forecast => {
        data_type => 'enum',
        extra => { list => ['0','1'] },
        default_value => '1',
    },
    supports_historical => {
        data_type => 'enum',
        extra => { list => ['0','1'] },
        default_value => '0',
    },
);
__PACKAGE__->set_primary_key('id');

1;
