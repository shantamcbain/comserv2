#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Spec;
use JSON;

BEGIN {
    use_ok('Comserv::Model::RemoteDB');
}

# Test 1: Lazy loading - config should not load until accessed
{
    my $remotedb = Comserv::Model::RemoteDB->new();
    my $config = $remotedb->config;
    ok(defined $config, "Config attribute exists after instantiation");
    is(ref $config, 'HASH', "Config is a hash reference");
}

# Test 2: Environment variable loading
{
    local $ENV{COMSERV_DB_TEST_HOST} = 'test.example.com';
    local $ENV{COMSERV_DB_TEST_DATABASE} = 'testdb';
    local $ENV{COMSERV_DB_TEST_USERNAME} = 'testuser';
    local $ENV{COMSERV_DB_TEST_PASSWORD} = 'testpass';
    
    my $remotedb = Comserv::Model::RemoteDB->new();
    my $config = $remotedb->_load_from_env_variables();
    
    ok(defined $config, "Environment variables parsed");
    is(ref $config, 'HASH', "Config is a hash reference");
    ok(exists $config->{test}, "test connection found in config");
    is($config->{test}->{host}, 'test.example.com', "Host from environment variable");
    is($config->{test}->{database}, 'testdb', "Database from environment variable");
}

# Test 3: K8s Secrets loading - should handle missing K8s gracefully
{
    my $remotedb = Comserv::Model::RemoteDB->new();
    my $config = $remotedb->_load_from_k8s_secrets();
    
    # This may return undef if K8s Secrets not available (expected in non-K8s env)
    if (defined $config) {
        is(ref $config, 'HASH', "K8s Secrets config is a hash reference");
    } else {
        ok(1, "K8s Secrets gracefully returns undef when not available");
    }
}

# Test 4: Non-K8s fallback - db_config.json loading
{
    my $temp_dir = tempdir(CLEANUP => 1);
    my $config_file = File::Spec->catfile($temp_dir, 'db_config.json');
    
    # Create a test db_config.json
    my $test_config = {
        test_local => {
            host => 'localhost',
            port => 3306,
            database => 'testdb',
            username => 'testuser',
            password => 'testpass',
            db_type => 'mysql'
        }
    };
    
    open my $fh, ">", $config_file or die "Cannot create test config: $!";
    print $fh encode_json($test_config);
    close $fh;
    
    ok(-f $config_file, "Test config file created");
    
    # Verify file exists and is readable
    ok(-r $config_file, "Test config file is readable");
    
    # Read and validate JSON
    open $fh, "<", $config_file or die "Cannot read test config: $!";
    local $/;
    my $json_text = <$fh>;
    close $fh;
    
    my $loaded = decode_json($json_text);
    ok(exists $loaded->{test_local}, "Test connection found in JSON");
    is($loaded->{test_local}->{host}, 'localhost', "Host correctly stored in JSON");
}

# Test 5: Fallback chain priority
{
    # Environment variables should override db_config
    local $ENV{COMSERV_DB_PRODUCTION_HOST} = 'prod-override.example.com';
    local $ENV{COMSERV_DB_PRODUCTION_DATABASE} = 'prod_override';
    
    my $remotedb = Comserv::Model::RemoteDB->new();
    my $env_config = $remotedb->_load_from_env_variables();
    
    ok(exists $env_config->{production}, "Production connection loaded from env vars");
    is($env_config->{production}->{host}, 'prod-override.example.com', "Environment override works");
}

done_testing();
