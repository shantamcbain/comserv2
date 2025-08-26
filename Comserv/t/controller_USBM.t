use strict;
use warnings;
use Test::More;


use Catalyst::Test 'Comserv';
use Comserv::Controller::USBM;

ok( request('/usbm')->is_success, 'Request should succeed' );
done_testing();
