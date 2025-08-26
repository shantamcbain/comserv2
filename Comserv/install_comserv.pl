#!/usr/bin/env perl

use strict;
use warnings;
use feature 'say';

# Function to execute shell commands and capture errors
sub shell_exec {
    my ($command) = @_;
    say "[INFO] Executing command: $command";

    # Execute the command directly
    my $exit_status = system($command);

    # Check the exit status of the command
    if ($exit_status != 0) {
        say "[ERROR] Command failed with exit code: " . ($exit_status >> 8);
        exit(1);
    }

    say "[SUCCESS] Command executed successfully.";
}

# Step 1: Install Perlbrew if not installed
sub install_perlbrew {
    say "[INFO] Checking if perlbrew is installed...";
    my $perlbrew_path = `which perlbrew`;
    chomp $perlbrew_path;

    if (!$perlbrew_path) {
        say "[INFO] Perlbrew is not installed.";
        say "[INFO] Installing perlbrew...";
        my $install_result = system("curl -L https://install.perlbrew.pl | bash");
        if ($install_result != 0) {
            say "[ERROR] Failed to install perlbrew. Please install it manually.";
            exit(1);
        }
        say "[SUCCESS] Perlbrew installed successfully.";
    } else {
        say "[SUCCESS] Perlbrew is already installed.";
    }
}

# Step 2: Install the required Perl version
sub install_perl_version {
    my $required_perl_version = "perl-5.40.0";
    say "[INFO] Checking if Perl $required_perl_version is installed via perlbrew...";
    my $perl_installed = `perlbrew list | grep $required_perl_version`;

    if (!$perl_installed) {
        say "[INFO] Installing Perl $required_perl_version via perlbrew...";
        my $install_result = system("perlbrew install $required_perl_version");
        if ($install_result != 0) {
            say "[ERROR] Failed to install Perl $required_perl_version.";
            exit(1);
        }
        say "[SUCCESS] Perl $required_perl_version installed successfully.";
    } else {
        say "[SUCCESS] Perl $required_perl_version is already installed.";
    }

    # Set environment variables for perlbrew without launching a subshell
    $ENV{PERLBREW_ROOT} = "$ENV{HOME}/perl5/perlbrew";
    $ENV{PERLBREW_HOME} = "$ENV{HOME}/.perlbrew";
    $ENV{PATH} = "$ENV{PERLBREW_ROOT}/bin:$ENV{PERLBREW_ROOT}/perls/$required_perl_version/bin:$ENV{PATH}";
}

# Step 3: Install dependencies from cpanfile
sub install_dependencies {
    say "[INFO] Installing dependencies from cpanfile...";
    my $install_result = system("cpanm --installdeps .");
    if ($install_result != 0) {
        say "[ERROR] Failed to install one or more dependencies from cpanfile.";
        exit(1);
    }
    say "[SUCCESS] Dependencies installed successfully.";
}

# Main script execution
sub main {
    my $options = ['setup'];  # Add 'setup' to options to indicate setup mode

    install_perlbrew();
    install_perl_version();
    install_dependencies();

    # Construct the command with CATALYST_DEBUG and setup mode
    my $command = 'CATALYST_DEBUG=1 script/comserv_server.pl'
        . (@$options ? ' -d ' . join(' ', @$options) : '')
        . ' -r';

    shell_exec($command);
}

main();
