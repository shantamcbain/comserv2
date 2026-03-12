package Comserv::Model::Schema::Ency::Result::Weather_config;
use base 'DBIx::Class::Core';

__PACKAGE__->table('weather_config');
__PACKAGE__->add_columns(
    api_key => {
        data_type => 'varchar',
        size => 255,
    },
    api_service => {
        data_type => 'varchar',
        size => 50,
        default_value => 'openweathermap',
    },
    country_code => {
        data_type => 'varchar',
        size => 2,
        default_value => 'US',
    },
    created_at => {
        data_type => 'timestamp',
        default_value => 'current_timestamp()',
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
    language => {
        data_type => 'varchar',
        size => 10,
        default_value => 'en',
    },
    location_method => {
        data_type => 'enum',
        extra => { list => ['zip','coordinates','city'] },
        default_value => 'zip',
    },
    location_value => {
        data_type => 'varchar',
        size => 100,
    },
    site_id => {
        data_type => 'int',
        size => 11,
    },
    temperature_units => {
        data_type => 'enum',
        extra => { list => ['metric','imperial','kelvin'] },
        default_value => 'metric',
    },
    update_interval => {
        data_type => 'int',
        size => 11,
        default_value => '30',
    },
    updated_at => {
        data_type => 'timestamp',
        default_value => 'current_timestamp()',
    },
    user_id => {
        data_type => 'int',
        size => 11,
    },
);
__PACKAGE__->set_primary_key('id');

1;
