use strict;
use warnings;
use Test::More;


use Catalyst::Test 'Comserv';
use Comserv::Controller::Base;

ok( request('/base')->is_success, 'Request should succeed' );
done_testing();
