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
    # Oct 30 2026: free lowercase provider slug (^[a-z0-9_.-]{2,64}$), no enum -> a new provider needs no schema change.
    # Applied by Admin > Schema Compare from this file. See Comserv::Util::AI::UserKeys.
    service => {
        data_type => 'varchar',
        size => 64,
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
    # chat | management | billing | search | ... (NULL rows from before the migration count as chat)
    key_type => {
        data_type => 'varchar',
        size => 32,
        is_nullable => 1,
        default_value => 'chat',
    },
    # optional OpenAI-compatible endpoint (validated by UserKeys->validate_base_url: https, or http only for LAN/localhost)
    base_url => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 1,
    },
    label => {
        data_type => 'varchar',
        size => 128,
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
    'unique_user_site_service_type' => ['user_id', 'site_id', 'service', 'key_type']
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
    return $metadata if ref($metadata) eq 'HASH';
    my $parsed;
    eval {
        $parsed = decode_json($metadata);
    };
    if ($@) {
        warn "UserApiKeys get_metadata decode failed for id=" . ($self->id || '?') . ": $@";
        return {};
    }
    return ref($parsed) eq 'HASH' ? $parsed : {};
}

sub set_metadata {
    my ($self, $metadata_hash) = @_;
    return unless ref($metadata_hash) eq 'HASH';
    $self->metadata(encode_json($metadata_hash));
    return;  # Return value to maintain consistency with other methods
}

sub encrypt_api_key {
    use Comserv::Util::Encryption;
    my ($self, $plain_key) = @_;
    return unless $plain_key;
    
    # Use standard Comserv::Util::Encryption module for consistency
    # Use 'user_api_keys' namespace to differentiate from other encrypted data
    return Comserv::Util::Encryption->encrypt($plain_key, 'user_api_keys');
}

sub decrypt_api_key {
    use Comserv::Util::Encryption;
    my ($self) = @_;
    return unless $self->api_key_encrypted;
    
    # Use standard Comserv::Util::Encryption module for consistency
    my $encrypted = $self->api_key_encrypted;
    
    # If the encrypted data has 'ENC:' prefix, use the Encryption module
    if ($encrypted =~ /^ENC:/) {
        return Comserv::Util::Encryption->decrypt($encrypted, 'user_api_keys');
    }
    
    # Fallback: try legacy decryption for backward compatibility
    # This maintains compatibility with existing data encrypted with the old system
    my $encryption_key = $ENV{API_KEY_ENCRYPTION_KEY} || 'default-encryption-key-change-in-production';
    
    use Crypt::CBC;
    my $cipher = Crypt::CBC->new(
        -key    => $encryption_key,
        -cipher => 'Cipher::AES',
        -salt   => 1,
        -pbkdf  => 'pbkdf2',
    );
    
    my $decrypted;
    eval {
        my $encrypted = decode_base64($encrypted);
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
