#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../local/lib/perl5";

# Make the script executable
system("chmod +x $FindBin::Bin/test_email_modules.pl");

print "Testing email module loading...\n\n";
print "Using \@INC paths:\n";
foreach my $path (@INC) {
    print "  $path\n";
}
print "\n";

# First test base modules
my @base_modules = (
    'Catalyst::View::Email',
    'Catalyst::View::Email::Template',
    'Email::MIME',
    'Email::Sender::Simple',
    'Email::Sender::Transport::SMTP',
    'Email::Simple',
);

my $base_ok = 1;
print "Testing base email modules:\n";
foreach my $module (@base_modules) {
    print "  Testing $module... ";
    eval "require $module";
    if ($@) {
        print "FAILED: $@\n";
        $base_ok = 0;
    } else {
        print "OK\n";
    }
}

print "\n";
if ($base_ok) {
    print "All base email modules loaded successfully!\n";
} else {
    print "Some base modules failed to load. Please run:\n";
    print "  perl $FindBin::Bin/install_email_modules.pl\n";
}

# Then test Comserv views
print "\nTesting Comserv email views:\n";
my $views_ok = 1;

eval {
    require Comserv::View::Email;
    print "  Comserv::View::Email loaded successfully.\n";
};
if ($@) {
    print "  Failed to load Comserv::View::Email: $@\n";
    $views_ok = 0;
}

eval {
    require Comserv::View::Email::Template;
    print "  Comserv::View::Email::Template loaded successfully.\n";
};
if ($@) {
    print "  Failed to load Comserv::View::Email::Template: $@\n";
    $views_ok = 0;
}

print "\n";
if ($views_ok) {
    print "All Comserv email views loaded successfully!\n";
} else {
    print "Some Comserv email views failed to load.\n";
    print "This may be due to missing base modules.\n";
}

# Overall status
print "\n";
if ($base_ok && $views_ok) {
    print "ALL TESTS PASSED: Email system should be working correctly.\n";
} else {
    print "SOME TESTS FAILED: Email system may not work correctly.\n";
    print "Please run: perl $FindBin::Bin/install_email_modules.pl\n";
}

exit($base_ok && $views_ok ? 0 : 1);