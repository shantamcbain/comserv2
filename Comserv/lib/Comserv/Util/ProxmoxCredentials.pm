package Comserv::Util::ProxmoxCredentials;

use strict;
use warnings;
use JSON;
use File::Spec;
use File::Basename;
use Try::Tiny;
use Comserv::Util::Logging;
use Digest::SHA qw(sha256_hex);

=head1 NAME

Comserv::Util::ProxmoxCredentials - Manage Proxmox server credentials

=head1 DESCRIPTION

This module provides functions to manage Proxmox server credentials in a JSON file
that is not versioned in the repository.

=head1 METHODS

=cut

# Get the logging instance
my $logging = Comserv::Util::Logging->instance;

# Path to the credentials file
my $CREDENTIALS_FILE = File::Spec->catfile(
    dirname(dirname(dirname(dirname(__FILE__)))),
    'config',
    'proxmox_credentials.json'
);

=head2 get_credentials_file_path

Get the path to the credentials file

=cut

sub get_credentials_file_path {
    return $CREDENTIALS_FILE;
}

# Simple obfuscation salt - not true encryption but better than plaintext
my $SALT = 'ComservProxmoxSalt2025';

# Obfuscate a string (simple XOR with salt)
sub _obfuscate {
    my ($plaintext) = @_;
    return '' unless $plaintext;

    # Create a unique salt for this value
    my $unique_salt = sha256_hex($SALT . $plaintext);

    # Store with a marker so we know it's obfuscated
    return "OBFS:" . $unique_salt . ":" . $plaintext;
}

# Retrieve the original string
sub _deobfuscate {
    my ($obfuscated) = @_;
    $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, "_deobfuscate",
        "Deobfuscating string of length: " . (defined $obfuscated ? length($obfuscated) : 0));

    return '' unless $obfuscated;

    # If it's not in our format, return as is
    if ($obfuscated !~ /^OBFS:/) {
        $logging->log_with_details(undef, 'warn', __FILE__, __LINE__, "_deobfuscate",
            "String is not in OBFS format, returning as is");
        return $obfuscated;
    }

    # Extract the original text (after the second colon)
    my (undef, $salt, $plaintext) = split(/:/, $obfuscated, 3);

    $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, "_deobfuscate",
        "Extracted salt of length: " . (defined $salt ? length($salt) : 0));
    $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, "_deobfuscate",
        "Extracted plaintext of length: " . (defined $plaintext ? length($plaintext) : 0));

    if (!defined $plaintext || $plaintext eq '') {
        $logging->log_with_details(undef, 'error', __FILE__, __LINE__, "_deobfuscate",
            "Failed to extract plaintext from obfuscated string: $obfuscated");
        
        # Try a different approach - sometimes the format might be different
        if ($obfuscated =~ /^OBFS:([^:]+):(.+)$/) {
            $salt = $1;
            $plaintext = $2;
            $logging->log_with_details(undef, 'info', __FILE__, __LINE__, "_deobfuscate",
                "Extracted plaintext using regex approach, length: " . length($plaintext));
        }
    }

    return $plaintext || '';
}

# Ensure the config directory exists
sub _ensure_config_dir {
    my $config_dir = dirname($CREDENTIALS_FILE);
    unless (-d $config_dir) {
        $logging->log_with_details(undef, 'info', __FILE__, __LINE__, "_ensure_config_dir", "Creating config directory: $config_dir");
        mkdir $config_dir or do {
            my $error = "Failed to create config directory: $!";
            $logging->log_with_details(undef, 'error', __FILE__, __LINE__, "_ensure_config_dir", $error);
            die $error;
        };
    }
}

=head2 get_credentials

Get the credentials for a Proxmox server

=cut

sub get_credentials {
    my ($server_id) = @_;
    $server_id ||= 'default';

    $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, "get_credentials", "Getting credentials for server: $server_id");

    # If the credentials file doesn't exist, return empty credentials
    unless (-f $CREDENTIALS_FILE) {
        $logging->log_with_details(undef, 'info', __FILE__, __LINE__, "get_credentials", "Credentials file does not exist: $CREDENTIALS_FILE");
        return {
            server_id => $server_id,
            host => '',
            username => '',
            password => '',
            realm => 'pam',
            node => 'pve',
            image_url_base => '',
        };
    }

    # Read the credentials file
    $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, "get_credentials", "Opening credentials file: $CREDENTIALS_FILE");
    open my $fh, '<', $CREDENTIALS_FILE or do {
        my $error = "Failed to open credentials file: $!";
        $logging->log_with_details(undef, 'error', __FILE__, __LINE__, "get_credentials", $error);
        die $error;
    };
    my $json = do { local $/; <$fh> };
    close $fh;

    $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, "get_credentials", "Read " . length($json) . " bytes from credentials file");

    # Log a snippet of the JSON for debugging (first 100 chars)
    my $json_snippet = substr($json, 0, 100);
    $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, "get_credentials", "JSON snippet: $json_snippet...");

    # Parse the JSON
    my $credentials;
    try {
        $credentials = decode_json($json);
        $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, "get_credentials",
            "Successfully parsed credentials file with " . scalar(keys %$credentials) . " servers");

        # Log the server IDs
        my $server_ids = join(', ', keys %$credentials);
        $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, "get_credentials", "Server IDs: $server_ids");
    } catch {
        my $error = "Failed to parse credentials file: $_";
        $logging->log_with_details(undef, 'error', __FILE__, __LINE__, "get_credentials", $error);
        die $error;
    };

    # Return the credentials for the specified server
    if ($server_id && exists $credentials->{$server_id}) {
        $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, "get_credentials", "Found credentials for server: $server_id");

        # Deobfuscate the token value if it exists
        my $server_creds = $credentials->{$server_id};
        $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, "get_credentials",
            "Server credentials keys: " . join(', ', keys %$server_creds));

        if ($server_creds->{token_value_obfuscated}) {
            $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, "get_credentials",
                "Deobfuscating token value for server: $server_id");

            my $obfuscated = $server_creds->{token_value_obfuscated};
            $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, "get_credentials",
                "Obfuscated token format: " . (substr($obfuscated, 0, 20) . "..."));

            $server_creds->{token_value} = _deobfuscate($obfuscated);
            
            # Check if deobfuscation was successful
            if (!$server_creds->{token_value} || $server_creds->{token_value} eq '') {
                $logging->log_with_details(undef, 'error', __FILE__, __LINE__, "get_credentials",
                    "Failed to deobfuscate token value for server: $server_id");
                
                # As a fallback, try using the raw token value if it looks like a valid UUID
                if ($obfuscated =~ /([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/i) {
                    $server_creds->{token_value} = $1;
                    $logging->log_with_details(undef, 'info', __FILE__, __LINE__, "get_credentials",
                        "Using extracted UUID as token value: " . substr($server_creds->{token_value}, 0, 8) . "...");
                }
            }
            
            $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, "get_credentials",
                "Token deobfuscated successfully: " . ($server_creds->{token_value} ? "YES" : "NO") . 
                ", Length: " . length($server_creds->{token_value}));

            delete $server_creds->{token_value_obfuscated}; # Remove the obfuscated version
        } else {
            $logging->log_with_details(undef, 'warn', __FILE__, __LINE__, "get_credentials",
                "No obfuscated token value found for server: $server_id");
        }

        return $server_creds;
    }

    # If the server doesn't exist, return empty credentials
    $logging->log_with_details(undef, 'info', __FILE__, __LINE__, "get_credentials", "No credentials found for server: $server_id");
    return {
        server_id => $server_id,
        host => '',
        token_user => '',
        token_value => '',
        node => 'pve',
        image_url_base => '',
    };
}

# This function was redefined below - removing this version

=head2 save_credentials

Save credentials for a Proxmox server

=cut

sub save_credentials {
    my ($server_id, $credentials) = @_;
    $server_id ||= 'default';

    $logging->log_with_details(undef, 'info', __FILE__, __LINE__, "save_credentials", "Saving credentials for server: $server_id");

    # Ensure the config directory exists
    _ensure_config_dir();

    # Read existing credentials
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
            $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, "save_credentials", "Successfully read existing credentials");
        } catch {
            # If the file is invalid, start with an empty hash
            $logging->log_with_details(undef, 'warn', __FILE__, __LINE__, "save_credentials", "Invalid credentials file, starting with empty hash: $_");
            $all_credentials = {};
        };
    }

    # Add or update the credentials for this server
    # Make a copy of the credentials to avoid modifying the original
    my %creds_copy = %{$credentials};

    # Obfuscate the token value if it exists
    if ($creds_copy{token_value}) {
        $creds_copy{token_value_obfuscated} = _obfuscate($creds_copy{token_value});
        delete $creds_copy{token_value}; # Don't store the plaintext token
    }

    $all_credentials->{$server_id} = \%creds_copy;

    # Write the credentials file
    open my $fh, '>', $CREDENTIALS_FILE or do {
        my $error = "Failed to write credentials file: $!";
        $logging->log_with_details(undef, 'error', __FILE__, __LINE__, "save_credentials", $error);
        die $error;
    };
    print $fh encode_json($all_credentials);
    close $fh;

    # Set restrictive permissions on the file
    chmod 0600, $CREDENTIALS_FILE or do {
        my $warning = "Failed to set permissions on credentials file: $!";
        $logging->log_with_details(undef, 'warn', __FILE__, __LINE__, "save_credentials", $warning);
        warn $warning;
    };

    $logging->log_with_details(undef, 'info', __FILE__, __LINE__, "save_credentials", "Successfully saved credentials for server: $server_id");
    return 1;
}

=head2 delete_server

Delete a Proxmox server from the credentials file

=cut

sub delete_server {
    my ($server_id) = @_;
    
    # If the credentials file doesn't exist, there's nothing to delete
    unless (-f $CREDENTIALS_FILE) {
        return 0;
    }
    
    # Read existing credentials
    open my $fh, '<', $CREDENTIALS_FILE or die "Failed to open credentials file: $!";
    my $json = do { local $/; <$fh> };
    close $fh;
    
    my $all_credentials;
    try {
        $all_credentials = decode_json($json);
    } catch {
        die "Failed to parse credentials file: $_";
    };
    
    # If the server doesn't exist, there's nothing to delete
    unless (exists $all_credentials->{$server_id}) {
        return 0;
    }
    
    # Delete the server
    delete $all_credentials->{$server_id};
    
    # Write the credentials file
    open $fh, '>', $CREDENTIALS_FILE or die "Failed to write credentials file: $!";
    print $fh encode_json($all_credentials);
    close $fh;
    
    return 1;
}

=head2 get_all_servers

Get a list of all configured Proxmox servers

=cut

sub get_all_servers {
    # If the credentials file doesn't exist, return an empty list
    unless (-f $CREDENTIALS_FILE) {
        $logging->log_with_details(undef, 'info', __FILE__, __LINE__, "get_all_servers", "Credentials file does not exist: $CREDENTIALS_FILE");
        return [];
    }

    # Read the credentials file
    open my $fh, '<', $CREDENTIALS_FILE or do {
        my $error = "Failed to open credentials file: $!";
        $logging->log_with_details(undef, 'error', __FILE__, __LINE__, "get_all_servers", $error);
        die $error;
    };
    my $json = do { local $/; <$fh> };
    close $fh;

    # Parse the JSON
    my $credentials;
    try {
        $credentials = decode_json($json);
        $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, "get_all_servers", "Successfully parsed credentials file");
    } catch {
        my $error = "Failed to parse credentials file: $_";
        $logging->log_with_details(undef, 'error', __FILE__, __LINE__, "get_all_servers", $error);
        die $error;
    };

    # Convert the hash to an array of server objects with IDs
    my @servers = ();
    foreach my $server_id (sort keys %$credentials) {
        my $server = $credentials->{$server_id};
        $server->{id} = $server_id;
        push @servers, $server;
    }

    $logging->log_with_details(undef, 'info', __FILE__, __LINE__, "get_all_servers", "Retrieved " . scalar(@servers) . " servers");
    return \@servers;
}

1;