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
        is_nullable => 0,
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
    },
    roles => {
        data_type => 'text',
    },
);
__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint('username_unique' => ['username']);

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
