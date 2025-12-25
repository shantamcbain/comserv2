package Comserv::Util::ProxmoxCredentials;

use strict;
use warnings;
use JSON;
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

my $CREDENTIALS_FILE = File::Spec->catfile(
    dirname(dirname(dirname(dirname(__FILE__)))),
    'config',
    'proxmox_credentials.json'
);

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

        if ($server_creds->{token_value_encrypted}) {
            $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, "get_credentials",
                "Decrypting token value for server: $server_id");

            my $decrypted = Comserv::Util::Encryption->decrypt($server_creds->{token_value_encrypted}, 'proxmox');
            $server_creds->{token_value} = $decrypted;
            delete $server_creds->{token_value_encrypted};
        }

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

    if ($creds_copy{token_value}) {
        $creds_copy{token_value_encrypted} = Comserv::Util::Encryption->encrypt($creds_copy{token_value}, 'proxmox');
        delete $creds_copy{token_value};
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
        
        if ($server->{token_value_encrypted}) {
            $server->{token_value} = Comserv::Util::Encryption->decrypt($server->{token_value_encrypted}, 'proxmox');
            delete $server->{token_value_encrypted};
        }
        
        push @servers, $server;
    }

    $logging->log_with_details(undef, 'info', __FILE__, __LINE__, "get_all_servers",
        "Retrieved " . scalar(@servers) . " servers");
    return \@servers;
}

1;
