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

Comserv::Util::ProxmoxCredentials - Proxmox server records and API tokens in app_secrets

=head1 DESCRIPTION

The only file this application needs is the database login. The Proxmox API
token and the non-secret server record (host, API URL, node, token user) both
live in ency.app_secrets, so every host that can reach the database — including
the Docker test container — can connect without a local credentials file.

  proxmox_token:<server_id>  ENC: ciphertext of the API token
  proxmox_server:<server_id> JSON of the non-secret server record

config/proxmox_credentials.json is an optional local cache. A missing or
unwritable file is not an error.

=cut

my $logging = Comserv::Util::Logging->instance;

# Optional local cache. lib/Comserv/Util -> app root is three levels up.
my $CREDENTIALS_FILE = File::Spec->catfile(
    dirname(__FILE__),
    '..', '..', '..',
    'config',
    'proxmox_credentials.json'
);

my $ENCY_DBH;
my $JSON = JSON->new->canonical(1);

=head2 get_credentials_file_path

Path of the optional local cache. Callers must not treat a missing file as failure.

=cut

sub get_credentials_file_path {
    return $CREDENTIALS_FILE;
}

sub _safe_id {
    my ($server_id) = @_;
    $server_id //= 'default';
    $server_id =~ s/[^A-Za-z0-9_-]//g;
    return $server_id || 'default';
}

sub _token_key {
    my ($server_id) = @_;
    return 'proxmox_token:' . _safe_id($server_id);
}

sub _server_key {
    my ($server_id) = @_;
    return 'proxmox_server:' . _safe_id($server_id);
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

sub _upsert_secret {
    my ($key, $value, $description) = @_;
    my $dbh = _ency_dbh();
    my $sth = $dbh->prepare(
        "INSERT INTO app_secrets (secret_key, secret_value, description, updated_by)
         VALUES (?, ?, ?, 'proxmox')
         ON DUPLICATE KEY UPDATE secret_value = VALUES(secret_value),
                                 description = VALUES(description),
                                 updated_by = 'proxmox'"
    );
    $sth->execute($key, $value, $description);
    return 1;
}

sub _store_token {
    my ($server_id, $plaintext) = @_;
    return 0 unless defined $plaintext && length $plaintext;

    my $encrypted = Comserv::Util::Encryption->encrypt($plaintext, 'proxmox');
    die "Encryption produced no ciphertext for Proxmox token\n"
        unless $encrypted && $encrypted =~ /^ENC:/;

    _upsert_secret(_token_key($server_id), $encrypted, "Proxmox API token for $server_id");
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

sub _delete_secret {
    my ($key) = @_;
    my $dbh = eval { _ency_dbh() };
    return 0 if $@ || !$dbh;
    my $sth = $dbh->prepare("DELETE FROM app_secrets WHERE secret_key = ?");
    $sth->execute($key);
    return $sth->rows;
}

sub _delete_token {
    my ($server_id) = @_;
    return _delete_secret(_token_key($server_id));
}

sub _strip_token_fields {
    my ($creds) = @_;
    delete $creds->{token_value};
    delete $creds->{token_value_encrypted};
    delete $creds->{id};
    delete $creds->{server_id};
    return $creds;
}

sub _public_fields {
    my ($creds) = @_;
    my %copy = %{ $creds || {} };
    _strip_token_fields(\%copy);
    for my $key (keys %copy) {
        delete $copy{$key} unless defined $copy{$key} && $copy{$key} ne '';
    }
    return \%copy;
}

sub _store_server {
    my ($server_id, $creds) = @_;
    my $public = _public_fields($creds);
    return 0 unless $public->{api_url_base} || $public->{host};

    my $json = $JSON->encode($public);
    _upsert_secret(_server_key($server_id), $json, "Proxmox server record for $server_id");
    $logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_store_server',
        "Stored Proxmox server record in app_secrets for $server_id");
    return 1;
}

sub _load_servers_from_db {
    my $dbh = eval { _ency_dbh() };
    if ($@ || !$dbh) {
        $logging->log_with_details(undef, 'error', __FILE__, __LINE__, '_load_servers_from_db',
            "Cannot read app_secrets: " . ($@ || 'no dbh'));
        return {};
    }

    my $sth = $dbh->prepare(
        "SELECT secret_key, secret_value FROM app_secrets WHERE secret_key LIKE ?"
    );
    $sth->execute('proxmox_server:%');

    my %servers;
    while (my ($key, $value) = $sth->fetchrow_array) {
        next unless defined $key && $key =~ /^proxmox_server:(.+)$/;
        my $server_id = $1;
        next unless defined $value && length $value;
        my $record;
        try {
            $record = $JSON->decode($value);
        } catch {
            $logging->log_with_details(undef, 'error', __FILE__, __LINE__, '_load_servers_from_db',
                "Proxmox server record for $server_id is not JSON: $_");
        };
        next unless $record && ref $record eq 'HASH';
        _strip_token_fields($record);
        $servers{$server_id} = $record;
    }
    return \%servers;
}

sub _read_file_servers {
    return {} unless -f $CREDENTIALS_FILE;

    my $json = eval {
        open my $fh, '<', $CREDENTIALS_FILE or die "Failed to open credentials file: $!";
        local $/;
        my $text = <$fh>;
        close $fh;
        $text;
    };
    if ($@ || !defined $json) {
        $logging->log_with_details(undef, 'error', __FILE__, __LINE__, '_read_file_servers',
            "Cannot read optional credentials file: " . ($@ || 'empty'));
        return {};
    }

    my $credentials;
    try {
        $credentials = $JSON->decode($json);
    } catch {
        $logging->log_with_details(undef, 'error', __FILE__, __LINE__, '_read_file_servers',
            "Optional credentials file is not JSON: $_");
    };
    return {} unless $credentials && ref $credentials eq 'HASH';

    my %servers;
    for my $server_id (keys %$credentials) {
        next unless $credentials->{$server_id} && ref $credentials->{$server_id} eq 'HASH';
        my %copy = %{ $credentials->{$server_id} };
        _strip_token_fields(\%copy);
        $servers{$server_id} = \%copy;
    }
    return \%servers;
}

sub _fill_connection {
    my ($server_id, $creds) = @_;
    $creds ||= {};
    unless ($creds->{host}) {
        my $url = $creds->{api_url_base} || '';
        $creds->{host} = $1 if $url =~ m{https?://([^:/]+)};
    }
    unless ($creds->{api_url_base}) {
        my $host = $creds->{host} || '';
        if ($host) {
            my $port = $creds->{port} || 8006;
            my $protocol = $creds->{protocol} || 'https';
            $creds->{api_url_base} = "$protocol://$host:$port/api2/json";
        }
    }
    $creds->{name} ||= $server_id;
    $creds->{node} ||= 'pve';
    $creds->{id} = $server_id;
    $creds->{server_id} = $server_id;
    return $creds;
}

sub _hydrate {
    my ($server_id, $creds) = @_;
    $creds = _fill_connection($server_id, { %{ $creds || {} } });
    $creds->{token_value} = _load_token($server_id);
    return $creds;
}

sub _merged_servers {
    my $from_db = _load_servers_from_db();
    my $from_file = _read_file_servers();
    my %ids = map { $_ => 1 } (keys %$from_db, keys %$from_file);

    my %merged;
    for my $server_id (keys %ids) {
        my %record = %{ $from_file->{$server_id} || {} };
        my $db_record = $from_db->{$server_id} || {};
        for my $key (keys %$db_record) {
            my $value = $db_record->{$key};
            $record{$key} = $value if defined $value && $value ne '';
        }
        $merged{$server_id} = \%record;
    }
    return \%merged;
}

sub _empty_credentials {
    my ($server_id) = @_;
    return {
        server_id => $server_id,
        id => $server_id,
        host => '',
        token_user => '',
        token_value => '',
        node => 'pve',
        image_url_base => '',
        api_url_base => '',
    };
}

sub _write_file_cache {
    my ($servers) = @_;
    my $dir = dirname($CREDENTIALS_FILE);
    unless (-d $dir) {
        $logging->log_with_details(undef, 'warn', __FILE__, __LINE__, '_write_file_cache',
            "Optional credentials directory does not exist: $dir");
        return 0;
    }

    my %public;
    for my $server_id (keys %$servers) {
        $public{$server_id} = _public_fields($servers->{$server_id});
    }

    my $wrote = eval {
        open my $fh, '>', $CREDENTIALS_FILE or die "Failed to write credentials file: $!";
        print $fh $JSON->encode(\%public);
        close $fh;
        chmod 0600, $CREDENTIALS_FILE;
        1;
    };
    if ($@ || !$wrote) {
        $logging->log_with_details(undef, 'warn', __FILE__, __LINE__, '_write_file_cache',
            "Optional credentials file was not updated: " . ($@ || 'write failed'));
        return 0;
    }
    return 1;
}

=head2 get_credentials

Server record plus decrypted token. The database is enough; the local file is optional.

=cut

sub get_credentials {
    my ($server_id) = @_;
    $server_id = _safe_id($server_id);

    $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, 'get_credentials',
        "Getting credentials for server: $server_id");

    my $servers = _merged_servers();
    unless (exists $servers->{$server_id}) {
        $logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'get_credentials',
            "No Proxmox server record in app_secrets or the optional local file for $server_id");
        return _empty_credentials($server_id);
    }

    my $creds = _hydrate($server_id, $servers->{$server_id});
    $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, 'get_credentials',
        "Loaded $server_id api_url_base=" . ($creds->{api_url_base} ? 'set' : 'missing')
        . " token=" . ($creds->{token_value} ? 'set' : 'missing'));
    return $creds;
}

=head2 save_credentials

Write the server record and, when supplied, the token to app_secrets.
Updating the local file is best-effort.

=cut

sub save_credentials {
    my ($server_id, $credentials) = @_;
    $server_id = _safe_id($server_id);
    $credentials ||= {};

    $logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'save_credentials',
        "Saving credentials for server: $server_id");

    my $token_value = $credentials->{token_value};
    if (defined $token_value && length $token_value) {
        _store_token($server_id, $token_value);
    }

    my $public = _fill_connection($server_id, _public_fields($credentials));
    _store_server($server_id, $public);

    my $all = _read_file_servers();
    $all->{$server_id} = _public_fields($public);
    _write_file_cache($all);

    $logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'save_credentials',
        "Saved Proxmox server record for $server_id in app_secrets");
    return 1;
}

=head2 delete_server

Remove the server record and token from app_secrets. The local file is updated when it exists.

=cut

sub delete_server {
    my ($server_id) = @_;
    $server_id = _safe_id($server_id);

    my $removed = 0;
    $removed += _delete_secret(_server_key($server_id)) || 0;
    $removed += _delete_token($server_id) || 0;

    my $file_servers = _read_file_servers();
    if (exists $file_servers->{$server_id}) {
        delete $file_servers->{$server_id};
        _write_file_cache($file_servers);
        $removed++;
    }

    $logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'delete_server',
        "Deleted Proxmox server $server_id from app_secrets");
    return $removed ? 1 : 0;
}

=head2 get_all_servers

Every server known to app_secrets, plus any extra servers in the optional local file.

=cut

sub get_all_servers {
    my $servers = _merged_servers();
    my @list;
    for my $server_id (sort keys %$servers) {
        push @list, _hydrate($server_id, $servers->{$server_id});
    }

    $logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'get_all_servers',
        "Retrieved " . scalar(@list) . " Proxmox servers from app_secrets"
        . (-f $CREDENTIALS_FILE ? ' and the local file' : ''));
    return \@list;
}

1;
