package Comserv::Model::Schema::Ency::Result::SchemaMigration;
use base 'DBIx::Class::Core';

__PACKAGE__->table('schema_migrations');
__PACKAGE__->add_columns(
    applied_at => {
        data_type => 'timestamp',
        is_nullable => 1,
        default_value => 'current_timestamp()',
    },
    applied_by => {
        data_type => 'varchar',
        size => 100,
        is_nullable => 1,
    },
    checksum => {
        data_type => 'varchar',
        size => 64,
    },
    description => {
        data_type => 'text',
        is_nullable => 1,
    },
    error => {
        data_type => 'text',
        is_nullable => 1,
    },
    execution_time_ms => {
        data_type => 'int',
        size => 11,
        is_nullable => 1,
    },
    id => {
        data_type => 'int',
        size => 11,
        is_auto_increment => 1,
    },
    name => {
        data_type => 'varchar',
        size => 255,
    },
    rolled_back_at => {
        data_type => 'timestamp',
        is_nullable => 1,
    },
    status => {
        data_type => 'enum',
        extra => { list => ['applied','failed','rolled_back'] },
    },
    version => {
        data_type => 'varchar',
        size => 20,
    },
);
__PACKAGE__->set_primary_key('id');

1;
