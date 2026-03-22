#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";

# Load the Catalyst application
use Comserv;

# Return the PSGI app for Starman/Plack
my $app = Comserv->psgi_app;

# Optional: enable common middleware here if needed in future
# use Plack::Builder;
# my $wrapped = builder {
#     enable 'AccessLog';
#     enable 'ContentLength';
#     $app;
# };
# return $wrapped;

return $app;
