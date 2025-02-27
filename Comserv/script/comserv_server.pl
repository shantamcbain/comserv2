#!/usr/bin/env perl

use FindBin;

BEGIN {
    $ENV{CATALYST_SCRIPT_GEN} = 40;

    # Install local::lib if not already installed
    eval { require local::lib; }; # Check if local::lib is loaded
    if ($@) { # $@ contains error message if require failed
        system("perlbrew exec cpanm local::lib") == 0
            or die "Failed to install local::lib using perlbrew. Please install it manually.\n";

        # Reload the environment to activate the newly installed local::lib
        exec($^X, $0, @ARGV);
        exit; # This line is technically redundant but good practice
    }

    # Set up local::lib for local installations (NOW after the exec check)
    use local::lib "../local";
    use lib "$FindBin::Bin/../local/lib/perl5";
    $ENV{PERL5LIB} = "$FindBin::Bin/../local/lib/perl5:$ENV{PERL5LIB}";
    $ENV{PATH} = "$FindBin::Bin/../local/bin:$ENV{PATH}";
}


# Automatically install dependencies locally
system("cpanm --local-lib=local --installdeps .") == 0
    or warn "Some dependencies may not have been installed. Check your cpanfile.\n";

use Catalyst::ScriptRunner;
Catalyst::ScriptRunner->run('Comserv', 'Server');

1;

# ... (rest of your POD documentation)