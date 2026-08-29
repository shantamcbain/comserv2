use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

BEGIN { use_ok('Comserv::Model::AI2::Router'); }

my $r = Comserv::Model::AI2::Router->new;
ok($r, 'Router instantiates');

ok($r->_transient_outage('OpenRouter provider error: 503 Service Unavailable - Provider returned error'),
    '503 Service Unavailable is transient');
ok($r->_transient_outage('502 Bad Gateway'), '502 is transient');
ok($r->_transient_outage('504 Gateway Timeout'), '504 is transient');
ok(!$r->_transient_outage('400 Bad Request - not a valid model ID'), '400 is not transient');
ok(!$r->_transient_outage('401 Unauthorized'), '401 is not transient');

ok($r->_credits_exhausted('OpenRouter provider error: 503 Service Unavailable'),
    '503 counts as hop-down so fallback engages');
ok($r->_credits_exhausted('429 Too Many Requests'), '429 still hop-down');
ok(!$r->_credits_exhausted('400 Bad Request'), '400 does not hop-down');

like($r->_user_facing_error('OpenRouter provider error: 503 Service Unavailable'),
    qr/temporarily unavailable/i, 'user never sees raw 503');
unlike($r->_user_facing_error('OpenRouter provider error: 503 Service Unavailable'),
    qr/503/, 'no status code in public error');

my ($p, $m);
($p, $m) = $r->_detect_provider('supergrok|grok-4.6');
is($p, 'supergrok', 'supergrok| prefix stays SuperGrok');
is($m, 'grok-4.6', 'bare grok-4.6');

($p, $m) = $r->_detect_provider('grok-4.6');
is($p, 'supergrok', 'bare grok-* is SuperGrok not xAI pay grok');

($p, $m) = $r->_detect_provider('openrouter|x-ai/grok-4');
is($p, 'supergrok', 'OpenRouter x-ai/grok remaps to SuperGrok (do not bill OpenRouter)');
is($m, 'grok-4', 'strips x-ai/ prefix');

($p, $m) = $r->_detect_provider('x-ai/grok-4.6');
is($p, 'supergrok', 'slash x-ai/grok is SuperGrok not OpenRouter');

($p, $m) = $r->_detect_provider('grok|grok-4.6');
is($p, 'grok', 'explicit grok| is xAI pay-per-token (overridden to SuperGrok when token exists)');

($p, $m) = $r->_detect_provider('openrouter|tencent/hy3');
is($p, 'external', 'non-grok OpenRouter stays OpenRouter');

done_testing();
