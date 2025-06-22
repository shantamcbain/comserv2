#!/usr/bin/env perl

# Comserv Deployment Diagnostic Script
# This script helps diagnose the "Can't locate Comserv.pm" issue

use strict;
use warnings;
use FindBin;
use File::Spec;
use Cwd 'abs_path';

print "=== Comserv Deployment Diagnostic ===\n\n";

# Get the current directory
my $current_dir = abs_path($FindBin::Bin);
print "Current directory: $current_dir\n";

# Check if we're in a Comserv directory
my $is_comserv_dir = 0;
if (-f 'comserv.psgi' || -f 'Makefile.PL' || -d 'lib') {
    $is_comserv_dir = 1;
    print "✓ This appears to be a Comserv directory\n";
} else {
    print "✗ This doesn't appear to be a Comserv directory\n";
}

print "\n--- Checking Required Files ---\n";

# Check for PSGI file
if (-f 'comserv.psgi') {
    print "✓ comserv.psgi exists\n";
    
    # Test PSGI syntax
    print "  Testing PSGI syntax... ";
    my $psgi_test = `perl -c comserv.psgi 2>&1`;
    if ($? == 0) {
        print "OK\n";
    } else {
        print "FAILED\n";
        print "  Error: $psgi_test\n";
    }
} else {
    print "✗ comserv.psgi missing\n";
}

# Check for lib directory
if (-d 'lib') {
    print "✓ lib directory exists\n";
    
    # Check for Comserv.pm in lib
    if (-f 'lib/Comserv.pm') {
        print "✓ lib/Comserv.pm exists\n";
        
        # Test Comserv.pm syntax
        print "  Testing Comserv.pm syntax... ";
        my $comserv_test = `perl -I lib -c lib/Comserv.pm 2>&1`;
        if ($? == 0) {
            print "OK\n";
        } else {
            print "FAILED\n";
            print "  Error: $comserv_test\n";
        }
    } else {
        print "✗ lib/Comserv.pm missing\n";
    }
    
    # Check for Comserv module directory
    if (-d 'lib/Comserv') {
        print "✓ lib/Comserv directory exists\n";
        
        # List some key modules
        my @key_modules = qw(
            lib/Comserv/Controller
            lib/Comserv/Model
            lib/Comserv/View
            lib/Comserv/Util/Logging.pm
        );
        
        foreach my $module (@key_modules) {
            if (-e $module) {
                print "  ✓ $module exists\n";
            } else {
                print "  ✗ $module missing\n";
            }
        }
    } else {
        print "✗ lib/Comserv directory missing\n";
    }
} else {
    print "✗ lib directory missing\n";
}

print "\n--- Perl Environment ---\n";
print "Perl version: $]\n";
print "Perl executable: $^X\n";

print "\n--- \@INC Paths ---\n";
foreach my $path (@INC) {
    print "  $path\n";
}

# Check if we can load Comserv with current setup
print "\n--- Testing Module Loading ---\n";
if ($is_comserv_dir && -f 'lib/Comserv.pm') {
    print "Testing 'use lib \"lib\"; use Comserv;'... ";
    
    my $test_code = q{
        use lib "lib";
        use Comserv;
        print "SUCCESS\n";
    };
    
    my $result = `perl -e '$test_code' 2>&1`;
    if ($? == 0) {
        print "OK\n";
    } else {
        print "FAILED\n";
        print "Error: $result\n";
    }
}

print "\n--- Recommendations ---\n";

if (!$is_comserv_dir) {
    print "• Navigate to the Comserv application directory\n";
    print "• Ensure you're in the directory containing comserv.psgi\n";
}

if (!-f 'comserv.psgi') {
    print "• Create or copy comserv.psgi file\n";
}

if (!-d 'lib') {
    print "• Create lib directory\n";
}

if (!-f 'lib/Comserv.pm') {
    print "• Create or copy lib/Comserv.pm file\n";
    print "• This is the main application module\n";
}

if (!-d 'lib/Comserv') {
    print "• Create lib/Comserv directory structure\n";
    print "• Copy all Comserv modules (Controller, Model, View, etc.)\n";
}

print "\n--- Production Deployment Notes ---\n";
print "For production deployment on /opt/comserv/Comserv/:\n";
print "1. Ensure all files are copied to the production server\n";
print "2. Set proper ownership: chown -R www-data:www-data /opt/comserv/Comserv/\n";
print "3. Set proper permissions: chmod -R 755 /opt/comserv/Comserv/\n";
print "4. Test with: cd /opt/comserv/Comserv && perl -c comserv.psgi\n";
print "5. Restart Starman: systemctl restart starman\n";

print "\n=== Diagnostic Complete ===\n";