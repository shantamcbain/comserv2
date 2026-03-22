package Comserv::Model::Schema::Ency::Result::ApiToken;
use base 'DBIx::Class::Core';

__PACKAGE__->table('api_tokens');
__PACKAGE__->add_columns(
    id => {
        data_type => 'int',
        is_auto_increment => 1,
    },
    user_id => {
        data_type => 'int',
        is_nullable => 0,
    },
    token_hash => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 0,
    },
    token_name => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 1,
    },
    is_active => {
        data_type => 'tinyint',
        default_value => 1,
    },
    created_at => {
        data_type => 'datetime',
        is_nullable => 0,
    },
    expires_at => {
        data_type => 'datetime',
        is_nullable => 1,
    },
    last_used_at => {
        data_type => 'datetime',
        is_nullable => 1,
    },
    revoked_at => {
        data_type => 'datetime',
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key('id');
__PACKAGE__->belongs_to(user => 'Comserv::Model::Schema::Ency::Result::User', 'user_id');

1;
