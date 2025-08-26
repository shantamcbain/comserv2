use strict;
use warnings;
use Test::More;

use Catalyst::Test 'Comserv';
use Comserv::Controller::ApiCredentials;

# Test that the controller exists
ok( request('/ApiCredentials')->is_redirect || request('/ApiCredentials')->is_success, 'Request to /ApiCredentials should work' );

# Test that the controller responds to the correct URL
my $response = request('/ApiCredentials');
ok( $response->is_redirect || $response->is_success, 'Request should be handled' );

done_testing();