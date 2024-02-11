use strict;
use warnings;

use Comserv;

my $app = Comserv->apply_default_middlewares(Comserv->psgi_app);
$app;

