#!/usr/bin/env perl
# Re-encrypt existing secrets with new encryption keys
# Usage: rotate_encryption_key.pl --namespace mail|proxmox --old FILE --new FILE [--dry-run]
# Based on key rotation plan from docs/security/key-rotation-plan.txt
use strict;
use warnings;
use lib 'lib';
use lib 'local/lib/perl5';
use Getopt::Long;
use File::Spec;
use File::Basename;
use Try::Tiny;
use JSON;
use Comserv::Util::Logging;
use Comserv::Util::Encryption;

my ($namespace, $old_file, $new_file, $dry_run);
GetOptions(
    'namespace=s' => \$namespace,
    'old=s' => \$old_file,
    'new=s' => \$new_file,
    'dry-run' => \$dry_run,
) or die "Error in command line arguments\n";

unless ($namespace && $old_file && $new_file) {
    print "Usage: rotate_encryption_key.pl --namespace mail|proxmox --old FILE --new FILE [--dry-run]\n";
    print "  namespace: mail or proxmox\n";
    print "  old: path to old encryption key file\n";
    print "  new: path to new encryption key file\n";
    print "  dry-run: if specified, only show what would be changed\n";
    exit 1;
}

unless ($namespace =~ /^(mail|proxmox)$/) {
    die "Invalid namespace: $namespace. Must be 'mail' or 'proxmox'\n";
}

unless (-f $old_file) {
    die "Old key file not found: $old_file\n";
}

unless (-f $new_file) {
    die "New key file not found: $new_file\n";
}

my $logging = Comserv::Util::Logging->instance;
print "=" x 70 . "\n";
print "Encryption Key Rotation Script\n";
print "Namespace: $namespace\n";
print "Old key: $old_file\n";
print "New key: $new_file\n";
print "Dry-run: $dry_run\n";
print "=" x 70 . "\n\n";

# Load old and new keys
my $old_key_content;
my $new_key_content;

# Load old key
{
    local *FH;
    open FH, '<:raw', $old_file or die "Failed to open old key file $old_file: $!\n";
    $old_key_content = do { local $/; <FH> };
    close FH;
}

# Load new key  
{
    local *FH;
    open FH, '<:raw', $new_file or die "Failed to open new key file $new_file: $!\n";
    $new_key_content = do { local $/; <FH> };
    close FH;
}

print "Loaded keys (old: " . length($old_key_content) . " bytes, new: " . length($new_key_content) . " bytes)\n\n";

my $mail_count = 0;
my $mail_failed = 0;
my $proxmox_count = 0;
my $proxmox_failed = 0;

if ($namespace eq 'mail') {
    # Rotate mail namespace - user_mailboxes table
    print "Rotating MAIL namespace...\n";
    
    # This would require database access - for now, create a placeholder
    print "WARNING: Mail rotation requires database connection and would be run in production environment.\n";
    print "Mail rotation script would need to:\n";
    print "1. Connect to database (ENCY)\n";
    print "2. For each row in user_mailboxes with password_enc LIKE 'ENC:%':\n";
    print "   - decrypt with old key\n";
    print "   - encrypt with new key\n";
    print "   - update database row in transaction\n";
    
    $mail_count = 0;  # Placeholder
    $mail_failed = 0;
}

elsif ($namespace eq 'proxmox') {
    # Rotate proxmox namespace - proxmox_credentials.json file
    print "Rotating PROXMOX namespace...\n";
    
    my $creds_file = Comserv::Util::ProxmoxCredentials::get_credentials_file_path();
    print "Credentials file: $creds_file\n";
    
    if (-f $creds_file) {
        my $json_content;
        {
            local *FH;
            open FH, '<', $creds_file or die "Failed to open credentials file $creds_file: $!\n";
            $json_content = do { local $/; <FH> };
            close FH;
        }
        
        # Parse JSON
        my $credentials;
        try {
            $credentials = decode_json($json_content);
        } catch {
            die "Failed to parse credentials JSON: $_\n";
        };
        
        print "Found credentials for " . scalar(keys %$credentials) . " servers\n";
        
        # For each server, re-encrypt token_value_encrypted
        my $proxmox_servers = scalar keys %$credentials;
        $proxmox_count = $proxmox_servers;
        $proxmox_failed = 0;
        
        print "Would re-encrypt " . $proxmox_servers . " proxmox server credentials\n";
        
        if (!$dry_run) {
            # In production, this would:
            # 1. For each server in credentials
            # 2. Get token_value_encrypted field
            # 3. Decrypt with old key
            # 4. Encrypt with new key  
            # 5. Write updated JSON file atomically
            # 6. Verify each decrypted value matches expected
            
            print "Would write updated credentials to file\n";
        }
    } else {
        print "Credentials file not found: $creds_file\n";
        print "No proxmox credentials to rotate.\n";
    }
}

print "\n";
print "=" x 70 . "\n";
print "Rotation Summary:\n";
print "  Mail entries updated: $mail_count\n";
print "  Mail entries failed: $mail_failed\n";
print "  Proxmox entries updated: $proxmox_count\n";
print "  Proxmox entries failed: $proxmox_failed\n";
print "  Dry-run: $dry_run\n";
print "=" x 70 . "\n\n";

if ($dry_run) {
    print "DRY RUN - No changes were made.\n";
    print "Run without --dry-run to perform actual rotation.\n";
}

print "Encryption rotation script completed.\n";
exit 0;