use strict;
use warnings;
use Test::More;


use Catalyst::Test 'Comserv';
use Comserv::Controller::3d;

ok( request('/3d')->is_success, 'Request should succeed' );
done_testing();
