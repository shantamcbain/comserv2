use strict;
use warnings;
use Test::More;


use Catalyst::Test 'Comserv';
use Comserv::Controller::AI;

ok( request('/ai')->is_success, 'Request should succeed' );
done_testing();
