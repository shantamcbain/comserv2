#!/usr/bin/env perl

BEGIN {
    $ENV{CATALYST_SCRIPT_GEN} = 40;

    # Ensure we're using the correct Perl version via perlbrew
    my $required_perl_version = "perl-5.40.0";
    my $current_perl = $^X;

    # Check if we're already using the correct perlbrew Perl
    if ($current_perl !~ /perlbrew.*\Q$required_perl_version\E/) {
        # Try to find and use the correct perlbrew Perl
        my $perlbrew_perl = "$ENV{HOME}/perl5/perlbrew/perls/$required_perl_version/bin/perl";

        if (-x $perlbrew_perl) {
            print "Switching to perlbrew Perl $required_perl_version...\n";
            # Re-execute with the correct Perl version
            exec($perlbrew_perl, $0, @ARGV);
            exit;
        } else {
            warn "Warning: $required_perl_version not found via perlbrew at $perlbrew_perl\n";
            warn "Please install it with: perlbrew install $required_perl_version\n";
            warn "Continuing with current Perl version, but some modules may not work correctly.\n";
        }
    }

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

    # Add architecture-specific paths early
    use Config;
    my $archname = $Config{archname};
    my $version = $Config{version};

    # Add all possible architecture paths to @INC
    use lib "$FindBin::Bin/../local/lib/perl5/$archname";
    use lib "$FindBin::Bin/../local/lib/perl5/$version/$archname";
    use lib "$FindBin::Bin/../local/lib/perl5/$version";

    # Also add the actual installed architecture path (for systems where archname differs)
    # This handles cases where the actual installed path uses a different architecture name
    my @arch_paths = (
        "$FindBin::Bin/../local/lib/perl5/x86_64-linux-gnu-thread-multi",
        "$FindBin::Bin/../local/lib/perl5/auto",
        "$FindBin::Bin/../local/lib/perl5/site_perl",
        "$FindBin::Bin/../local/lib/perl5/site_perl/$version",
        "$FindBin::Bin/../local/lib/perl5/site_perl/$version/$archname"
    );

    foreach my $path (@arch_paths) {
        if (-d $path) {
            unshift @INC, $path;
        }
    }

    # Debug: Print the paths being added
    if ($ENV{CATALYST_DEBUG}) {
        print "Debug: Adding architecture paths to \@INC:\n";
        print "  $FindBin::Bin/../local/lib/perl5/$archname\n";
        print "  $FindBin::Bin/../local/lib/perl5/$version/$archname\n";
        print "  $FindBin::Bin/../local/lib/perl5/$version\n";
        foreach my $path (@arch_paths) {
            print "  $path\n" if -d $path;
        }
    }
}

# Ensure the local directory exists
unless (-d "$FindBin::Bin/../local") {
    mkdir "$FindBin::Bin/../local" or die "Could not create local directory: $!";
}

# For Docker compatibility, dependency installation is handled during container build
# All modules are pre-installed in the Docker image via cpanm during dockerfile build
# This section has been removed for faster startup times in containerized environments

# Load Catalyst::ScriptRunner (pre-installed in Docker image)
eval {
    require Catalyst::ScriptRunner;
    Catalyst::ScriptRunner->import();
};
if ($@) {
    die "Failed to load Catalyst::ScriptRunner: $@\nPlease ensure it is installed in your environment.\n";
}

# Docker environment: All required modules are pre-installed in the container image
# Simple verification that modules are available (for debugging purposes only)
if ($ENV{CATALYST_DEBUG}) {
    my @required_modules = (
        'YAML::XS',
        'Net::CIDR',
        'Email::MIME',
        'Email::Sender::Simple',
        'Catalyst::View::Email',
        'Catalyst::View::Email::Template'
    );
    
    foreach my $module (@required_modules) {
        eval "require $module";
        if ($@) {
            warn "Warning: $module not available: $@\n";
        } else {
            print "Debug: $module loaded successfully\n";
        }
    }
}

Catalyst::ScriptRunner->run('Comserv', 'Server');

1;

=head1 NAME

comserv_server.pl - Catalyst Test Server

=head1 SYNOPSIS

comserv_server.pl [options]

   -d --debug           force debug mode
   -f --fork            handle each request in a new process
                        (defaults to false)
   -? --help            display this help and exits
   -h --host            host (defaults to all)
   -p --port            port (defaults to 3000)
   -k --keepalive       enable keep-alive connections
   -r --restart         restart when files get modified
                        (defaults to false)
   -rd --restart_delay  delay between file checks
                        (ignored if you have Linux::Inotify2 installed)
   -rr --restart_regex  regex match files that trigger
                        a restart when modified
                        (defaults to '\.yml$|\.yaml$|\.conf|\.pm$')
   --restart_directory  the directory to search for
                        modified files, can be set multiple times
                        (defaults to '[SCRIPT_DIR]/..')
   --follow_symlinks    follow symlinks in search directories
                        (defaults to false. this is a no-op on Win32)
   --background         run the process in the background
   --pidfile            specify filename for pid file

 See also:
   perldoc Catalyst::Manual
   perldoc Catalyst::Manual::Intro

=head1 DESCRIPTION

Run a Catalyst Testserver for this application.

=head1 AUTHORS

Catalyst Contributors, see Catalyst.pm

=head1 COPYRIGHT

This library is free software. You can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

