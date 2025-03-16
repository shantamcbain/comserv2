#!/usr/bin/env perl

use FindBin;

BEGIN {
    $ENV{CATALYST_SCRIPT_GEN} = 40;

    # Add the lib directory to @INC
    use FindBin;
    use lib "$FindBin::Bin/../lib";
    use lib "$FindBin::Bin/..";

    # Install local::lib if not already installed
    eval { require local::lib; }; # Check if local::lib is loaded
    if ($@) { # $@ contains error message if require failed
        system("cpanm local::lib") == 0
            or die "Failed to install local::lib. Please install it manually with: cpanm local::lib\n";

        # Reload the environment to activate the newly installed local::lib
        exec($^X, $0, @ARGV);
        exit; # This line is technically redundant but good practice
    }

    # Set up local::lib for local installations
    use local::lib "$FindBin::Bin/../local";
    use lib "$FindBin::Bin/../local/lib/perl5";
    $ENV{PERL5LIB} = "$FindBin::Bin/../local/lib/perl5:$ENV{PERL5LIB}";
    $ENV{PATH} = "$FindBin::Bin/../local/bin:$ENV{PATH}";
}

# Ensure the local directory exists
unless (-d "$FindBin::Bin/../local") {
    mkdir "$FindBin::Bin/../local" or die "Could not create local directory: $!";
}

# Automatically install dependencies locally
print "Installing dependencies from cpanfile...\n";
my $cpanfile_path = "$FindBin::Bin/../cpanfile";
if (-e $cpanfile_path) {
    print "Found cpanfile at: $cpanfile_path\n";
    system("cpanm --local-lib=$FindBin::Bin/../local --installdeps $FindBin::Bin/..") == 0
        or warn "Some dependencies may not have been installed. Check your cpanfile.\n";
} else {
    warn "cpanfile not found at $cpanfile_path. Skipping dependency installation.\n";
}

# Specifically install Catalyst::ScriptRunner if not already installed
eval { require Catalyst::ScriptRunner; };
if ($@) {
    print "Installing Catalyst::ScriptRunner...\n";
    my $result = system("cpanm --local-lib=$FindBin::Bin/../local Catalyst::ScriptRunner");

    if ($result != 0) {
        die "Failed to install Catalyst::ScriptRunner. Please install it manually with: cpanm --local-lib=$FindBin::Bin/../local Catalyst::ScriptRunner\n";
    }

    # Add the newly installed module's path to @INC
    unshift @INC, "$FindBin::Bin/../local/lib/perl5";

    # Restart the script to ensure the newly installed module is properly loaded
    print "Restarting script to load the newly installed module...\n";
    exec($^X, $0, @ARGV);
    exit;
}

# Now try to use Catalyst::ScriptRunner
eval {
    require Catalyst::ScriptRunner;
    Catalyst::ScriptRunner->import();
};
if ($@) {
    die "Failed to load Catalyst::ScriptRunner even after installation: $@\nPlease install it manually.\n";
}

Catalyst::ScriptRunner->run('Comserv', 'Server');

1;

# ... (rest of your POD documentation)