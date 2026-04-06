package Comserv::Model::Schema::Ency::Result::WeatherHistory;
use base 'DBIx::Class::Core';

__PACKAGE__->table('weather_history');
__PACKAGE__->add_columns(
    id => {
        data_type         => 'int',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    config_id => {
        data_type   => 'int',
        is_nullable => 0,
        is_foreign_key => 1,
    },
    temperature => {
        data_type   => 'decimal',
        size        => [5, 2],
        is_nullable => 1,
    },
    feels_like => {
        data_type   => 'decimal',
        size        => [5, 2],
        is_nullable => 1,
    },
    humidity => {
        data_type   => 'int',
        is_nullable => 1,
    },
    pressure => {
        data_type   => 'decimal',
        size        => [7, 2],
        is_nullable => 1,
    },
    wind_speed => {
        data_type   => 'decimal',
        size        => [5, 2],
        is_nullable => 1,
    },
    cloudiness => {
        data_type   => 'int',
        is_nullable => 1,
    },
    condition_main => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 1,
    },
    condition_description => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
    },
    weather_icon => {
        data_type   => 'varchar',
        size        => 10,
        is_nullable => 1,
    },
    location_name => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
    },
    recorded_at => {
        data_type     => 'timestamp',
        default_value => 'current_timestamp()',
        is_nullable   => 0,
    },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->belongs_to(
    'weather_config',
    'Comserv::Model::Schema::Ency::Result::WeatherConfig',
    'config_id'
);

1;
