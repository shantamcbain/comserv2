#!/usr/bin/env perl

    use FindBin;

    BEGIN {
        $ENV{CATALYST_SCRIPT_GEN} = 40;
        $ENV{CATALYST_DEBUG} = 1;  # Enable debug mode

        # Add the lib directory to @INC
        use FindBin;
        use lib "$FindBin::Bin/../lib";
        use lib "$FindBin::Bin/..";

        # Install local::lib if not already installed
        eval { require local::lib; };
        if ($@) {
            system("perlbrew exec cpanm local::lib") == 0
                or die "Failed to install local::lib using perlbrew: $!\n";
            exec($^X, $0, @ARGV);
            exit;
        }

        # Set up local::lib
        use local::lib "../local";
        use lib "$FindBin::Bin/../local/lib/perl5";
        $ENV{PERL5LIB} = "$FindBin::Bin/../local/lib/perl5:$ENV{PERL5LIB}";
        $ENV{PATH} = "$FindBin::Bin/../local/bin:$ENV{PATH}";
    }

    # Install required Catalyst modules
    my @required_modules = qw(
        Catalyst::Runtime
        Catalyst::ScriptRunner
        Catalyst::Devel
    );

    foreach my $module (@required_modules) {
        system("cpanm --local-lib=../local $module") == 0
            or warn "Failed to install $module: $!\n";
    }

    # Install project dependencies
    system("cpanm --local-lib=../local --installdeps .") == 0
        or warn "Some dependencies may not have been installed\n";

    # Add setup mode handling
    use strict;
    use warnings;

    eval {
        require Catalyst::ScriptRunner;
        # Initialize setup mode if requested
        if ($ENV{SETUP_MODE}) {
            require Comserv::Controller::Setup;
            my $setup = Comserv::Controller::Setup->new();
            print "Entering setup mode...\n";
            $setup->index();
        }
        Catalyst::ScriptRunner->run('Comserv', 'Server');
    };
    if ($@) {
        die "Failed to start server: $@\n";
    }

    1;