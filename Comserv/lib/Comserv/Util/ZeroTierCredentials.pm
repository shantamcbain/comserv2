package Comserv::Util::ZeroTierCredentials;

use strict;
use warnings;
use JSON::MaybeXS qw(encode_json decode_json);
use Comserv::Util::Logging;
use Comserv::Util::Encryption;
use Comserv::Util::ZeroTier;

# Token lives in ency.app_secrets, encrypted. The row key is zerotier_api_token.
# Ciphertext uses the existing proxmox encryption key: a new namespace has no
# key file on this host, and Encryption refuses to invent one.
# Network id and the undo snapshot are not secrets. They share the table so
# every host that can reach the database sees the same values. No new table.

my $logging = Comserv::Util::Logging->instance;
my $ENCY_DBH;
my $ENC_NS = 'proxmox';

sub TOKEN_KEY   { 'zerotier_api_token' }
sub NETWORK_KEY { 'zerotier_network_id' }
sub UNDO_KEY    { 'zerotier_undo' }

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
    require DBI;
    $ENCY_DBH = DBI->connect($dsn, $conn->{username}, $conn->{password}, {
        RaiseError => 1,
        PrintError => 0,
        AutoCommit => 1,
    }) or die "Cannot connect to ency for app_secrets\n";
    return $ENCY_DBH;
}

sub _select {
    my ($key) = @_;
    my $dbh = _ency_dbh();
    my $sth = $dbh->prepare('SELECT secret_value FROM app_secrets WHERE secret_key = ?');
    $sth->execute($key);
    my ($value) = $sth->fetchrow_array;
    return defined $value ? $value : '';
}

sub _upsert {
    my ($key, $value, $description, $by) = @_;
    my $dbh = _ency_dbh();
    my $who = $by && $by =~ /^[A-Za-z0-9_.-]{1,80}$/ ? $by : 'zerotier';
    my $sth = $dbh->prepare(
        'INSERT INTO app_secrets (secret_key, secret_value, description, updated_by)
         VALUES (?, ?, ?, ?)
         ON DUPLICATE KEY UPDATE secret_value = VALUES(secret_value),
                                 description = VALUES(description),
                                 updated_by = VALUES(updated_by)'
    );
    $sth->execute($key, $value, $description, $who);
    return 1;
}

sub token_is_set {
    my $stored = eval { _select(TOKEN_KEY()) };
    if ($@) {
        $logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'token_is_set',
            'Cannot read ZeroTier token row from app_secrets');
        return 0;
    }
    return defined $stored && $stored =~ /^ENC:/ ? 1 : 0;
}

sub load_token {
    my $stored = eval { _select(TOKEN_KEY()) };
    if ($@) {
        $logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'load_token',
            'Cannot read ZeroTier token row from app_secrets');
        return '';
    }
    return '' unless defined $stored && length $stored;
    my $plain = eval { Comserv::Util::Encryption->decrypt($stored, $ENC_NS) };
    if ($@ || !defined $plain || $plain eq '') {
        $logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'load_token',
            'ZeroTier token is in app_secrets but did not decrypt');
        return '';
    }
    return $plain;
}

sub save_token {
    my ($token, $by) = @_;
    return { ok => 0, error => 'Token was empty. Nothing was saved.' }
        unless defined $token && $token =~ /\S/;
    my $enc = eval { Comserv::Util::Encryption->encrypt($token, $ENC_NS) };
    if ($@ || !$enc || $enc !~ /^ENC:/) {
        $logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'save_token',
            'ZeroTier token was not saved: encryption failed');
        return { ok => 0, error => 'Token was not saved. Encryption failed.' };
    }
    my $ok = eval { _upsert(TOKEN_KEY(), $enc, 'ZeroTier Central API token', $by); 1 };
    if (!$ok || $@) {
        my $err = Comserv::Util::ZeroTier::redact("$@", $token);
        $logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'save_token',
            "ZeroTier token was not saved: $err");
        return { ok => 0, error => 'Token was not saved. Database write failed.' };
    }
    $logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'save_token',
        'Stored encrypted ZeroTier token in app_secrets');
    return { ok => 1 };
}

sub load_network_id {
    my $id = eval { _select(NETWORK_KEY()) };
    if ($@) {
        $logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'load_network_id',
            'Cannot read ZeroTier network id from app_secrets');
        return $Comserv::Util::ZeroTier::DEFAULT_NETWORK_ID;
    }
    return $Comserv::Util::ZeroTier::DEFAULT_NETWORK_ID
        unless Comserv::Util::ZeroTier::valid_network_id($id);
    return lc $id;
}

sub save_network_id {
    my ($id, $by) = @_;
    return { ok => 0, error => 'Network id must be 16 hex characters.' }
        unless Comserv::Util::ZeroTier::valid_network_id($id);
    my $ok = eval {
        _upsert(NETWORK_KEY(), lc $id, 'ZeroTier network id (not a secret)', $by);
        1;
    };
    if (!$ok || $@) {
        $logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'save_network_id',
            'ZeroTier network id was not saved');
        return { ok => 0, error => 'Network id was not saved.' };
    }
    return { ok => 1 };
}

sub save_undo {
    my ($record, $by) = @_;
    return { ok => 0, error => 'Undo record was empty.' } unless ref $record eq 'HASH';
    delete $record->{token};
    delete $record->{api_token};
    my $json = eval { encode_json($record) };
    if ($@ || !$json) {
        $logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'save_undo',
            'ZeroTier undo snapshot could not be encoded');
        return { ok => 0, error => 'Undo snapshot was not saved.' };
    }
    my $ok = eval {
        _upsert(UNDO_KEY(), $json, 'Last ZeroTier routes and DNS before a change', $by);
        1;
    };
    if (!$ok || $@) {
        $logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'save_undo',
            'ZeroTier undo snapshot was not saved');
        return { ok => 0, error => 'Undo snapshot was not saved.' };
    }
    return { ok => 1 };
}

sub load_undo {
    my $json = eval { _select(UNDO_KEY()) };
    if ($@) {
        $logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'load_undo',
            'Cannot read ZeroTier undo snapshot from app_secrets');
        return;
    }
    return unless defined $json && $json =~ /\S/;
    my $rec = eval { decode_json($json) };
    if ($@ || ref $rec ne 'HASH') {
        $logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'load_undo',
            'ZeroTier undo snapshot is not valid JSON');
        return;
    }
    delete $rec->{token};
    delete $rec->{api_token};
    return $rec;
}

1;
