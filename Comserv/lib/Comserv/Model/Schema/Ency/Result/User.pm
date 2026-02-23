package Comserv::Model::Schema::Ency::Result::User;
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
        is_nullable => 1,
    },
    password => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 1,
    },
    first_name => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 1,
    },
    last_name => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 1,
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
    email_notifications => {
        data_type => 'tinyint',
        size => 4,
        is_nullable => 0,
        default_value => 1,
    },
    status => {
        data_type => 'varchar',
        size => 50,
        default_value => 'active',
        is_nullable => 0,
    },
    email_verified_at => {
        data_type => 'timestamp',
        is_nullable => 1,
    },
    created_by => {
        data_type => 'integer',
        is_nullable => 1,
    },
    creation_context => {
        data_type => 'varchar',
        size => 100,
        is_nullable => 1,
    },
    created_at => {
        data_type => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP',
        is_nullable => 0,
    },
    updated_at => {
        data_type => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP',
        is_nullable => 0,
    },
);
__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint('username_unique' => ['username']);
__PACKAGE__->add_unique_constraint('email_unique' => ['email']);

# Relationships
__PACKAGE__->has_many(site_users => 'Comserv::Model::Schema::Ency::Result::System::SiteUser', 'user_id');

__PACKAGE__->belongs_to(
    'creator' => 'Comserv::Model::Schema::Ency::Result::User',
    'created_by',
    { join_type => 'left', on_delete => 'set null' }
);

__PACKAGE__->has_many(
    'created_users' => 'Comserv::Model::Schema::Ency::Result::User',
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

# Add method to check password (needed for authentication)
sub check_password {
    my ($self, $password) = @_;
    
    # Use SHA256 hashing to match the hashed password stored in the database
    use Digest::SHA qw(sha256_hex);
    my $hashed_input = sha256_hex($password);
    
    return $self->password eq $hashed_input;
}

# Add method to get display name
sub display_name {
    my $self = shift;
    my $name = '';
    $name .= $self->first_name if $self->first_name;
    $name .= ' ' if $name && $self->last_name;
    $name .= $self->last_name if $self->last_name;
    return $name || $self->username;
}

1;