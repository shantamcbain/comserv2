use strict;
use warnings;
use Test::More;


use Catalyst::Test 'Comserv';
use Comserv::Controller::ENCY;

ok( request('/ency')->is_success, 'Request should succeed' );
done_testing();
