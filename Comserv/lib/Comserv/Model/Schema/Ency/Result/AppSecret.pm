package Comserv::Model::Schema::Ency::Result::AppSecret;
use base 'DBIx::Class::Core';

__PACKAGE__->table('app_secrets');

__PACKAGE__->add_columns(
    id           => { data_type => 'integer', is_auto_increment => 1 },
    secret_key   => { data_type => 'varchar', size => 100, is_nullable => 0 },
    secret_value => { data_type => 'text',    is_nullable => 0 },
    description  => { data_type => 'varchar', size => 255, is_nullable => 1 },
    updated_at   => { data_type => 'timestamp', is_nullable => 0,
                      default_value => \'CURRENT_TIMESTAMP' },
    updated_by   => { data_type => 'varchar', size => 100, is_nullable => 1 },
);

__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint(['secret_key']);

1;
