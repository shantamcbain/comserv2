#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;

use Catalyst::Test 'Comserv';

# Declare the $response variable and make a request to the root path
my $response = request('/');

# Check if the request is successful
ok( $response->is_success, 'Request should succeed' );

# Check if the session variable 'group' is set to 'normal'
is( $response->header('X-Session-Group'), 'normal', 'Session variable group should be set to normal' );

done_testing();