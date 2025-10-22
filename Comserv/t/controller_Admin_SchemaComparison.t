#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;

# Test that the SchemaComparison controller uses existing model connections
# instead of trying to access db_config.json directly at runtime

BEGIN {
    use_ok('Comserv::Controller::Admin::SchemaComparison');
}

subtest 'SchemaComparison controller loads successfully' => sub {
    my $controller = Comserv::Controller::Admin::SchemaComparison->new();
    isa_ok($controller, 'Comserv::Controller::Admin::SchemaComparison');
    can_ok($controller, qw(get_database_comparison transform_comparison_data_for_template));
};

subtest 'transform_comparison_data_for_template method' => sub {
    my $controller = Comserv::Controller::Admin::SchemaComparison->new();
    
    # Create test comparison data
    my $comparison_data = {
        databases => {
            ency => {
                connected => 1,
                display_name => 'Ency Database',
                table_count => 3,
                tables => [
                    { name => 'users', database => 'ency', has_result_file => 0 },
                    { name => 'projects', database => 'ency', has_result_file => 1 },
                ],
                connection_info => { host => 'localhost', port => 3306 }
            },
            forager => {
                connected => 0,
                display_name => 'Forager Database',
                error => 'Connection failed: timeout',
                table_count => 0,
                tables => []
            }
        }
    };
    
    my $result = $controller->transform_comparison_data_for_template($comparison_data);
    
    # Verify structure
    ok($result, 'Template data is returned');
    isa_ok($result, 'HASH', 'Template data is a hash reference');
    
    # Check ency transformation
    ok(exists $result->{ency}, 'ency key exists in template data');
    is($result->{ency}->{connection_status}, 'connected', 'ency connection status is correct');
    is($result->{ency}->{display_name}, 'Ency Database', 'ency display name is correct');
    is($result->{ency}->{table_count}, 3, 'ency table count is correct');
    is($result->{ency}->{error}, '', 'ency error is empty for successful connection');
    is(scalar(@{$result->{ency}->{table_comparisons}}), 2, 'ency has correct number of tables');
    
    # Check forager transformation
    ok(exists $result->{forager}, 'forager key exists in template data');
    is($result->{forager}->{connection_status}, 'disconnected', 'forager connection status is correct');
    is($result->{forager}->{display_name}, 'Forager Database', 'forager display name is correct');
    is($result->{forager}->{table_count}, 0, 'forager table count is correct');
    is($result->{forager}->{error}, 'Connection failed: timeout', 'forager error is preserved');
    is(scalar(@{$result->{forager}->{table_comparisons}}), 0, 'forager has no tables');
};

subtest 'controller does not access db_config.json directly' => sub {
    # This test verifies that the controller code doesn't attempt to read
    # db_config.json directly during the HTTP request handling
    
    my $controller = Comserv::Controller::Admin::SchemaComparison->new();
    
    # Check controller source for any direct file access
    # This is a meta-test to ensure our fix is properly implemented
    
    # Read the controller source code
    my $controller_file = '/home/shanta/PycharmProjects/comserv2/Comserv/lib/Comserv/Controller/Admin/SchemaComparison.pm';
    open(my $fh, '<', $controller_file) or die "Cannot open controller file: $!";
    my $source_code = do { local $/; <$fh> };
    close($fh);
    
    # Verify no direct RemoteDB instantiation in get_database_comparison
    my ($get_db_comparison_method) = $source_code =~ /sub get_database_comparison \{(.*?)\n^\}/ms;
    ok($get_db_comparison_method, 'get_database_comparison method found in source');
    
    # Check that the method doesn't contain RemoteDB instantiation
    unlike($get_db_comparison_method, qr/RemoteDB->new/, 'get_database_comparison does not create RemoteDB instances');
    unlike($get_db_comparison_method, qr/db_config\.json/, 'get_database_comparison does not reference db_config.json');
    
    # Check that it uses proper model calls
    like($get_db_comparison_method, qr/\$c->model\('DBEncy'\)/, 'get_database_comparison uses DBEncy model');
    like($get_db_comparison_method, qr/\$c->model\('DBForager'\)/, 'get_database_comparison uses DBForager model');
    like($get_db_comparison_method, qr/->list_tables\(\)/, 'get_database_comparison calls list_tables method');
    like($get_db_comparison_method, qr/->get_startup_connection_info\(\)/, 'get_database_comparison calls get_startup_connection_info method');
};

done_testing();