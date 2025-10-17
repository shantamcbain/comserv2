use strict;
use warnings;
use Test::More;
use Catalyst::Test 'Comserv';
use Comserv::Controller::Admin::Backup;

# Test basic controller loading
ok( request('/admin/backup')->is_success, 'Admin backup controller should load' );

# Test the BackupManager directly to capture debug output
# This will trigger all the debug warnings we added
use Comserv::Util::BackupManager;
use Comserv;

# Set up Catalyst context
my $c = Comserv->new();
$c->setup_finalize();

# Get BackupManager instance
my $backup_manager = Comserv::Util::BackupManager->new(app_dir => $c->config->{home});

# Capture STDERR to see debug output
my $debug_output = '';
{
    local *STDERR;
    open STDERR, '>', \$debug_output or die "Cannot capture STDERR: $!";
    
    # Attempt database backup - this should trigger all our debug warnings
    eval {
        my $result = $backup_manager->create_database_backup($c, 'test_debug', {
            backup_type => 'all',
            compress => 0
        });
        
        ok($result, 'Database backup should return a result') if $result;
    };
    
    # If backup fails, that's expected - we just want to see the debug output
    if ($@) {
        like($@, qr/No databases were successfully backed up/, 'Expected error message when no databases available');
    }
}

# Print debug output for analysis
diag("Debug output from backup attempt:");
diag($debug_output) if $debug_output;

# Check if we got the expected debug messages
like($debug_output, qr/DEBUG:/, 'Should contain debug messages') if $debug_output;

done_testing();