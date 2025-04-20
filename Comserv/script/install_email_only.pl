#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;

# Make the script executable
system("chmod +x $FindBin::Bin/install_email_only.pl");

# Set up local::lib for local installations
use lib "$FindBin::Bin/../local/lib/perl5";
$ENV{PERL5LIB} = "$FindBin::Bin/../local/lib/perl5:$ENV{PERL5LIB}";
$ENV{PATH} = "$FindBin::Bin/../local/bin:$ENV{PATH}";

# Ensure the local directory exists
unless (-d "$FindBin::Bin/../local") {
    mkdir "$FindBin::Bin/../local" or die "Could not create local directory: $!";
}

print "Installing only the essential email modules...\n";

# Install cpanm if not already installed
system("cpan App::cpanminus") unless `which cpanm`;

# Install email modules with specific versions
print "Installing email modules...\n";
my @modules = (
    # Core email modules only
    'Email::Simple@2.216',
    'Email::MIME@1.949',
    'Email::Sender::Simple@1.300035',
    'Catalyst::View::Email@0.36',
    'Catalyst::View::Email::Template@0.36'
);

my $all_success = 1;
foreach my $module (@modules) {
    print "Installing $module...\n";
    my $result = system("cpanm --local-lib=$FindBin::Bin/../local --notest $module");
    if ($result != 0) {
        print "Failed to install $module, trying with force flag...\n";
        $result = system("cpanm --local-lib=$FindBin::Bin/../local --notest --force $module");
        if ($result != 0) {
            print "WARNING: Failed to install $module even with force flag.\n";
            $all_success = 0;
        }
    }
}

print "\n";
if ($all_success) {
    print "All essential email modules installed successfully!\n";
} else {
    print "Some modules failed to install. Check the output above for details.\n";
}

print "\nNow run: script/comserv_server.pl -r\n";