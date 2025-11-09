#!/usr/bin/env perl
=pod
=head1 NAME
detect_degradation_patterns.t - Comprehensive test harness for degradation pattern detection

=head1 DESCRIPTION
Tests all 4 scenarios from Phase 3 audit with mock data:
1. First run (missing counter file) - auto-initialization
2. JSON parsing - verify JSON::decode_json usage
3. Invalid configuration - time_window_minutes validation
4. File repeats detection - anomaly detection logic

=cut

use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use JSON;
use YAML;
use Time::HiRes qw(time);

# Locate the script under test
my $script_path = '/home/shanta/PycharmProjects/comserv2/Comserv/root/Documentation/session_history/detect_degradation_patterns.pl';

# Check if script exists
if (!-f $script_path) {
    plan skip_all => "Script not found at $script_path";
}

plan tests => 7;  # 7 subtests with internal assertions

# Create temporary test environment
my $test_dir = tempdir(CLEANUP => 1);
my $audit_log = "$test_dir/audit_log.json";
my $counter_file = "$test_dir/.prompt_counter";

# ============================================================================
# TEST 1: FIRST RUN - Counter file auto-initialization
# ============================================================================
subtest "Test 1: First Run (Missing Counter File)" => sub {
    plan tests => 5;
    
    # Ensure counter file doesn't exist
    unlink $counter_file if -f $counter_file;
    
    # Create empty audit log
    open my $fh, '>', $audit_log or die "Cannot create audit log: $!";
    close $fh;
    
    # Run script
    my $result = system("perl $script_path $audit_log $counter_file 2>/dev/null");
    is($result, 0, "Script exits successfully");
    
    # Verify counter file was created
    ok(-f $counter_file, "Counter file created");
    
    # Load and verify structure
    my $counter = YAML::LoadFile($counter_file);
    ok($counter, "Counter file contains valid YAML");
    
    # Verify default values initialized
    is($counter->{prompt_tracking}{total_prompts_limit}, 19, 
        "Default prompt limit set to 19");
    is($counter->{pattern_anomalies}{files_checked}{time_window_minutes}, 10,
        "Default time window set to 10 minutes");
};

# ============================================================================
# TEST 2: JSON PARSING - Verify JSON::decode_json is used (not YAML)
# ============================================================================
subtest "Test 2: JSON Parsing (Critical Fix #1)" => sub {
    plan tests => 6;
    
    # Create test audit log with JSON entries
    unlink $counter_file if -f $counter_file;
    
    # Write multiple JSON entries (one per line, as expected by script)
    open my $fh, '>', $audit_log or die "Cannot create audit log: $!";
    
    my $current_time = int(time());
    my @test_entries = (
        {"action" => "ViewFile", "timestamp" => $current_time, "file" => "test1.pm"},
        {"action" => "ViewFile", "timestamp" => $current_time + 1, "file" => "test1.pm"},
        {"action" => "ViewFile", "timestamp" => $current_time + 2, "file" => "test1.pm"},
    );
    
    foreach my $entry (@test_entries) {
        print $fh JSON::encode_json($entry) . "\n";
    }
    close $fh;
    
    # Run script - should NOT fail with YAML errors
    my $output = `perl $script_path $audit_log $counter_file 2>&1`;
    my $exit_code = $? >> 8;
    
    is($exit_code, 0, "Script runs without errors");
    ok($output !~ /YAML error/i, "No YAML parsing errors");
    ok(-f $counter_file, "Counter file created successfully");
    
    # Verify counter contains anomaly detection
    my $counter = YAML::LoadFile($counter_file);
    ok($counter, "Counter loaded successfully after JSON parsing");
    
    # Verify file repeats were detected (3 ViewFile for same file)
    ok(exists $counter->{current_status}{caution_reasons}, 
        "Caution reasons field exists");
    ok($counter->{current_status}{status_level} =~ /CAUTION|ALERT/,
        "Status reflects detected anomaly");
};

# ============================================================================
# TEST 3: INVALID TIME WINDOW VALIDATION
# ============================================================================
subtest "Test 3: Invalid Time Window Validation (Critical Fix #2)" => sub {
    plan tests => 5;
    
    unlink $counter_file if -f $counter_file;
    
    # First, create a valid counter
    open my $fh, '>', $audit_log or die "Cannot create audit log: $!";
    close $fh;
    
    my $result = system("perl $script_path $audit_log $counter_file 2>/dev/null");
    is($result, 0, "Initial counter creation succeeds");
    
    # Now corrupt the counter to have invalid time_window_minutes
    my $counter = YAML::LoadFile($counter_file);
    $counter->{pattern_anomalies}{files_checked}{time_window_minutes} = 0;
    YAML::DumpFile($counter_file, $counter);
    
    # Run script - should die with validation error
    my $output = `perl $script_path $audit_log $counter_file 2>&1`;
    my $exit_code = $? >> 8;
    
    isnt($exit_code, 0, "Script dies with invalid time window");
    ok($output =~ /Invalid time window/i, "Error message mentions invalid time window");
    
    # Test with negative value
    $counter->{pattern_anomalies}{files_checked}{time_window_minutes} = -5;
    YAML::DumpFile($counter_file, $counter);
    
    $output = `perl $script_path $audit_log $counter_file 2>&1`;
    $exit_code = $? >> 8;
    
    isnt($exit_code, 0, "Script dies with negative time window");
    ok($output =~ /Invalid time window/i, "Error message for negative value");
};

# ============================================================================
# TEST 4: FILE REPEATS DETECTION
# ============================================================================
subtest "Test 4: File Repeats Anomaly Detection" => sub {
    plan tests => 7;
    
    unlink $counter_file if -f $counter_file;
    
    # Create audit log with file repeat scenario
    # 3+ ViewFile entries for same file within time window
    my $current_time = int(time());
    
    open my $fh, '>', $audit_log or die "Cannot create audit log: $!";
    
    # Add 3 ViewFile entries for 'config.pm' within 10-minute window (600 seconds)
    my @entries = (
        {"action" => "ViewFile", "timestamp" => $current_time - 300, "file" => "config.pm"},
        {"action" => "ViewFile", "timestamp" => $current_time - 150, "file" => "config.pm"},
        {"action" => "ViewFile", "timestamp" => $current_time - 50, "file" => "config.pm"},
    );
    
    foreach my $entry (@entries) {
        print $fh JSON::encode_json($entry) . "\n";
    }
    close $fh;
    
    # Run script
    my $result = system("perl $script_path $audit_log $counter_file 2>/dev/null");
    is($result, 0, "Script runs successfully");
    ok(-f $counter_file, "Counter file created");
    
    # Verify anomaly was detected
    my $counter = YAML::LoadFile($counter_file);
    ok($counter, "Counter loaded successfully");
    
    # Check that status reflects anomaly
    ok($counter->{current_status}{status_level} =~ /CAUTION|ALERT/,
        "Status indicates anomaly detected");
    
    # Verify caution reasons were populated
    my $caution = $counter->{current_status}{caution_reasons};
    ok(ref($caution) eq 'ARRAY' && scalar(@$caution) > 0,
        "Caution reasons populated");
    
    # Verify caution contains file repeat message
    my $found_file_repeat = grep { $_ =~ /config\.pm|file.*repeat/i } @$caution;
    ok($found_file_repeat, "Caution includes file repeat detection");
    
    # Verify file is in restrictions
    ok(exists $counter->{current_status}{tool_restrictions},
        "Tool restrictions applied for anomaly response");
};

# ============================================================================
# TEST 5: COMMAND REPEATS DETECTION
# ============================================================================
subtest "Test 5: Command Repeats Anomaly Detection" => sub {
    plan tests => 5;
    
    unlink $counter_file if -f $counter_file;
    
    my $current_time = int(time());
    
    open my $fh, '>', $audit_log or die "Cannot create audit log: $!";
    
    # Add 3 ExecuteShellCommand entries for same command within 15-minute window
    my @entries = (
        {"action" => "ExecuteShellCommand", "timestamp" => $current_time - 400, "command" => "git status"},
        {"action" => "ExecuteShellCommand", "timestamp" => $current_time - 200, "command" => "git status"},
        {"action" => "ExecuteShellCommand", "timestamp" => $current_time - 50, "command" => "git status"},
    );
    
    foreach my $entry (@entries) {
        print $fh JSON::encode_json($entry) . "\n";
    }
    close $fh;
    
    # Run script
    my $result = system("perl $script_path $audit_log $counter_file 2>/dev/null");
    is($result, 0, "Script runs successfully");
    
    # Verify anomaly was detected
    my $counter = YAML::LoadFile($counter_file);
    ok($counter, "Counter loaded");
    
    # Status should reflect anomaly
    ok($counter->{current_status}{status_level} =~ /CAUTION|ALERT/,
        "Status indicates command repeat detected");
    
    # Caution reasons should be populated
    my $caution = $counter->{current_status}{caution_reasons};
    ok(ref($caution) eq 'ARRAY' && scalar(@$caution) > 0,
        "Caution reasons populated for command repeats");
    
    # Verify caution mentions command
    my $found_cmd = grep { $_ =~ /command|git status/i } @$caution;
    ok($found_cmd, "Caution includes command repeat message");
};

# ============================================================================
# TEST 6: DIAGNOSIS REVERSALS DETECTION
# ============================================================================
subtest "Test 6: Diagnosis Reversals Detection" => sub {
    plan tests => 5;
    
    unlink $counter_file if -f $counter_file;
    
    my $current_time = int(time());
    
    open my $fh, '>', $audit_log or die "Cannot create audit log: $!";
    
    # Create diagnosis reversal pattern: A -> B -> A
    my @entries = (
        {"action" => "analyze", "timestamp" => $current_time - 300, "diagnosis" => "Problem is in config"},
        {"action" => "analyze", "timestamp" => $current_time - 200, "diagnosis" => "Actually issue is in logger"},
        {"action" => "analyze", "timestamp" => $current_time - 100, "diagnosis" => "Problem is in config"},
    );
    
    foreach my $entry (@entries) {
        print $fh JSON::encode_json($entry) . "\n";
    }
    close $fh;
    
    # Run script
    my $result = system("perl $script_path $audit_log $counter_file 2>/dev/null");
    is($result, 0, "Script runs successfully");
    
    # Verify diagnosis reversal was detected
    my $counter = YAML::LoadFile($counter_file);
    ok($counter, "Counter loaded");
    
    # Check status
    ok($counter->{current_status}{status_level} =~ /CAUTION|ALERT/,
        "Status indicates diagnosis reversal detected");
    
    # Check caution reasons
    my $caution = $counter->{current_status}{caution_reasons};
    ok(ref($caution) eq 'ARRAY' && scalar(@$caution) > 0,
        "Caution reasons populated");
    
    # Verify diagnosis reversal message
    my $found_reversal = grep { $_ =~ /diagnosis|reversal|looping/i } @$caution;
    ok($found_reversal, "Caution includes diagnosis reversal message");
};

# ============================================================================
# TEST 7: MIXED ANOMALIES
# ============================================================================
subtest "Test 7: Multiple Anomalies Combined" => sub {
    plan tests => 6;
    
    unlink $counter_file if -f $counter_file;
    
    my $current_time = int(time());
    
    open my $fh, '>', $audit_log or die "Cannot create audit log: $!";
    
    # Add both file repeats AND command repeats
    my @entries = (
        {"action" => "ViewFile", "timestamp" => $current_time - 300, "file" => "app.pm"},
        {"action" => "ViewFile", "timestamp" => $current_time - 200, "file" => "app.pm"},
        {"action" => "ViewFile", "timestamp" => $current_time - 100, "file" => "app.pm"},
        {"action" => "ExecuteShellCommand", "timestamp" => $current_time - 250, "command" => "make test"},
        {"action" => "ExecuteShellCommand", "timestamp" => $current_time - 150, "command" => "make test"},
        {"action" => "ExecuteShellCommand", "timestamp" => $current_time - 50, "command" => "make test"},
    );
    
    foreach my $entry (@entries) {
        print $fh JSON::encode_json($entry) . "\n";
    }
    close $fh;
    
    # Run script
    my $result = system("perl $script_path $audit_log $counter_file 2>/dev/null");
    is($result, 0, "Script runs successfully");
    
    # Verify both anomalies detected
    my $counter = YAML::LoadFile($counter_file);
    ok($counter, "Counter loaded");
    
    # Status should be ALERT (multiple anomalies)
    ok($counter->{current_status}{status_level} =~ /CAUTION|ALERT/,
        "Status reflects multiple anomalies");
    
    # Multiple caution reasons should exist
    my $caution = $counter->{current_status}{caution_reasons};
    ok(ref($caution) eq 'ARRAY' && scalar(@$caution) >= 2,
        "Multiple caution reasons recorded");
    
    # Verify both patterns mentioned
    my $file_msg = grep { $_ =~ /app\.pm|file.*repeat/i } @$caution;
    my $cmd_msg = grep { $_ =~ /command|make test/i } @$caution;
    ok($file_msg, "File repeat anomaly recorded");
    ok($cmd_msg, "Command repeat anomaly recorded");
};

done_testing();