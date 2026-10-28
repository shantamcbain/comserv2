package Comserv::Util::ProxmoxCredentials;

use strict;
use warnings;
use JSON;
use DBI;
use File::Spec;
use File::Basename;
use Try::Tiny;
use Comserv::Util::Logging;
use Comserv::Util::Encryption;

=head1 NAME

Comserv::Util::ProxmoxCredentials - Manage Proxmox server credentials with AES-256 encryption

=head1 DESCRIPTION

This module provides secure credential management for Proxmox servers using AES-256 encryption.
Credentials are encrypted at rest and only decrypted when actively used.

=head1 METHODS

=cut

my $logging = Comserv::Util::Logging->instance;

# lib/Comserv/Util -> app root is three levels up. The old path landed in
# lib/Comserv/Comserv/config, which does not exist, so the add-server form
# never wrote the file the dashboard reads.
my $CREDENTIALS_FILE = File::Spec->catfile(
    dirname(__FILE__),
    '..', '..', '..',
    'config',
    'proxmox_credentials.json'
);

# api_tokens.token_hash is a one-way hash for inbound API auth and cannot be
# decrypted. app_secrets.secret_value is the existing reversible store
# (same table Cloudflare credentials use). The value written here is always
# ENC:... from Comserv::Util::Encryption, never the raw Proxmox token.
my $ENCY_DBH;

=head2 Encryption Note

Encryption/decryption logic has been extracted to Comserv::Util::Encryption module.
This module now delegates to that module using the 'proxmox' namespace.

=cut

=head2 get_credentials_file_path

Get the path to the credentials file

=cut

sub get_credentials_file_path {
    return $CREDENTIALS_FILE;
}

sub _token_key {
    my ($server_id) = @_;
    $server_id //= 'default';
    $server_id =~ s/[^A-Za-z0-9_-]//g;
    return "proxmox_token:$server_id";
}

sub _ency_dbh {
    if ($ENCY_DBH && eval { $ENCY_DBH->ping }) {
        return $ENCY_DBH;
    }
    $ENCY_DBH = undef;

    require Comserv::Model::RemoteDB;
    my $remote = Comserv::Model::RemoteDB->new();
    my $info = $remote->get_connection_info('ency');
    die "No ency database connection available\n" unless $info && $info->{config};

    my $conn = $info->{config};
    my $driver = 'MariaDB';
    eval { require DBD::MariaDB; 1 } or do {
        require DBD::mysql;
        $driver = 'mysql';
    };
    my $host = $conn->{host} || '127.0.0.1';
    $host = '127.0.0.1' if $host eq 'localhost';
    my $dsn = "dbi:$driver:database=$conn->{database};host=$host;port=" . ($conn->{port} || 3306);

    $ENCY_DBH = DBI->connect($dsn, $conn->{username}, $conn->{password}, {
        RaiseError => 1,
        PrintError => 0,
        AutoCommit => 1,
    }) or die "Cannot connect to ency for app_secrets: $DBI::errstr\n";
    return $ENCY_DBH;
}

sub _store_token {
    my ($server_id, $plaintext) = @_;
    return 0 unless defined $plaintext && length $plaintext;

    my $encrypted = Comserv::Util::Encryption->encrypt($plaintext, 'proxmox');
    die "Encryption produced no ciphertext for Proxmox token\n"
        unless $encrypted && $encrypted =~ /^ENC:/;

    my $dbh = _ency_dbh();
    my $key = _token_key($server_id);
    my $sth = $dbh->prepare(
        "INSERT INTO app_secrets (secret_key, secret_value, description, updated_by)
         VALUES (?, ?, ?, 'proxmox')
         ON DUPLICATE KEY UPDATE secret_value = VALUES(secret_value),
                                 description = VALUES(description),
                                 updated_by = 'proxmox'"
    );
    $sth->execute($key, $encrypted, "Proxmox API token for $server_id");
    $logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_store_token',
        "Stored encrypted Proxmox token in app_secrets for $server_id");
    return 1;
}

sub _load_token {
    my ($server_id) = @_;
    my $dbh = eval { _ency_dbh() };
    if ($@ || !$dbh) {
        $logging->log_with_details(undef, 'error', __FILE__, __LINE__, '_load_token',
            "Cannot read app_secrets: " . ($@ || 'no dbh'));
        return '';
    }
    my $sth = $dbh->prepare("SELECT secret_value FROM app_secrets WHERE secret_key = ?");
    $sth->execute(_token_key($server_id));
    my ($stored) = $sth->fetchrow_array;
    return '' unless defined $stored && length $stored;
    my $plain = Comserv::Util::Encryption->decrypt($stored, 'proxmox');
    unless (defined $plain && length $plain) {
        $logging->log_with_details(undef, 'error', __FILE__, __LINE__, '_load_token',
            "Proxmox token for $server_id is in app_secrets but did not decrypt");
        return '';
    }
    return $plain;
}

sub _delete_token {
    my ($server_id) = @_;
    my $dbh = eval { _ency_dbh() };
    return 0 if $@ || !$dbh;
    my $sth = $dbh->prepare("DELETE FROM app_secrets WHERE secret_key = ?");
    $sth->execute(_token_key($server_id));
    return 1;
}

# Never persist the raw token (or a file-local ciphertext) next to the
# non-secret server fields.
sub _strip_token_fields {
    my ($creds) = @_;
    delete $creds->{token_value};
    delete $creds->{token_value_encrypted};
    return $creds;
}



=head2 get_credentials

Get the credentials for a Proxmox server (decrypted)

=cut

sub get_credentials {
    my ($server_id) = @_;
    $server_id ||= 'default';

    $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, "get_credentials",
        "Getting credentials for server: $server_id");

    unless (-f $CREDENTIALS_FILE) {
        $logging->log_with_details(undef, 'info', __FILE__, __LINE__, "get_credentials",
            "Credentials file does not exist: $CREDENTIALS_FILE");
        return {
            server_id => $server_id,
            host => '',
            token_user => '',
            token_value => '',
            node => 'pve',
            image_url_base => '',
        };
    }

    open my $fh, '<', $CREDENTIALS_FILE or do {
        my $error = "Failed to open credentials file: $!";
        $logging->log_with_details(undef, 'error', __FILE__, __LINE__, "get_credentials", $error);
        die $error;
    };
    my $json = do { local $/; <$fh> };
    close $fh;

    my $credentials;
    try {
        $credentials = decode_json($json);
        $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, "get_credentials",
            "Successfully parsed credentials file");
    } catch {
        my $error = "Failed to parse credentials file: $_";
        $logging->log_with_details(undef, 'error', __FILE__, __LINE__, "get_credentials", $error);
        die $error;
    };

    if ($server_id && exists $credentials->{$server_id}) {
        $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, "get_credentials",
            "Found credentials for server: $server_id");

        my $server_creds = $credentials->{$server_id};
        _strip_token_fields($server_creds);
        $server_creds->{token_value} = _load_token($server_id);
        unless ($server_creds->{host}) {
            my $url = $server_creds->{api_url_base} || '';
            $server_creds->{host} = $1 if $url =~ m{https?://([^:/]+)};
        }
        $server_creds->{name} ||= $server_id;

        return $server_creds;
    }

    $logging->log_with_details(undef, 'info', __FILE__, __LINE__, "get_credentials",
        "No credentials found for server: $server_id");
    return {
        server_id => $server_id,
        host => '',
        token_user => '',
        token_value => '',
        node => 'pve',
        image_url_base => '',
    };
}

=head2 save_credentials

Save credentials for a Proxmox server (encrypted)

=cut

sub save_credentials {
    my ($server_id, $credentials) = @_;
    $server_id ||= 'default';

    $logging->log_with_details(undef, 'info', __FILE__, __LINE__, "save_credentials",
        "Saving credentials for server: $server_id");

    my $all_credentials = {};
    if (-f $CREDENTIALS_FILE) {
        open my $fh, '<', $CREDENTIALS_FILE or do {
            my $error = "Failed to open credentials file: $!";
            $logging->log_with_details(undef, 'error', __FILE__, __LINE__, "save_credentials", $error);
            die $error;
        };
        my $json = do { local $/; <$fh> };
        close $fh;

        try {
            $all_credentials = decode_json($json);
            $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, "save_credentials",
                "Successfully read existing credentials");
        } catch {
            $logging->log_with_details(undef, 'warn', __FILE__, __LINE__, "save_credentials",
                "Invalid credentials file, starting with empty hash: $_");
            $all_credentials = {};
        };
    }

    my %creds_copy = %{$credentials};
    my $token_value = delete $creds_copy{token_value};
    _strip_token_fields(\%creds_copy);

    if (defined $token_value && length $token_value) {
        _store_token($server_id, $token_value);
    }

    $all_credentials->{$server_id} = \%creds_copy;

    open my $fh, '>', $CREDENTIALS_FILE or do {
        my $error = "Failed to write credentials file: $!";
        $logging->log_with_details(undef, 'error', __FILE__, __LINE__, "save_credentials", $error);
        die $error;
    };
    print $fh encode_json($all_credentials);
    close $fh;

    chmod 0600, $CREDENTIALS_FILE or do {
        my $warning = "Failed to set permissions on credentials file: $!";
        $logging->log_with_details(undef, 'warn', __FILE__, __LINE__, "save_credentials", $warning);
        warn $warning;
    };

    $logging->log_with_details(undef, 'info', __FILE__, __LINE__, "save_credentials",
        "Successfully saved credentials for server: $server_id");
    return 1;
}

=head2 delete_server

Delete a Proxmox server from the credentials file

=cut

sub delete_server {
    my ($server_id) = @_;
    
    unless (-f $CREDENTIALS_FILE) {
        return 0;
    }
    
    open my $fh, '<', $CREDENTIALS_FILE or die "Failed to open credentials file: $!";
    my $json = do { local $/; <$fh> };
    close $fh;
    
    my $all_credentials;
    try {
        $all_credentials = decode_json($json);
    } catch {
        die "Failed to parse credentials file: $_";
    };
    
    unless (exists $all_credentials->{$server_id}) {
        return 0;
    }
    
    delete $all_credentials->{$server_id};
    _delete_token($server_id);
    
    open $fh, '>', $CREDENTIALS_FILE or die "Failed to write credentials file: $!";
    print $fh encode_json($all_credentials);
    close $fh;
    
    chmod 0600, $CREDENTIALS_FILE;
    
    return 1;
}

=head2 get_all_servers

Get a list of all configured Proxmox servers (with decrypted tokens)

=cut

sub get_all_servers {
    unless (-f $CREDENTIALS_FILE) {
        $logging->log_with_details(undef, 'info', __FILE__, __LINE__, "get_all_servers",
            "Credentials file does not exist: $CREDENTIALS_FILE");
        return [];
    }

    open my $fh, '<', $CREDENTIALS_FILE or do {
        my $error = "Failed to open credentials file: $!";
        $logging->log_with_details(undef, 'error', __FILE__, __LINE__, "get_all_servers", $error);
        die $error;
    };
    my $json = do { local $/; <$fh> };
    close $fh;

    my $credentials;
    try {
        $credentials = decode_json($json);
        $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, "get_all_servers",
            "Successfully parsed credentials file");
    } catch {
        my $error = "Failed to parse credentials file: $_";
        $logging->log_with_details(undef, 'error', __FILE__, __LINE__, "get_all_servers", $error);
        die $error;
    };

    my @servers = ();
    foreach my $server_id (sort keys %$credentials) {
        my $server = $credentials->{$server_id};
        $server->{id} = $server_id;
        _strip_token_fields($server);
        $server->{token_value} = _load_token($server_id);
        unless ($server->{host}) {
            my $url = $server->{api_url_base} || '';
            $server->{host} = $1 if $url =~ m{https?://([^:/]+)};
        }
        $server->{name} ||= $server_id;
        
        push @servers, $server;
    }

    $logging->log_with_details(undef, 'info', __FILE__, __LINE__, "get_all_servers",
        "Retrieved " . scalar(@servers) . " servers");
    return \@servers;
}

1;
