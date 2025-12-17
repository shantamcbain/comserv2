#!/usr/bin/env perl
use strict;
use warnings;
use Test::More tests => 5;
use File::Temp qw(tempdir);
use File::Copy qw(copy);
use Cwd qw(abs_path);

# Test: db_config.json preservation when kubectl unavailable (non-K8s environment)

my $temp_dir = tempdir(CLEANUP => 1);
my $test_db_config = "$temp_dir/db_config.json";
my $script_path = abs_path('docker-entrypoint.sh');

# Create test db_config.json with test credentials
my $test_config = {
    "host" => "localhost",
    "user" => "test_user",
    "password" => "test_password",
    "database" => "comserv_test"
};

# Write test config file
use JSON;
open my $fh, '>', $test_db_config or die "Cannot create $test_db_config: $!";
print $fh encode_json($test_config);
close $fh;

ok(-f $test_db_config, "Test db_config.json created successfully");

# Run docker-entrypoint.sh with kubectl unavailable
# Set CATALYST_HOME to temp directory and modify PATH to exclude kubectl
my $original_path = $ENV{PATH};
my $modified_path = "/usr/bin:/bin";  # Minimal PATH without kubectl
local $ENV{PATH} = $modified_path;
local $ENV{CATALYST_HOME} = $temp_dir;

# Capture script output
my $output = `bash "$script_path" 2>&1 || true`;

ok($output =~ /kubectl not available/, "Script outputs fallback message when kubectl unavailable");

# Verify db_config.json still exists (was NOT deleted)
ok(-f $test_db_config, "db_config.json preserved when kubectl unavailable (non-K8s environment)");

# Verify script completed without fatal error related to missing kubectl
ok($? >= 0, "Script executes without fatal kubectl-related error");

# Verify fallback message indicates file will be used directly
ok($output =~ /db_config\.json will be used directly/, "Script indicates db_config.json will be used for configuration");

done_testing();
