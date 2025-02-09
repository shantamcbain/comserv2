#!/usr/bin/env perl

use strict;
use warnings;
use feature 'say';
use JSON;    # For creating the db_config.json file

# Define the required Perl version
my $required_perl_version = "perl-5.40.0";

# Prompt user for confirmation before proceeding with a step
sub prompt_user {
    my ($message) = @_;
    say "$message [y/n]";
    my $response = <STDIN>;
    chomp $response;
    return $response =~ /^y$/i;
}

# Step 1: Ensure `perlbrew` is installed
sub install_perlbrew {
    say "[INFO] Checking if perlbrew is installed...";
    my $perlbrew_path = `which perlbrew`;
    chomp $perlbrew_path;

    if (!$perlbrew_path) {
        if (prompt_user("[WARN] Perlbrew is not installed. Would you like to install it now?")) {
            say "[INFO] Installing perlbrew...";
            my $install_result = system("curl -L https://install.perlbrew.pl | bash");

            if ($install_result != 0) {
                say "[ERROR] Failed to install perlbrew. Please install it manually.";
                say "Visit https://perlbrew.pl for detailed instructions.";
                exit(1);
            }

            say "[INFO] Adding perlbrew to your shell configuration...";
            my $bashrc = "$ENV{HOME}/.bashrc";
            my $zshrc  = "$ENV{HOME}/.zshrc";

            if (-e $bashrc) {
                system("echo '\\nsource ~/perl5/perlbrew/etc/bashrc' >> $bashrc");
                say "[SUCCESS] Perlbrew added to your ~/.bashrc.";
            } elsif (-e $zshrc) {
                system("echo '\\nsource ~/perl5/perlbrew/etc/bashrc' >> $zshrc");
                say "[SUCCESS] Perlbrew added to your ~/.zshrc.";
            } else {
                say "[WARN] Could not detect a shell configuration file. Add this manually to your shell config:\n";
                say "  source ~/perl5/perlbrew/etc/bashrc";
            }

            say "[INFO] Please reload your shell or restart your terminal to activate perlbrew.";
            say "[INFO] Once reloaded, re-run this script to continue.";
            exit(0);
        } else {
            say "[ERROR] Perlbrew is required to proceed. Exiting.";
            exit(1);
        }
    }

    say "[SUCCESS] Perlbrew is installed.";
}

# Step 2: Ensure the required Perl version is installed
sub install_perl_version {
    say "[INFO] Checking if Perl $required_perl_version is installed via perlbrew...";
    my $perl_installed = `perlbrew list | grep $required_perl_version`;

    if (!$perl_installed) {
        if (prompt_user("[WARN] Perl $required_perl_version is not installed. Would you like to install it now?")) {
            say "[INFO] Installing Perl $required_perl_version via perlbrew...";
            my $install_result = system("perlbrew install $required_perl_version");

            if ($install_result != 0) {
                say "[ERROR] Failed to install Perl $required_perl_version.";
                exit(1);
            }
        } else {
            say "[ERROR] Perl $required_perl_version is required to proceed. Exiting.";
            exit(1);
        }
    }

    say "[INFO] Switching to Perl $required_perl_version...";
    my $use_result = system("perlbrew use $required_perl_version");
    if ($use_result != 0) {
        say "[ERROR] Failed to switch to Perl $required_perl_version.";
        exit(1);
    }
    say "[SUCCESS] Perl $required_perl_version is ready.";
}

# Step 3: Install dependencies from `cpanfile`
sub install_dependencies {
    say "[INFO] Starting dependency installation...";

    # Check if cpanfile exists
    if (!-e "cpanfile") {
        say "[ERROR] Could not find `cpanfile` in the current directory.";
        if (prompt_user("[WARN] Would you like to proceed without installing dependencies?")) {
            say "[INFO] Skipping dependency installation.";
            return; # Exit this function but continue the script
        } else {
            say "[ERROR] Dependency installation requires `cpanfile`. Exiting.";
            exit(1); # Exit the entire script
        }
    }

    # Check if cpanm exists, and install App::cpanminus if necessary
    say "[INFO] Checking if cpanm is installed...";
    my $cpanm_path = `which cpanm`;
    chomp $cpanm_path;

    if (!$cpanm_path) {
        say "[INFO] Installing cpanm (App::cpanminus)...";
        my $install_cpanm = system("perlbrew install-cpanm");
        if ($install_cpanm != 0) {
            say "[ERROR] Failed to install cpanm. Please try installing it manually.";
            exit(1); # Exit if cpanm cannot be installed
        }
        say "[SUCCESS] cpanm installed successfully.";
    }

    # Read and process the cpanfile
    say "[INFO] Reading modules from cpanfile...";
    open my $fh, '<', 'cpanfile' or die "[ERROR] Unable to open cpanfile: $!";
    my @lines = <$fh>;
    close $fh;

    foreach my $line (@lines) {
        # Skip comments and empty lines
        next if $line =~ /^\s*#/;
        next if $line =~ /^\s*$/;

        # Extract module name and optional version
        if (my ($module, $version) = $line =~ /^\s*requires\s*['"]([^'"]+)['"]\s*(?:=>\s*['"]?([^'"]*)['"]?)?/) {
            say "[INFO] Checking if module '$module' is installed...";

            # Check if the module is already installed
            my $is_installed = eval "use $module; 1";
            if ($is_installed) {
                say "[SUCCESS] Module '$module' is already installed.";
            } else {
                say "[WARN] Module '$module' is not installed. Installing...";
                $version = $version ? " $version" : "";
                my $install_cmd = "cpanm $module$version";
                my $install_result = system($install_cmd);

                if ($install_result == 0) {
                    say "[SUCCESS] Successfully installed module '$module'.";
                } else {
                    say "[ERROR] Failed to install module '$module'. Please check for issues.";
                }
            }
        }
    }

    say "[INFO] Completed processing all modules from cpanfile.";
}

# Step 4: Create the db_config.json file
sub setup_db_config {
    say "[INFO] Starting database configuration setup...";

    my $config_file = "db_config.json";
    my $config = {};

    if (-e $config_file) {
        if (!prompt_user("[WARN] db_config.json already exists. Do you want to overwrite it?")) {
            say "[INFO] Skipping database configuration setup.";
            return;
        }
    }

    while (1) {
        say "[INFO] Add a new database configuration:";
        say "Enter a name for this database (e.g., shanta_ency, shanta_forager):";
        my $db_name = <STDIN>;
        chomp $db_name;

        say "Host (default: localhost):";
        my $host = <STDIN>;
        chomp $host;
        $host ||= "localhost";

        say "Port (default: 3306):";
        my $port = <STDIN>;
        chomp $port;
        $port ||= 3306;

        say "Username:";
        my $username = <STDIN>;
        chomp $username;

        say "Password:";
        my $password = <STDIN>;
        chomp $password;

        say "Database name:";
        my $database = <STDIN>;
        chomp $database;

        $config->{$db_name} = {
            host     => $host,
            port     => $port,
            username => $username,
            password => $password,
            database => $database
        };

        if (!prompt_user("[INFO] Would you like to add another database?")) {
            last;
        }
    }

    open my $out, '>', $config_file or die "[ERROR] Could not create db_config.json: $!";
    print $out to_json($config, { pretty => 1 });
    close $out;

    say "[SUCCESS] Database configuration saved to db_config.json.";
}

# Step 5: Start comserv_server.pl in debug mode
sub start_comserv_server {
    if (prompt_user("[INFO] Would you like to start comserv_server.pl in debug mode with auto-restart?")) {
        say "[INFO] Starting comserv_server.pl in debug mode...";
        exec("plackup -r comserv_server.pl --env development --restart");
    } else {
        say "[INFO] comserv_server.pl was not started. You can start it manually when ready.";
    }
}

# Main execution flow
install_perlbrew();        # Step 1: Ensure perlbrew exists
if (prompt_user("Proceed to install Perl $required_perl_version?")) {
    install_perl_version();    # Step 2: Ensure the correct Perl version is installed and active
}
if (prompt_user("Proceed to check/install modules from cpanfile?")) {
    install_dependencies();    # Step 3: Install dependencies from cpanfile
}
if (prompt_user("Proceed to set up the database configuration file (db_config.json)?")) {
    setup_db_config();         # Step 4: Create db_config.json
}
if (prompt_user("Proceed to start comserv_server.pl in debug mode?")) {
    start_comserv_server();    # Step 5: Start comserv_server.pl in debug mode
}

say "[SUCCESS] All steps completed.";