package Comserv::Model::Schema::Ency::Result::UserApiKeys;
use base 'DBIx::Class::Core';
__PACKAGE__->load_components("InflateColumn::DateTime");
use warnings FATAL => 'all';
use JSON;
use Crypt::CBC;
use MIME::Base64;

__PACKAGE__->table('user_api_keys');
__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    user_id => {
        data_type => 'integer',
        is_nullable => 0,
    },
    site_id => {
        data_type => 'integer',
        is_nullable => 1,
    },
    service => {
        data_type => 'enum',
        extra => { list => ['grok', 'ollama', 'brave', 'searxng', 'openai', 'claude', 'gemini', 'anthropic', 'cohere'] },
        is_nullable => 0,
    },
    api_key_encrypted => {
        data_type => 'text',
        is_nullable => 0,
    },
    metadata => {
        data_type => 'text',
        is_nullable => 1,
    },
    is_active => {
        data_type => 'boolean',
        default_value => 1,
        is_nullable => 0,
    },
    created_at => {
        data_type => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP',
        is_nullable => 0,
    },
    updated_at => {
        data_type => 'timestamp',
        is_nullable => 0,
        default_value => 'current_timestamp()',
    },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->add_unique_constraint(
    'unique_user_site_service' => ['user_id', 'site_id', 'service']
);

__PACKAGE__->belongs_to(
    'user' => 'Comserv::Model::Schema::Ency::Result::User',
    { 'foreign.id' => 'self.user_id' },
    { on_delete => 'cascade' }
);

__PACKAGE__->belongs_to(
    'site' => 'Comserv::Model::Schema::Ency::Result::Site',
    { 'foreign.id' => 'self.site_id' },
    { join_type => 'left', on_delete => 'cascade' }
);

sub get_metadata {
    my $self = shift;
    my $metadata = $self->metadata;
    return {} unless $metadata;
    eval {
        return decode_json($metadata);
    };
    return {};
}

sub set_metadata {
    my ($self, $metadata_hash) = @_;
    return unless ref($metadata_hash) eq 'HASH';
    $self->metadata(encode_json($metadata_hash));
}

sub encrypt_api_key {
    my ($self, $plain_key) = @_;
    return unless $plain_key;
    
    my $encryption_key = $ENV{API_KEY_ENCRYPTION_KEY} || 'default-encryption-key-change-in-production';
    
    my $cipher = Crypt::CBC->new(
        -key    => $encryption_key,
        -cipher => 'Cipher::AES',
        -salt   => 1,
        -pbkdf  => 'pbkdf2',
    );
    
    my $encrypted = $cipher->encrypt($plain_key);
    return encode_base64($encrypted, '');
}

sub decrypt_api_key {
    my ($self) = @_;
    return unless $self->api_key_encrypted;
    
    my $encryption_key = $ENV{API_KEY_ENCRYPTION_KEY} || 'default-encryption-key-change-in-production';
    
    my $cipher = Crypt::CBC->new(
        -key    => $encryption_key,
        -cipher => 'Cipher::AES',
        -salt   => 1,
        -pbkdf  => 'pbkdf2',
    );
    
    my $decrypted;
    eval {
        my $encrypted = decode_base64($self->api_key_encrypted);
        $decrypted = $cipher->decrypt($encrypted);
    };
    if ($@) {
        warn "UserApiKeys decrypt_api_key failed for id=" . ($self->id || '?') . ": $@";
        return undef;
    }
    return $decrypted;
}

sub set_api_key {
    my ($self, $plain_key) = @_;
    my $encrypted = $self->encrypt_api_key($plain_key);
    $self->api_key_encrypted($encrypted) if $encrypted;
}

sub get_api_key {
    my $self = shift;
    return $self->decrypt_api_key();
}

1;
