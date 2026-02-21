package Comserv::Model::Schema::Ency::Result::EmailVerificationCode;
use base 'DBIx::Class::Core';
use warnings FATAL => 'all';

__PACKAGE__->table('email_verification_codes');
__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    user_id => {
        data_type => 'integer',
        is_nullable => 0,
    },
    code_hash => {
        data_type => 'varchar',
        size => 64,
        is_nullable => 0,
    },
    created_at => {
        data_type => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP',
        is_nullable => 0,
    },
    expires_at => {
        data_type => 'timestamp',
        is_nullable => 0,
    },
    verified_at => {
        data_type => 'timestamp',
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->belongs_to(
    'user' => 'Comserv::Model::Schema::Ency::Result::User',
    'user_id',
    { on_delete => 'cascade' }
);

1;
