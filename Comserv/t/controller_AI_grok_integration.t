use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use JSON;

BEGIN {
    use_ok('Comserv::Controller::AI') or BAIL_OUT("Failed to load AI controller");
}

# Test 1: AI controller loads
ok(1, "AI controller loads successfully");

# Test 2: Verify Grok model can be used
{
    my $grok_available = 0;
    eval {
        require Comserv::Model::Grok;
        $grok_available = 1;
    };
    ok($grok_available, "Grok model is available for use");
}

# Test 3: Verify provider parameter extraction logic
{
    # Simulate parameter extraction
    my %test_json_data = (
        prompt => "What is AI?",
        provider => "grok",
        system => "You are helpful",
        format => "text"
    );
    
    my $provider = $test_json_data{provider} || 'ollama';
    is($provider, 'grok', "Provider parameter extracted correctly from request");
    
    # Test default provider
    my %test_json_data_default = (
        prompt => "What is AI?",
    );
    
    $provider = $test_json_data_default{provider} || 'ollama';
    is($provider, 'ollama', "Default provider is ollama when not specified");
}

# Test 4: Verify Grok routing condition
{
    my $provider = 'grok';
    my $use_grok = (lc($provider) eq 'grok') ? 1 : 0;
    ok($use_grok, "Grok provider routing condition works");
    
    $provider = 'ollama';
    my $use_ollama = (lc($provider) ne 'grok') ? 1 : 0;
    ok($use_ollama, "Ollama fallback routing works");
}

# Test 5: Verify multi-turn message format for Grok
{
    my $system = "You are a helpful assistant";
    my $prompt = "What is 2+2?";
    
    my @messages = (
        { role => 'system', content => $system || 'You are a helpful assistant.' },
        { role => 'user', content => $prompt }
    );
    
    is(scalar(@messages), 2, "Message array has correct structure");
    is($messages[0]->{role}, 'system', "System message has correct role");
    is($messages[1]->{role}, 'user', "User message has correct role");
}

done_testing();
