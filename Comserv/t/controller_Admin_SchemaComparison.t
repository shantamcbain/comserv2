#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;
use FindBin;

# Test that the Admin controller and SchemaComparison controller load successfully
# and follow standard patterns.

BEGIN {
    use_ok('Comserv::Controller::Admin');
    use_ok('Comserv::Controller::Admin::SchemaComparison');
}

subtest 'Admin controller loads successfully' => sub {
    my $controller = Comserv::Controller::Admin->new();
    isa_ok($controller, 'Comserv::Controller::Admin');
    can_ok($controller, qw(get_database_comparison schema_compare));
};

subtest 'SchemaComparison controller loads successfully' => sub {
    my $controller = Comserv::Controller::Admin::SchemaComparison->new();
    isa_ok($controller, 'Comserv::Controller::Admin::SchemaComparison');
    can_ok($controller, qw(sync_table_to_result create_table_from_result));
};

subtest 'controller does not access db_config.json directly' => sub {
    # This test verifies that the controller code doesn't attempt to read
    # db_config.json directly during the HTTP request handling
    
    # Read the Admin controller source code
    my $controller_file = "$FindBin::Bin/../lib/Comserv/Controller/Admin.pm";
    open(my $fh, '<', $controller_file) or die "Cannot open controller file $controller_file: $!";
    my $source_code = do { local $/; <$fh> };
    close($fh);
    
    # Verify no direct RemoteDB instantiation in get_database_comparison
    my ($get_db_comparison_method) = $source_code =~ /sub get_database_comparison \{(.*?)\n^\}/ms;
    ok($get_db_comparison_method, 'get_database_comparison method found in source');
    
    # Check that the method doesn't contain RemoteDB instantiation
    unlike($get_db_comparison_method, qr/RemoteDB->new/, 'get_database_comparison does not create RemoteDB instances');
    unlike($get_db_comparison_method, qr/db_config\.json/, 'get_database_comparison does not reference db_config.json');
};

done_testing();
