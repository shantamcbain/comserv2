use strict;
use warnings;
use Test::More;


use Catalyst::Test 'Comserv';
use Comserv::Controller::CSC;

ok( request('/csc')->is_success, 'Request should succeed' );
done_testing();
