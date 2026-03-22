#!/usr/bin/perl
use strict;
use warnings;
use File::Spec;
use FindBin;
use lib File::Spec->catdir($FindBin::Bin, 'Comserv', 'lib');
use Comserv::Util::Logging;

# Test local logging first
print "Testing local logging...\n";
$ENV{'COMSERV_LOG_DIR'} = File::Spec->catdir($FindBin::Bin, 'test_logs_local');
Comserv::Util::Logging->init();
my $logger = Comserv::Util::Logging->instance();
$logger->log_with_details(undef, 'INFO', __FILE__, __LINE__, 'test', "Local log message");

if (-f File::Spec->catfile($ENV{'COMSERV_LOG_DIR'}, 'logs', 'application.log')) {
    print "SUCCESS: Local log file created.\n";
} else {
    print "FAILED: Local log file NOT created.\n";
}

# Now test NFS logging if variable set
print "\nTesting NFS logging...\n";
my $nfs_dir = File::Spec->catdir($FindBin::Bin, 'test_logs_nfs');
$ENV{'COMSERV_NFS_LOG_DIR'} = $nfs_dir;
Comserv::Util::Logging->init();
$logger->log_with_details(undef, 'INFO', __FILE__, __LINE__, 'test', "NFS log message");

if (-f File::Spec->catfile($nfs_dir, 'application.log')) {
    print "SUCCESS: NFS log file created at $nfs_dir/application.log\n";
} else {
    print "FAILED: NFS log file NOT created at $nfs_dir/application.log\n";
}

# Cleanup
# system("rm -rf test_logs_local test_logs_nfs");
