package Comserv::Util::Encryption;

use strict;
use warnings;
use Moose;
use namespace::autoclean;
use Try::Tiny;
use Crypt::CBC;
use Crypt::OpenSSL::AES;
use Crypt::Random qw(makerandom);
use MIME::Base64 qw(encode_base64 decode_base64);
use File::Spec;
use File::Basename;
use Comserv::Util::Logging;

=head1 NAME

Comserv::Util::Encryption - General-purpose AES-256 encryption/decryption for credential management

=head1 DESCRIPTION

Provides reusable AES-256-CBC encryption/decryption with support for multiple credential namespaces.
Each namespace (proxmox, database, api, etc.) can have its own encryption key.
Keys are stored in config directory or loaded from environment variables.

=head1 METHODS

=head2 encrypt($plaintext, $namespace)

Encrypt a string using AES-256-CBC.
Returns encrypted string prefixed with 'ENC:' and base64-encoded.

  my $encrypted = Comserv::Util::Encryption->encrypt('secret_token', 'proxmox');

=cut

sub encrypt {
    my ($class, $plaintext, $namespace) = @_;
    $namespace ||= 'default';
    
    return '' unless $plaintext;
    
    my $key = $class->_get_encryption_key($namespace);
    
    my $cipher = Crypt::CBC->new(
        -key             => $key,
        -cipher          => 'Crypt::OpenSSL::AES',
        -header          => 'salt',
        -iterations      => 1,
        -randomiv        => 1
    );
    
    my $encrypted = $cipher->encrypt($plaintext);
    
    return 'ENC:' . encode_base64($encrypted, '');
}

=head2 decrypt($encrypted_data, $namespace)

Decrypt a string that was encrypted with encrypt().
Automatically detects 'ENC:' prefix. Returns plaintext or empty string on error.
Handles legacy unencrypted data gracefully.

  my $plaintext = Comserv::Util::Encryption->decrypt($encrypted, 'proxmox');

=cut

sub decrypt {
    my ($class, $encrypted_data, $namespace) = @_;
    $namespace ||= 'default';
    
    return '' unless $encrypted_data;
    
    my $logging = Comserv::Util::Logging->instance;
    
    if ($encrypted_data !~ /^ENC:/) {
        $logging->log_with_details(undef, 'warn', __FILE__, __LINE__, "decrypt",
            "Data is not in encrypted format (namespace: $namespace), returning as-is (possible legacy data)");
        return $encrypted_data;
    }
    
    $encrypted_data =~ s/^ENC://;
    
    my $encrypted_bytes;
    try {
        $encrypted_bytes = decode_base64($encrypted_data);
    } catch {
        $logging->log_with_details(undef, 'error', __FILE__, __LINE__, "decrypt",
            "Failed to decode base64 (namespace: $namespace): $_");
        return '';
    };
    
    my $key = $class->_get_encryption_key($namespace);
    
    my $plaintext;
    try {
        my $cipher = Crypt::CBC->new(
            -key             => $key,
            -cipher          => 'Crypt::OpenSSL::AES',
            -header          => 'salt',
        );
        $plaintext = $cipher->decrypt($encrypted_bytes);
    } catch {
        $logging->log_with_details(undef, 'error', __FILE__, __LINE__, "decrypt",
            "Decryption failed (namespace: $namespace): $_");
        return '';
    };
    
    return $plaintext;
}

=head2 get_key($namespace)

Public method to get the encryption key (32 bytes for AES-256).
Used for testing and key management scripts.

=cut

sub get_key {
    my ($class, $namespace) = @_;
    $namespace ||= 'default';
    return $class->_get_encryption_key($namespace);
}

=head2 _get_encryption_key($namespace)

Private: Get or generate the encryption key for a specific namespace.
Priority: Environment variable → Key file → Generate new key

  # Looks for:
  # 1. PROXMOX_ENCRYPTION_KEY env var (for proxmox namespace)
  # 2. DATABASE_ENCRYPTION_KEY env var (for database namespace)
  # 3. /path/to/config/.proxmox_encryption_key file
  # 4. /path/to/config/.database_encryption_key file
  # 5. Generate new random key if neither exists

=cut

sub _get_encryption_key {
    my ($class, $namespace) = @_;
    $namespace ||= 'default';
    
    my $logging = Comserv::Util::Logging->instance;
    my $env_var_name = uc($namespace) . '_ENCRYPTION_KEY';
    
    # Try environment variable first
    if ($ENV{$env_var_name}) {
        my $key = $ENV{$env_var_name};
        if (length($key) == 64) {
            return pack('H*', $key);
        } elsif (length($key) >= 32) {
            return substr($key, 0, 32);
        }
    }
    
    # Try key file
    my $key_file = $class->_get_key_file_path($namespace);
    
    if (-f $key_file) {
        try {
            open my $fh, '<:raw', $key_file or die "Failed to open: $!";
            my $key = do { local $/; <$fh> };
            close $fh;
            
            if (length($key) == 32) {
                return $key;
            }
        } catch {
            $logging->log_with_details(undef, 'error', __FILE__, __LINE__, "_get_encryption_key",
                "Failed to read encryption key file ($namespace): $_");
            die "Failed to read encryption key file: $_";
        };
    }
    
    # Generate new key
    $logging->log_with_details(undef, 'warn', __FILE__, __LINE__, "_get_encryption_key",
        "No encryption key found for namespace '$namespace', generating new one");
    
    my $key = makerandom(Size => 256);
    
    $class->_ensure_config_dir();
    try {
        open my $fh, '>:raw', $key_file or die "Failed to open: $!";
        print $fh $key;
        close $fh;
        
        chmod 0600, $key_file or die "Failed to chmod: $!";
        
        $logging->log_with_details(undef, 'info', __FILE__, __LINE__, "_get_encryption_key",
            "Generated and saved encryption key for namespace '$namespace' at $key_file");
    } catch {
        $logging->log_with_details(undef, 'error', __FILE__, __LINE__, "_get_encryption_key",
            "Failed to save encryption key file ($namespace): $_");
        die "Failed to save encryption key file: $_";
    };
    
    return $key;
}

=head2 _get_key_file_path($namespace)

Get the file path for an encryption key file for a specific namespace.
Returns: /path/to/config/.{namespace}_encryption_key

=cut

sub _get_key_file_path {
    my ($class, $namespace) = @_;
    $namespace ||= 'default';
    
    my $config_dir = $class->_get_config_dir();
    return File::Spec->catfile($config_dir, '.' . $namespace . '_encryption_key');
}

=head2 _get_config_dir()

Get the Comserv config directory path.
Used for storing encryption keys.

=cut

sub _get_config_dir {
    my ($class) = @_;
    return File::Spec->catfile(
        dirname(dirname(dirname(dirname(__FILE__)))),
        'config'
    );
}

=head2 _ensure_config_dir()

Ensure the config directory exists, create if necessary.

=cut

sub _ensure_config_dir {
    my ($class) = @_;
    my $config_dir = $class->_get_config_dir();
    
    return if -d $config_dir;
    
    my $logging = Comserv::Util::Logging->instance;
    
    try {
        mkdir $config_dir or die "Failed to mkdir: $!";
        $logging->log_with_details(undef, 'info', __FILE__, __LINE__, "_ensure_config_dir",
            "Created config directory: $config_dir");
    } catch {
        my $error = "Failed to create config directory: $_";
        $logging->log_with_details(undef, 'error', __FILE__, __LINE__, "_ensure_config_dir", $error);
        die $error;
    };
}

__PACKAGE__->meta->make_immutable;
1;
