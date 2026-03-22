#!/usr/bin/env perl

=head1 NAME

migrate_proxmox_credentials.pl - Migrate Proxmox credentials from weak obfuscation to AES-256 encryption

=head1 SYNOPSIS

  ./script/migrate_proxmox_credentials.pl

=head1 DESCRIPTION

This script migrates existing Proxmox credentials from the weak SHA256 obfuscation
scheme to proper AES-256 encryption. It should be run after updating ProxmoxCredentials.pm
to the new implementation.

=cut

use strict;
use warnings;
use lib 'lib';
use lib 'local/lib/perl5';
use JSON;
use File::Spec;
use File::Basename;
use Comserv::Util::ProxmoxCredentials;
use Comserv::Util::Logging;

my $logging = Comserv::Util::Logging->instance;
my $creds_file = Comserv::Util::ProxmoxCredentials::get_credentials_file_path();

unless (-f $creds_file) {
    print "No credentials file found at: $creds_file\n";
    print "Nothing to migrate.\n";
    exit 0;
}

print "Migrating Proxmox credentials from legacy format to AES-256 encryption...\n\n";

open my $fh, '<', $creds_file or die "Failed to open credentials file: $!";
my $json = do { local $/; <$fh> };
close $fh;

my $credentials;
eval {
    $credentials = decode_json($json);
};
if ($@) {
    print "ERROR: Failed to parse credentials file: $@\n";
    exit 1;
}

my $migrated_count = 0;
my $legacy_count = 0;

foreach my $server_id (keys %$credentials) {
    my $server = $credentials->{$server_id};
    
    if ($server->{token_value_obfuscated}) {
        $legacy_count++;
        
        my $obfuscated = $server->{token_value_obfuscated};
        my $plaintext = '';
        
        if ($obfuscated =~ /^OBFS:([^:]+):(.+)$/) {
            $plaintext = $2;
        } else {
            $plaintext = $obfuscated;
        }
        
        if ($plaintext) {
            print "Migrating server: $server_id\n";
            Comserv::Util::ProxmoxCredentials::save_credentials($server_id, {
                host              => $server->{host},
                token_user        => $server->{token_user},
                token_value       => $plaintext,
                node              => $server->{node},
                image_url_base    => $server->{image_url_base},
            });
            $migrated_count++;
            print "  ✓ Successfully migrated\n";
        } else {
            print "WARNING: Could not extract plaintext from obfuscated value for server: $server_id\n";
        }
    } elsif ($server->{token_value_encrypted}) {
        print "Server $server_id already using encrypted format (skipping)\n";
    } else {
        print "WARNING: Server $server_id has no credentials to migrate\n";
    }
}

print "\n";
print "Migration Summary:\n";
print "  Legacy credentials found: $legacy_count\n";
print "  Successfully migrated: $migrated_count\n";
print "  Migration Status: " . ($migrated_count == $legacy_count ? "✓ SUCCESS" : "⚠ PARTIAL") . "\n";

if ($migrated_count > 0) {
    print "\nEncryption key has been generated and stored at:\n";
    print "  " . File::Spec->catfile(dirname(dirname($creds_file)), '.proxmox_encryption_key') . "\n";
    print "\n⚠ IMPORTANT: Protect this file! It's needed to decrypt credentials.\n";
    print "   File permissions should be 0600 (read/write only by owner)\n";
}

exit 0;
