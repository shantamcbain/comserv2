use strict;
use warnings;
use Test::More;


use Catalyst::Test 'Comserv';
use Comserv::Controller::MCoop;

ok( request('/mcoop')->is_success, 'Request should succeed' );
done_testing();
