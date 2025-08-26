#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Catalyst::Test 'Comserv';
use HTTP::Request::Common;
use Data::Dumper;

print "Testing ThemeEditor controller...\n";

# Test the index action
my $response = request('/themeeditor');
print "Response code: " . $response->code . "\n";
print "Content type: " . $response->content_type . "\n";
print "Content length: " . length($response->content) . "\n";
print "Content snippet: " . substr($response->content, 0, 100) . "...\n";

# Test with debug output
my $debug_response = request('/themeeditor?debug=1');
print "Debug response code: " . $debug_response->code . "\n";
print "Debug content length: " . length($debug_response->content) . "\n";

print "Test complete.\n";