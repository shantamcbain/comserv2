#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Comserv;
use Plack::Builder;

my $app = Comserv->psgi_app;

my $wrapped = builder {
    enable 'ReverseProxy';
    $app;
};

return $wrapped;
