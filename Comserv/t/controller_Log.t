use strict;
use warnings;
use Test::More;


use Catalyst::Test 'Comserv';
use Comserv::Controller::Log;

ok( request('/log')->is_success, 'Request should succeed' );
done_testing();
