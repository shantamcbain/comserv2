#!/usr/bin/env perl

BEGIN {
    $ENV{CATALYST_SCRIPT_GEN} = 40;

    # Set up local::lib for local installations
    use FindBin;
    use local::lib "$FindBin::Bin/../local";

    # Add local lib to @INC to ensure Perl can find modules
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

=head1 NAME

comserv_server.pl - Catalyst Test Server

=head1 SYNOPSIS

comserv_server.pl [options]

=head1 DESCRIPTION

Run a Catalyst Testserver for this application.

=head1 AUTHORS

Catalyst Contributors, see Catalyst.pm

=head1 COPYRIGHT

This library is free software. You can redistribute it and/or modify
it under the same terms as Perl itself.

=cut