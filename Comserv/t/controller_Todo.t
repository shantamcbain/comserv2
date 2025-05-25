use strict;
use warnings;
use Test::More;


use Catalyst::Test 'Comserv';
use Comserv::Controller::Todo;

ok( request('/todo')->is_success, 'Request should succeed' );
done_testing();
