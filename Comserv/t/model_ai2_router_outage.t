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
ok($p eq 'openrouter' || $p eq 'external', 'non-grok OpenRouter is openrouter (legacy external ok)');

# #2294: fallback hops must reuse the SAME messages (system prompt / Task Assistant).
{
    my $seen;
    no warnings 'redefine';
    local *Comserv::Model::AI2::Router::_chat_one = sub {
        my ($self, $c, $provider_name, $use_model, $messages, %opts) = @_;
        $seen = $messages;
        return {
            success => 0,
            error   => 'OpenRouter provider error: 503 Service Unavailable',
            provider => $provider_name,
        };
    };
    local *Comserv::Model::AI2::Router::pick_free_fallback = sub {
        return ({ provider => 'openrouter', model => 'google/gemma-4-31b-it:free' }, undef);
    };
    my $msgs = [
        { role => 'system', content => 'Task Assistant ACTION contract create_todo' },
        { role => 'user', content => 'add a todo pin SuperGrok' },
    ];
    # Skip sleep during retry
    local *Comserv::Model::AI2::Router::_chat_one_with_retry = sub {
        my ($self, $c, $provider_name, $use_model, $messages, %opts) = @_;
        my $resp = $self->_chat_one($c, $provider_name, $use_model, $messages, %opts);
        return $resp if $resp && $resp->{success};
        return {
            success => 1,
            response => 'ok',
            provider => $provider_name,
            model => $use_model,
        } if $provider_name eq 'openrouter' && ($use_model // '') =~ /gemma/;
        return $resp;
    };
    my $out = $r->chat_with_fallback(undef, 'openrouter', 'paid/model', $msgs);
    ok($out && $out->{success}, '503 hop-down succeeds on free fallback');
    is($seen, $msgs, 'fallback hop received the original messages array (Task Assistant prompt intact)');
}

done_testing();
