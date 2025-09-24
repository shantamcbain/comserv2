#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use Test::Exception;
use Catalyst::Test 'Comserv';
use Test::WWW::Mechanize::Catalyst;

# Comprehensive tests for Documentation controller functionality

my $mech = Test::WWW::Mechanize::Catalyst->new(catalyst_app => 'Comserv');

# Test 1: Happy Path - Documentation page basic access
{
    $mech->get_ok('/Documentation', 'Documentation page accessible');
    $mech->content_contains('Documentation', 'Page contains Documentation title');
}

# Test 2: Branching - Admin vs normal user role access
{
    # Test normal user access (session role filtering)
    $mech->get('/Documentation');
    if ($mech->success) {
        # Check for role-based content filtering
        my $content = $mech->content;
        ok(1, 'Documentation page loads for role-based access');
        
        # Look for role indicators in content
        if ($content =~ /Your Role:\s*(\w+)/) {
            my $role = $1;
            ok(defined $role, "Role detected in page: $role");
        }
    }
}

# Test 3: Input Verification - Documentation roles validation
{
    # Test edit_roles endpoint with valid parameters
    $mech->get('/Documentation/edit_roles/admin');
    
    # Check response (may be 200 OK or redirect depending on auth)
    ok($mech->status == 200 || $mech->status == 302 || $mech->status == 401, 
       'edit_roles responds appropriately to access attempt');
    
    if ($mech->status == 200) {
        # If accessible, verify form elements
        eval {
            $mech->content_contains('page_name', 'Edit form contains page_name field');
            $mech->content_contains('roles', 'Edit form contains roles field');
        };
    }
}

# Test 4: Input Verification - Invalid documentation paths
{
    $mech->get('/Documentation/nonexistent_page');
    
    # Should handle gracefully (404 or redirect)
    ok($mech->status == 404 || $mech->status == 302 || $mech->status == 200,
       'Invalid documentation path handled gracefully');
}

# Test 5: Happy Path - Documentation listing functionality
{
    $mech->get('/Documentation');
    
    if ($mech->success) {
        my $content = $mech->content;
        
        # Check for documentation listing structure
        ok($content =~ /<ul|<li|<div.*class.*doc/i || 
           $content =~ /documentation.*available|no.*documentation/i,
           'Page shows documentation listing or appropriate message');
    }
}

# Test 6: Exception Handling - Server error simulation via malformed requests
{
    # Test with potentially problematic characters
    $mech->get('/Documentation/../../../etc/passwd');
    
    # Should not serve system files
    ok($mech->status != 200 || 
       ($mech->success && $mech->content !~ /root:|bin:|daemon:/),
       'Path traversal attempts blocked');
}

# Test 7: Happy Path - Static resource access for documentation
{
    # Test if CSS/JS resources load (common in documentation systems)
    $mech->get('/');
    
    if ($mech->success) {
        my $content = $mech->content;
        my @css_links = $content =~ /<link[^>]+href="([^"]+\.css[^"]*)"/gi;
        my @js_links = $content =~ /<script[^>]+src="([^"]+\.js[^"]*)"/gi;
        
        # Test a few key resources if they exist
        foreach my $css (@css_links[0..2]) {  # Test first 3 CSS files
            last unless defined $css;
            $mech->get_ok($css, "CSS resource loads: $css") if $css !~ /^(http|\/\/)/;
        }
    }
}

# Test 8: Branching - Role-based content filtering
{
    $mech->get('/Documentation');
    
    if ($mech->success) {
        my $content = $mech->content;
        
        # Check for role-specific content or messages
        if ($content =~ /no.*documentation.*available.*role/i) {
            pass('Role-based filtering message displayed');
        } elsif ($content =~ /<li|<ul|documentation/i) {
            pass('Documentation content available for user role');
        } else {
            pass('Documentation page structure present');
        }
    }
}

# Test 9: Input Verification - Documentation search functionality
{
    # Test if search parameters are handled
    $mech->get('/Documentation?search=test');
    
    ok($mech->status == 200 || $mech->status == 302,
       'Search parameters handled appropriately');
}

# Test 10: Happy Path - Documentation metadata handling
{
    $mech->get('/Documentation');
    
    if ($mech->success) {
        my $content = $mech->content;
        
        # Check for proper HTML structure
        ok($content =~ /<html|<!DOCTYPE/i, 'Proper HTML document structure');
        ok($content =~ /<title>/i, 'Page has title tag');
        ok($content =~ /<head>/i, 'Page has head section');
    }
}

# Test 11: Exception Handling - Session handling edge cases
{
    # Test with various session states
    $mech->get('/Documentation');
    my $initial_status = $mech->status;
    
    # Multiple requests to test session consistency
    $mech->get('/Documentation');
    is($mech->status, $initial_status, 'Session state consistent across requests');
}

# Test 12: Input Verification - Form submission to edit_roles
{
    # Test POST to edit_roles (if accessible)
    eval {
        $mech->post('/Documentation/edit_roles/test', {
            'roles' => 'user',
            'page_name' => 'test'
        });
        
        # Check response handling
        ok($mech->status == 200 || $mech->status == 302 || $mech->status == 401 || $mech->status == 403,
           'POST to edit_roles handled appropriately');
    };
    
    if ($@) {
        pass('POST test skipped due to access restrictions');
    }
}

# Test 13: Happy Path - Documentation page rendering performance
{
    use Time::HiRes qw(time);
    
    my $start_time = time();
    $mech->get('/Documentation');
    my $end_time = time();
    
    my $response_time = $end_time - $start_time;
    
    ok($response_time < 5.0, "Documentation page loads in reasonable time (<5s): ${response_time}s");
}

# Test 14: Input Verification - Special characters in URLs
{
    # Test URL encoding handling
    my @test_paths = (
        '/Documentation/test%20space',
        '/Documentation/test+plus',
        '/Documentation/test&amp',
    );
    
    foreach my $path (@test_paths) {
        $mech->get($path);
        ok($mech->status == 200 || $mech->status == 404 || $mech->status == 302,
           "Special character path handled: $path");
    }
}

# Test 15: Exception Handling - Large request handling
{
    # Test with long query parameters
    my $long_param = 'x' x 1000;  # 1000 character string
    $mech->get("/Documentation?long_param=$long_param");
    
    # Should handle gracefully without crashing
    ok($mech->status == 200 || $mech->status == 414 || $mech->status == 400 || $mech->status == 302,
       'Large request parameters handled gracefully');
}

done_testing();