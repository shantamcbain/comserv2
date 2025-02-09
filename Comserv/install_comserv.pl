#!/usr/bin/env perl

use strict;
use warnings;
use feature 'say';
use JSON;
BEGIN {
    # Try loading Term::ReadKey
    eval { require Term::ReadKey; Term::ReadKey->import(); 1 } or do {
        say "[INFO] Missing module 'Term::ReadKey'. Attempting to install it now.";
        my $install_cmd = "cpan Term::ReadKey";

        if ($ENV{PERLBREW_PERL}) {
            # Use cpanm if available in the perlbrew environment
            $install_cmd = "cpanm Term::ReadKey" if `which cpanm` =~ /cpanm/;
        } elsif (`which cpanminus`) {
            $install_cmd = "cpanminus Term::ReadKey";
        }

        system($install_cmd) == 0 or die "[ERROR] Unable to install Term::ReadKey. Install it manually and rerun the script.";
        require Term::ReadKey;
        Term::ReadKey->import();
    };
};
# Define the required Perl version
my $required_perl_version = "perl-5.40.0";

# Prompt user for confirmation
sub prompt_user {
    my ($message) = @_;
    say "$message [y/n]";
    my $response = <STDIN>;
    chomp $response;
    while ($response !~ /^[yn]$/i) {
        say "Please answer with 'y' or 'n'.";
        say "$message [y/n]";
        $response = <STDIN>;
        chomp $response;
    }
    return $response =~ /^y$/i;
}

# Step 1: Check for and install system requirements
sub check_system_requirements {
    say "[INFO] Checking system requirements...";

    my %required_packages;
    my $install_cmd;

    # Determine the correct package manager and required packages
    if (-e '/etc/debian_version') {
        %required_packages = (
            'libdbd-mysql-perl' => 'DBD::mysql',
            'libmysqlclient-dev' => 'MySQL development files',
            'libssl-dev' => 'OpenSSL development files',
            'build-essential' => 'Build tools'
        );
        $install_cmd = 'sudo apt-get install -y';
    } elsif (-e '/etc/redhat-release') {
        %required_packages = (
            'perl-DBD-MySQL' => 'DBD::mysql',
            'mysql-devel' => 'MySQL development files',
            'openssl-devel' => 'OpenSSL development files',
            'gcc' => 'C compiler',
            'make' => 'Make utility'
        );
        $install_cmd = 'sudo yum install -y';
    } else {
        say "[ERROR] Unsupported operating system. Exiting.";
        exit(1);
    }

    # Check for missing packages
    my @missing_packages;
    for my $pkg (keys %required_packages) {
        my $check = system("dpkg -l $pkg >/dev/null 2>&1") == 0 ||
            system("rpm -q $pkg >/dev/null 2>&1") == 0;
        if (!$check) {
            push @missing_packages, $pkg;
        }
    }

    # Prompt user to install missing system packages
    if (@missing_packages) {
        say "[WARN] Missing system packages:";
        for my $pkg (@missing_packages) {
            say "  - $pkg ($required_packages{$pkg})";
        }

        if (prompt_user("Would you like to install them now?")) {
            my $pkg_list = join(" ", @missing_packages);
            my $install_result = system("$install_cmd $pkg_list");
            if ($install_result != 0) {
                say "[ERROR] Failed to install some system packages.";
                exit(1);
            }
            say "[SUCCESS] All missing system packages installed.";
        } else {
            say "[ERROR] Missing required system packages. Please install them manually.";
            exit(1);
        }
    } else {
        say "[INFO] All required system packages are installed.";
    }

    # Verify Perl-level dependencies (e.g., ensure the `DBD::mysql` module is installed)
    if (!check_perl_module_installed("DBD::mysql")) {
        say "[ERROR] Missing essential Perl module: DBD::mysql. Please install it via cpanm.";
        retry_dbd_mysql_install();
    }
}

# Step 2: Ensure `perlbrew` is installed
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

# Step 3: Ensure the required Perl version is installed
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
sub install_mysql_dependencies {
    say "[INFO] Checking for system libraries required by DBD::mysql...";

    # Define library requirements based on OS
    my ($mysql_dev_package, $install_cmd);
    if (-e '/etc/debian_version') {
        $mysql_dev_package = 'libmysqlclient-dev';
        $install_cmd = "sudo apt-get install -y $mysql_dev_package";
    } elsif (-e '/etc/redhat-release') {
        $mysql_dev_package = 'mysql-devel';
        $install_cmd = "sudo yum install -y $mysql_dev_package";
    } else {
        say "[ERROR] Unsupported operating system. Please manually install the MySQL development package.";
        exit(1);
    }

    # Check if the development library is installed
    my $is_installed = system("dpkg -l $mysql_dev_package >/dev/null 2>&1") == 0 ||
        system("rpm -q $mysql_dev_package >/dev/null 2>&1") == 0;

    # Install if missing, fallback to user instructions if sudo is unavailable
    if (!$is_installed) {
        say "[WARN] The required package $mysql_dev_package is missing.";
        if (prompt_user("Would you like to install it now?")) {
            my $install_result = system($install_cmd);
            if ($install_result != 0) {
                say "[ERROR] Failed to install $mysql_dev_package. Please manually install it or confirm you have sudo/root access.";
                provide_non_root_install_instructions();
                exit(1);
            }
            say "[SUCCESS] Successfully installed $mysql_dev_package.";
        } else {
            say "[ERROR] The package $mysql_dev_package is required but could not be installed.";
            provide_non_root_install_instructions();
            exit(1);
        }
    } else {
        say "[INFO] System MySQL development files are already installed.";
    }
}

sub provide_non_root_install_instructions {
    say "[INFO] To install the required MySQL development libraries (if you don’t have root access):";
    say "  - Contact your system administrator to install the library $mysql_dev_package.";
    say "  - Alternatively, you can build MySQL development libraries in your home directory.";
    say "Visit https://dev.mysql.com/downloads/ for more details on installing MySQL libraries without root access.";
}
# Step 4: Install dependencies from `cpanfile`
sub install_dependencies {
    say "[INFO] Installing dependencies from cpanfile...";

    # Check if cpanfile exists
    if (!-e "cpanfile") {
        say "[WARN] No cpanfile found in the current directory. Skipping dependency installation.";
        return;
    }

    # Install cpanm (if needed)
    my $cpanm_path = `which cpanm`;
    chomp $cpanm_path;

    if (!$cpanm_path) {
        say "[INFO] Installing cpanm using perlbrew...";
        my $install_result = system("perlbrew install-cpanm");
        if ($install_result != 0) {
            say "[ERROR] Failed to install cpanm. Please install it manually.";
            exit(1);
        }
        say "[SUCCESS] cpanm installed successfully.";
    }

    # Install perl modules from cpanfile
    my $install_result = system("cpanm --installdeps .");
    if ($install_result != 0) {
        say "[ERROR] Failed to install one or more dependencies from cpanfile.";
        # Attempt to install DBD::mysql separately if it might be missing
        retry_dbd_mysql_install();
        return;
    }

    # Confirm DBD::mysql is installed
    if (!check_perl_module_installed("DBD::mysql")) {
        say "[ERROR] DBD::mysql is still missing after installing dependencies from cpanfile.";
        retry_dbd_mysql_install();
        exit(1);
    }

    say "[SUCCESS] Dependencies installed successfully.";
}

# Retry installation of DBD::mysql if it fails earlier
sub retry_dbd_mysql_install {
    say "[INFO] Attempting to install DBD::mysql modules directly...";
    if (system("cpanm DBD::mysql") != 0) {
        say "[ERROR] Failed to install DBD::mysql. It might require additional system packages.";
        exit(1);
    }
    say "[SUCCESS] DBD::mysql installed successfully.";
}

# Function to confirm if a Perl module is available
sub check_perl_module_installed {
    my ($module) = @_;
    eval "use $module";
    return $@ ? 0 : 1; # Return 0 if there's an error (module not installed), 1 otherwise
}

# Step 5: Setup database configuration and save to JSON
sub setup_db_config {
    say "[INFO] Starting database configuration setup...";

    my $config_file = "db_config.json";
    my $config = {};

    if (-e $config_file && !prompt_user("[WARN] db_config.json already exists. Overwrite?")) {
        say "[INFO] Skipping database configuration setup.";
        return;
    }

    while (1) {
        # Prompt user for database information
        say "Enter database name:";
        my $db_name = <STDIN>; chomp $db_name;
        say "Enter database host:";
        my $db_host = <STDIN>; chomp $db_host;
        say "Enter database port:";
        my $db_port = <STDIN>; chomp $db_port;
        say "Enter database username:";
        my $db_user = <STDIN>; chomp $db_user;
        say "Enter database password:";
        ReadMode('noecho');
        my $db_pass = <STDIN>; chomp $db_pass;
        ReadMode('restore');
        say "";

        $config->{$db_name} = { host => $db_host, port => $db_port, user => $db_user, pass => $db_pass };

        last unless prompt_user("Add another database?");
    }

    open my $fh, '>', $config_file or die "[ERROR] Could not write to $config_file: $!";
    print $fh to_json($config, { pretty => 1 });
    close $fh;

    say "[SUCCESS] Database configuration saved.";
}

# Main script execution
sub main {
    # Step 1: Ensure system requirements are met
    check_system_requirements() or exit(1);

    # Step 2: Install perlbrew
    install_perlbrew();

    # Step 3: Install the required Perl version
    install_perl_version();

    # Step 4: Install dependencies
    install_dependencies();

    # Step 5: Configure database setup
    setup_db_config();

    say "[SUCCESS] Script completed successfully.";
}

main();