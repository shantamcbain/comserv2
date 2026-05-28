#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib $ENV{CATALYST_HOME} ? "$ENV{CATALYST_HOME}/lib" : "$FindBin::Bin/../lib";
use lib $ENV{CATALYST_HOME} ? $ENV{CATALYST_HOME} : "$FindBin::Bin/..";

use Comserv;
use Plack::Builder;

my $app = Comserv->psgi_app;

my $wrapped = builder {
    enable 'ReverseProxy';
    $app;
};

return $wrapped;
