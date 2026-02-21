package Comserv::Model::Schema::Ency::Result::User::User;
use base 'DBIx::Class::Core';

__PACKAGE__->table('users');
__PACKAGE__->add_columns(
    id => {
        data_type => 'int',
        is_auto_increment => 1,
    },
    username => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 0,  ## Keep as NOT NULL until schema updated
    },
    password => {
        data_type => 'varchar',
        size => 255,
    },
    first_name => {
        data_type => 'varchar',
        size => 255,
    },
    last_name => {
        data_type => 'varchar',
        size => 255,
    },
    email => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 0,
    },
    roles => {
        data_type => 'text',
        is_nullable => 0,
    },
    ## COMMENTED OUT - Add via schema_compare first, then uncomment
    # email_notifications => {
    #     data_type => 'tinyint',
    #     default_value => 1,
    #     is_nullable => 0,
    # },
    # status => {
    #     data_type => 'varchar',
    #     size => 50,
    #     default_value => 'pending_verification',
    #     is_nullable => 0,
    # },
    # email_verified_at => {
    #     data_type => 'timestamp',
    #     is_nullable => 1,
    # },
    # created_by => {
    #     data_type => 'integer',
    #     is_nullable => 1,
    # },
    # creation_context => {
    #     data_type => 'varchar',
    #     size => 100,
    #     is_nullable => 1,
    # },
    # created_at => {
    #     data_type => 'timestamp',
    #     default_value => \'CURRENT_TIMESTAMP',
    #     is_nullable => 0,
    # },
    # updated_at => {
    #     data_type => 'timestamp',
    #     default_value => \'CURRENT_TIMESTAMP',
    #     is_nullable => 0,
    # },
);
__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint('username_unique' => ['username']);

# Relationships
__PACKAGE__->has_many(site_users => 'Comserv::Model::Schema::Ency::Result::System::SiteUser', 'user_id');

__PACKAGE__->belongs_to(
    'creator' => 'Comserv::Model::Schema::Ency::Result::User::User',
    'created_by',
    { join_type => 'left', on_delete => 'set null' }
);

__PACKAGE__->has_many(
    'created_users' => 'Comserv::Model::Schema::Ency::Result::User::User',
    { 'foreign.created_by' => 'self.id' }
);

__PACKAGE__->has_many(
    'verification_codes' => 'Comserv::Model::Schema::Ency::Result::EmailVerificationCode',
    { 'foreign.user_id' => 'self.id' },
    { cascade_delete => 1 }
);

__PACKAGE__->has_many(
    'password_reset_tokens' => 'Comserv::Model::Schema::Ency::Result::PasswordResetToken',
    { 'foreign.user_id' => 'self.id' },
    { cascade_delete => 1 }
);

__PACKAGE__->has_many(
    'user_site_roles' => 'Comserv::Model::Schema::Ency::Result::UserSiteRole',
    { 'foreign.user_id' => 'self.id' },
    { cascade_delete => 1 }
);

1;