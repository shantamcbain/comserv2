package Comserv::Model::Schema::Ency::Result::WeatherProviders;
use base 'DBIx::Class::Core';

__PACKAGE__->table('weather_providers');
__PACKAGE__->add_columns(
    id => {
        data_type => 'int',
        is_auto_increment => 1,
    },
    provider_name => {
        data_type => 'varchar',
        size => 50,
        is_nullable => 0,
    },
    api_base_url => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 0,
    },
    requires_api_key => {
        data_type => 'enum',
        extra => { list => ['0', '1'] },
        default_value => '1',
        is_nullable => 0,
    },
    supports_current => {
        data_type => 'enum',
        extra => { list => ['0', '1'] },
        default_value => '1',
        is_nullable => 0,
    },
    supports_forecast => {
        data_type => 'enum',
        extra => { list => ['0', '1'] },
        default_value => '1',
        is_nullable => 0,
    },
    supports_historical => {
        data_type => 'enum',
        extra => { list => ['0', '1'] },
        default_value => '0',
        is_nullable => 0,
    },
    rate_limit_per_minute => {
        data_type => 'int',
        default_value => 60,
    },
    rate_limit_per_day => {
        data_type => 'int',
        default_value => 1000,
    },
    documentation_url => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 1,
    },
    is_active => {
        data_type => 'enum',
        extra => { list => ['0', '1'] },
        default_value => '1',
        is_nullable => 0,
    },
    created_at => {
        data_type => 'timestamp',
        default_value => 'current_timestamp()',
        is_nullable => 0,
    },
);

__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint('provider_name_unique' => ['provider_name']);

1;