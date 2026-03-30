package Comserv::Model::Schema::Ency::Result::Weather_data;
use base 'DBIx::Class::Core';

__PACKAGE__->table('weather_data');
__PACKAGE__->add_columns(
    cloudiness => {
        data_type => 'int',
        size => 11,
        is_nullable => 1,
    },
    condition_description => {
        data_type => 'varchar',
        size => 100,
        is_nullable => 1,
    },
    condition_main => {
        data_type => 'varchar',
        size => 50,
        is_nullable => 1,
    },
    config_id => {
        data_type => 'int',
        size => 11,
    },
    data_type => {
        data_type => 'enum',
        extra => { list => ['current','forecast'] },
    },
    feels_like => {
        data_type => 'decimal',
        size => 5,2,
        is_nullable => 1,
    },
    forecast_date => {
        data_type => 'date',
        is_nullable => 1,
    },
    forecast_time => {
        data_type => 'time',
        is_nullable => 1,
    },
    humidity => {
        data_type => 'int',
        size => 11,
        is_nullable => 1,
    },
    id => {
        data_type => 'int',
        size => 11,
        is_auto_increment => 1,
    },
    location_name => {
        data_type => 'varchar',
        size => 100,
        is_nullable => 1,
    },
    precipitation => {
        data_type => 'decimal',
        size => 5,2,
        is_nullable => 1,
    },
    pressure => {
        data_type => 'decimal',
        size => 7,2,
        is_nullable => 1,
    },
    raw_data => {
        data_type => 'longtext',
        is_nullable => 1,
    },
    retrieved_at => {
        data_type => 'timestamp',
        default_value => 'current_timestamp()',
    },
    sunrise => {
        data_type => 'time',
        is_nullable => 1,
    },
    sunset => {
        data_type => 'time',
        is_nullable => 1,
    },
    temperature => {
        data_type => 'decimal',
        size => 5,2,
        is_nullable => 1,
    },
    uv_index => {
        data_type => 'decimal',
        size => 3,1,
        is_nullable => 1,
    },
    visibility => {
        data_type => 'decimal',
        size => 5,2,
        is_nullable => 1,
    },
    weather_icon => {
        data_type => 'varchar',
        size => 10,
        is_nullable => 1,
    },
    wind_direction => {
        data_type => 'int',
        size => 11,
        is_nullable => 1,
    },
    wind_gust => {
        data_type => 'decimal',
        size => 5,2,
        is_nullable => 1,
    },
    wind_speed => {
        data_type => 'decimal',
        size => 5,2,
        is_nullable => 1,
    },
);
__PACKAGE__->set_primary_key('id');

1;
