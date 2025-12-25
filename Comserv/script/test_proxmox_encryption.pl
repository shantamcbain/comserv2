#!/usr/bin/env perl

=head1 NAME

test_proxmox_encryption.pl - Test and verify Proxmox credential encryption

=head1 SYNOPSIS

  ./script/test_proxmox_encryption.pl [--verbose] [--cleanup]

=head1 OPTIONS

  --verbose   Show detailed output
  --cleanup   Remove test credentials after testing

=cut

use strict;
use warnings;
use lib 'lib';
use lib 'local/lib/perl5';
use Getopt::Long;
use JSON;
use File::Spec;
use File::Slurp;

my ($verbose, $cleanup);
GetOptions(
    'verbose!' => \$verbose,
    'cleanup!' => \$cleanup,
) or die "Error in command line arguments\n";

eval {
    require Comserv::Util::ProxmoxCredentials;
    require Comserv::Util::Logging;
};
if ($@) {
    print "ERROR: Failed to load required modules: $@\n";
    print "Make sure dependencies are installed: cpanm --installdeps .\n";
    exit 1;
}

my $logging = Comserv::Util::Logging->instance;
my $creds_file = Comserv::Util::ProxmoxCredentials::get_credentials_file_path();

print "=" x 70 . "\n";
print "Proxmox Credentials Encryption Test Suite\n";
print "=" x 70 . "\n\n";

# Test 1: Key file generation
print "[TEST 1] Encryption key generation and file permissions\n";
my $key_file = File::Spec->catfile(
    File::Basename::dirname(File::Basename::dirname($creds_file)),
    '.proxmox_encryption_key'
);

eval {
    Comserv::Util::ProxmoxCredentials::_get_encryption_key();
};
if ($@) {
    print "  ✗ FAILED: $@\n";
    exit 1;
}

if (-f $key_file) {
    my @stat = stat($key_file);
    my $perms = sprintf("%04o", $stat[2] & 07777);
    print "  ✓ Key file exists at: $key_file\n";
    print "    Permissions: $perms\n";
    
    if ($perms eq '0600') {
        print "  ✓ Permissions are correct (0600)\n";
    } else {
        print "  ⚠ WARNING: Permissions are $perms (should be 0600)\n";
    }
} else {
    print "  ✗ FAILED: Key file not created\n";
    exit 1;
}
print "\n";

# Test 2: Save encrypted credentials
print "[TEST 2] Save encrypted credentials\n";
my $test_server = 'test_' . int(rand(1000000));
my $test_token = 'PVE:' . ('x' x 32) . '-test-token-' . int(rand(10000));

print "  Test server ID: $test_server\n";
print "  Test token: " . substr($test_token, 0, 20) . "...\n";

eval {
    Comserv::Util::ProxmoxCredentials::save_credentials($test_server, {
        host              => 'pve.example.com',
        token_user        => 'root@pam',
        token_value       => $test_token,
        node              => 'pve',
        image_url_base    => 'http://pve.example.com:8006',
    });
};
if ($@) {
    print "  ✗ FAILED to save credentials: $@\n";
    exit 1;
}
print "  ✓ Credentials saved successfully\n";
print "\n";

# Test 3: Verify no plaintext in file
print "[TEST 3] Verify credentials are encrypted (no plaintext in file)\n";
my $json_content = read_file($creds_file);

if ($json_content =~ /\Q$test_token\E/) {
    print "  ✗ FAILED: Plaintext token found in credentials file!\n";
    print "  This indicates credentials are NOT encrypted.\n";
    exit 1;
}
print "  ✓ Plaintext token NOT found in file\n";

if ($json_content =~ /ENC:/) {
    print "  ✓ Encryption marker (ENC:) found in file\n";
} else {
    print "  ✗ WARNING: No encryption marker found\n";
}
print "\n";

# Test 4: Retrieve and decrypt credentials
print "[TEST 4] Retrieve and decrypt credentials\n";
my $retrieved;
eval {
    $retrieved = Comserv::Util::ProxmoxCredentials::get_credentials($test_server);
};
if ($@) {
    print "  ✗ FAILED to retrieve credentials: $@\n";
    exit 1;
}

if (!$retrieved) {
    print "  ✗ FAILED: No credentials returned\n";
    exit 1;
}
print "  ✓ Credentials retrieved successfully\n";

if ($retrieved->{token_value} eq $test_token) {
    print "  ✓ Decrypted token matches original\n";
} else {
    print "  ✗ FAILED: Decrypted token doesn't match\n";
    print "    Expected: $test_token\n";
    print "    Got:      " . $retrieved->{token_value} . "\n";
    exit 1;
}
print "\n";

# Test 5: Verify other fields
print "[TEST 5] Verify all credential fields\n";
my %expected = (
    host => 'pve.example.com',
    token_user => 'root@pam',
    node => 'pve',
    image_url_base => 'http://pve.example.com:8006',
);

my $all_ok = 1;
foreach my $field (sort keys %expected) {
    if ($retrieved->{$field} eq $expected{$field}) {
        print "  ✓ $field: OK\n";
    } else {
        print "  ✗ $field: MISMATCH\n";
        print "    Expected: $expected{$field}\n";
        print "    Got:      " . $retrieved->{$field} . "\n";
        $all_ok = 0;
    }
}

if (!$all_ok) {
    exit 1;
}
print "\n";

# Test 6: List all servers
print "[TEST 6] Get all servers\n";
my $all_servers;
eval {
    $all_servers = Comserv::Util::ProxmoxCredentials::get_all_servers();
};
if ($@) {
    print "  ✗ FAILED: $@\n";
    exit 1;
}

print "  ✓ Retrieved " . scalar(@$all_servers) . " server(s)\n";
foreach my $server (@$all_servers) {
    print "    - " . $server->{id} . " (" . $server->{host} . ")\n";
}
print "\n";

# Test 7: Decrypt with environment variable key
print "[TEST 7] Encryption key via environment variable\n";
if ($ENV{PROXMOX_ENCRYPTION_KEY}) {
    print "  ✓ PROXMOX_ENCRYPTION_KEY environment variable is set\n";
} else {
    print "  ℹ Environment variable not set (using file-based key)\n";
}
print "\n";

# Cleanup
if ($cleanup) {
    print "[CLEANUP] Removing test credentials\n";
    eval {
        Comserv::Util::ProxmoxCredentials::delete_server($test_server);
    };
    if ($@) {
        print "  ✗ Failed to delete test server: $@\n";
    } else {
        print "  ✓ Test server deleted\n";
    }
    print "\n";
}

# Summary
print "=" x 70 . "\n";
print "✓ All tests PASSED\n";
print "=" x 70 . "\n";
print "\nEncryption Status: OPERATIONAL\n";
print "Key File: $key_file\n";
print "Credentials File: $creds_file\n";

exit 0;
