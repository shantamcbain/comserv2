#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;

# Set up local::lib and local paths for running under Starman/PSGI
use lib "$FindBin::Bin/../local/lib/perl5";
use Config;
BEGIN {
    my $archname = $Config{archname};
    my $version = $Config{version};
    unshift @INC, "$FindBin::Bin/../local/lib/perl5/$archname" if $archname;
    unshift @INC, "$FindBin::Bin/../local/lib/perl5/$version/$archname" if $version && $archname;
    unshift @INC, "$FindBin::Bin/../local/lib/perl5/$version" if $version;
    
    # Also add architecture specific multi-thread directories
    unshift @INC, "$FindBin::Bin/../local/lib/perl5/x86_64-linux-gnu-thread-multi";
    unshift @INC, "$FindBin::Bin/../local/lib/perl5/site_perl";
}

use lib $ENV{CATALYST_HOME} ? "$ENV{CATALYST_HOME}/lib" : "$FindBin::Bin/../lib";
use lib $ENV{CATALYST_HOME} ? $ENV{CATALYST_HOME} : "$FindBin::Bin/..";

use Comserv;
use Plack::Builder;

# Survives plackup -R restarts: marks Twiggy mode for WebSocket terminal detection.
my $_app_root = $ENV{CATALYST_HOME} ? $ENV{CATALYST_HOME} : "$FindBin::Bin/..";
if (-f "$_app_root/var/twiggy.enabled") {
    $ENV{COMSERV_TWIGGY}         = '1';
    $ENV{PLACK_SERVER_SOFTWARE} ||= 'Twiggy';
}

my $app = Comserv->psgi_app;

my $wrapped = builder {
    enable 'ReverseProxy';
    enable 'Static',
        path => qr{^/(static|root|assets)/},
        root => "$FindBin::Bin/..";
    $app;
};

return $wrapped;
