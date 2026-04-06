use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

BEGIN {
    use_ok('Comserv::Model::Grok') or BAIL_OUT("Failed to load Grok model");
}

# Test 1: Model loads
ok(1, "Grok model module loaded");

# Test 2: Can instantiate without API key (graceful degradation)
my $grok = Comserv::Model::Grok->new();
ok($grok, "Grok model instantiated");

# Test 3: Check default attributes
is($grok->endpoint, 'https://api.x.ai/v1/chat/completions', "Correct default endpoint");
is($grok->model, 'grok-3', "Correct default model");
is($grok->timeout, 120, "Correct default timeout");
is($grok->temperature, 0.7, "Correct default temperature");
is($grok->max_tokens, 2048, "Correct default max_tokens");

# Test 4: API key loading (should gracefully degrade if not set)
if ($grok->api_key) {
    ok(length($grok->api_key) > 0, "API key loaded from environment or K8s secret");
} else {
    ok(1, "API key not configured (expected in test environment)");
}

# Test 5: Error message is set if API key missing
unless ($grok->api_key) {
    like($grok->last_error, qr/(not available|not found|not configured)/i, 
        "Error message set when API key is missing");
}

# Test 6: Chat method exists and can be called with messages
can_ok($grok, 'chat');
can_ok($grok, 'query');
can_ok($grok, 'check_connection');

done_testing();
