#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use Config;
use File::Spec;

# Set up paths
my $app_root = "$FindBin::Bin/..";
my $local_lib_path = "$app_root/local";
my $cpanfile_path = "$app_root/cpanfile";

# Check if we need to run with sudo
my $sudo = '';
if ($> != 0) { # Check if not running as root
    $sudo = 'sudo ';
}

# Function to detect the operating system
sub detect_os {
    if (-f '/etc/debian_version' || -f '/etc/ubuntu_version') {
        return 'debian';
    } elsif (-f '/etc/redhat-release' || -f '/etc/centos-release') {
        return 'redhat';
    } elsif (-f '/etc/arch-release') {
        return 'arch';
    } elsif (-f '/etc/SuSE-release') {
        return 'suse';
    } else {
        return 'unknown';
    }
}

# Check if a Perl module is installed
sub module_installed {
    my $module = shift;
    eval "require $module";
    return $@ ? 0 : 1;
}

# Install system dependencies for GD
sub install_gd_dependencies {
    my $os = detect_os();
    my $install_cmd = '';
    
    if ($os eq 'debian') {
        $install_cmd = "${sudo}apt-get update && ${sudo}apt-get install -y libgd-dev libpng-dev libjpeg-dev libfreetype6-dev";
    } elsif ($os eq 'redhat') {
        $install_cmd = "${sudo}yum install -y gd-devel libpng-devel libjpeg-devel freetype-devel";
    } elsif ($os eq 'arch') {
        $install_cmd = "${sudo}pacman -S --noconfirm gd libpng libjpeg-turbo freetype2";
    } elsif ($os eq 'suse') {
        $install_cmd = "${sudo}zypper install -y gd-devel libpng-devel libjpeg-devel freetype-devel";
    } else {
        print "Unknown OS. Please manually install GD dependencies.\n";
        return 0;
    }
    
    print "Installing GD dependencies with: $install_cmd\n";
    system($install_cmd);
    return $? == 0;
}

# Install Perl module dependencies
sub install_perl_module {
    my $module = shift;
    my $force = shift || 0;
    my $timeout = shift || 300;
    
    my $cmd = "cpanm --local-lib=$local_lib_path";
    $cmd .= " --force" if $force;
    $cmd .= " --verbose --timeout $timeout $module";
    
    print "Installing Perl module: $module\n";
    print "Running: $cmd\n";
    system($cmd);
    return $? == 0;
}

# Main program
print "Checking dependencies for Comserv application...\n";

# Check for GD module
if (!module_installed('GD')) {
    print "GD module not found. Checking for system dependencies...\n";
    
    if (install_gd_dependencies()) {
        print "GD system dependencies installed successfully.\n";
        
        # Now try to install the Perl GD module
        if (install_perl_module('GD', 1, 600)) {
            print "GD Perl module installed successfully.\n";
        } else {
            print "Failed to install GD Perl module. Some functionality may be limited.\n";
        }
    } else {
        print "Failed to install GD system dependencies. Manual installation may be required.\n";
    }
}

# Check for other critical modules
my @critical_modules = qw(
    PDF::API2
    PDF::TextBlock
    GD::Text
    Catalyst::Runtime
    DBIx::Class
    Template
);

foreach my $module (@critical_modules) {
    if (!module_installed($module)) {
        print "$module not found. Installing...\n";
        install_perl_module($module, 1);
    }
}

print "Dependency check completed.\n";
exit 0;