package Comserv::Model::Schema::Ency::Result::WeatherConfig;
use base 'DBIx::Class::Core';

__PACKAGE__->table('weather_config');
__PACKAGE__->add_columns(
    id => { data_type => 'INT', size => 11, is_nullable => 0 },
    user_id => {
        data_type => 'int',
        is_nullable => 0,
    },
    site_id => {
        data_type => 'int',
        is_nullable => 0,
    },
    api_service => {
        data_type => 'varchar',
        size => 50,
        is_nullable => 0,
        default_value => 'openweathermap',
    },
    api_key => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 0,
    },
    location_method => {
        data_type => 'enum',
        extra => { list => ['zip', 'coordinates', 'city'] },
        default_value => 'zip',
        is_nullable => 0,
    },
    location_value => {
        data_type => 'varchar',
        size => 100,
        is_nullable => 0,
    },
    country_code => {
        data_type => 'varchar',
        size => 2,
        default_value => 'US',
        is_nullable => 0,
    },
    update_interval => {
        data_type => 'int',
        size => 11,
        is_nullable => 0,
        default_value => 30,
    },
    temperature_units => {
        data_type => 'enum',
        extra => { list => ['metric', 'imperial', 'kelvin'] },
        default_value => 'metric',
        is_nullable => 0,
    },
    language => {
        data_type => 'varchar',
        size => 10,
        default_value => 'en',
        is_nullable => 0,
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
    updated_at => {
        data_type => 'timestamp',
        default_value => 'current_timestamp()',
        is_nullable => 0,
    },
);

__PACKAGE__->set_primary_key('id');

# Relationships
__PACKAGE__->belongs_to(
    'user',
    'Comserv::Model::Schema::Ency::Result::User',
    'user_id'
);

__PACKAGE__->belongs_to(
    'site',
    'Comserv::Model::Schema::Ency::Result::Site',
    'site_id'
);

__PACKAGE__->has_many(
    'weather_data',
    'Comserv::Model::Schema::Ency::Result::WeatherData',
    'config_id'
);

1;