package Comserv::Model::Schema::Ency::Result::UserPreference;

use base 'DBIx::Class::Core';
use JSON qw(decode_json encode_json);

__PACKAGE__->table('user_preferences');
__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
    },
    user_id => {
        data_type   => 'integer',
        is_nullable => 0,
    },
    pref_key => {
        data_type   => 'varchar',
        size        => 128,
        is_nullable => 0,
    },
    pref_value => {
        data_type   => 'longtext',
        is_nullable => 1,
    },
    updated_at => {
        data_type     => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP',
        is_nullable   => 0,
    },
);

__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint(uq_user_pref_key => [qw(user_id pref_key)]);

__PACKAGE__->belongs_to(
    user => 'Comserv::Model::Schema::Ency::Result::User',
    { 'foreign.id' => 'self.user_id' },
    { on_delete => 'CASCADE' },
);

sub decoded_value {
    my ($self) = @_;
    my $raw = $self->pref_value;
    return undef unless defined $raw && length $raw;
    my $decoded;
    eval { $decoded = decode_json($raw); 1 } or return $raw;
    return $decoded;
}

sub set_encoded_value {
    my ($self, $value) = @_;
    if (!defined $value) {
        $self->pref_value(undef);
        return;
    }
    $self->pref_value(encode_json($value));
}

1;