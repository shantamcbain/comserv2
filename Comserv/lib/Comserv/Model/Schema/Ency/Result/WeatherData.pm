package Comserv::Model::Schema::Ency::Result::WeatherData;
use base 'DBIx::Class::Core';

__PACKAGE__->table('weather_data');
__PACKAGE__->add_columns(
    id => {
        data_type => 'int',
        is_auto_increment => 1,
    },
    config_id => {
        data_type => 'int',
        is_nullable => 0,
        is_foreign_key => 1,
    },
    data_type => {
        data_type => 'enum',
        extra => { list => ['current', 'forecast'] },
        is_nullable => 0,
    },
    temperature => {
        data_type => 'decimal',
        size => [5, 2],
        is_nullable => 1,
    },
    feels_like => {
        data_type => 'decimal',
        size => [5, 2],
        is_nullable => 1,
    },
    humidity => {
        data_type => 'int',
        is_nullable => 1,
    },
    pressure => {
        data_type => 'decimal',
        size => [7, 2],
        is_nullable => 1,
    },
    wind_speed => {
        data_type => 'decimal',
        size => [5, 2],
        is_nullable => 1,
    },
    wind_direction => {
        data_type => 'int',
        is_nullable => 1,
    },
    wind_gust => {
        data_type => 'decimal',
        size => [5, 2],
        is_nullable => 1,
    },
    visibility => {
        data_type => 'decimal',
        size => [5, 2],
        is_nullable => 1,
    },
    uv_index => {
        data_type => 'decimal',
        size => [3, 1],
        is_nullable => 1,
    },
    condition_main => {
        data_type => 'varchar',
        size => 50,
        is_nullable => 1,
    },
    condition_description => {
        data_type => 'varchar',
        size => 100,
        is_nullable => 1,
    },
    weather_icon => {
        data_type => 'varchar',
        size => 10,
        is_nullable => 1,
    },
    cloudiness => {
        data_type => 'int',
        is_nullable => 1,
    },
    precipitation => {
        data_type => 'decimal',
        size => [5, 2],
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
    sunrise => {
        data_type => 'time',
        is_nullable => 1,
    },
    sunset => {
        data_type => 'time',
        is_nullable => 1,
    },
    location_name => {
        data_type => 'varchar',
        size => 100,
        is_nullable => 1,
    },
    raw_data => {
        data_type => 'json',
        is_nullable => 1,
    },
    retrieved_at => {
        data_type => 'timestamp',
        default_value => 'current_timestamp()',
        is_nullable => 0,
    },
);

__PACKAGE__->set_primary_key('id');

# Indexes
__PACKAGE__->add_unique_constraint('idx_config_type' => ['config_id', 'data_type']);

# Relationships
__PACKAGE__->belongs_to(
    'weather_config',
    'Comserv::Model::Schema::Ency::Result::WeatherConfig',
    'config_id'
);

1;