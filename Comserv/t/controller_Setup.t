use strict;
use warnings;
use Test::More;


use Catalyst::Test 'Comserv';
use Comserv::Controller::Setup;

ok( request('/setup')->is_success, 'Request should succeed' );
done_testing();
