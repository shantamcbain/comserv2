use FindBin;
use lib "$FindBin::Bin/home/shanta/public_html/catalyst/Comserv/lib";
use strict;
use warnings;

use Comserv;

my $app = Comserv->apply_default_middlewares(Comserv->psgi_app);