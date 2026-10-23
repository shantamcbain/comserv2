use strict; use warnings; use Test::More;
use FindBin; use lib "$FindBin::Bin/../lib";
use Comserv::Util::AI::PaidBlock;
use Comserv::Util::AI::CodeReviewer;
use Comserv::Model::AI2::Router;
my $P = 'Comserv::Util::AI::PaidBlock';
# 1) paid OpenRouter grok / v4-pro blocked (2026-10-15)
ok($P->blocked_on_openrouter('x-ai/grok-4.7'), 'x-ai/grok-4.7 blocked on OpenRouter');
ok($P->blocked_on_openrouter('openrouter/x-ai/grok-build-0.1'), 'openrouter/*grok* blocked');
ok($P->blocked_on_openrouter('deepseek/deepseek-v4-pro'), 'v4-pro blocked');
ok(!$P->blocked_on_openrouter('cohere/north-mini-code:free'), 'north-mini allowed');
ok(!$P->blocked_on_openrouter('anthropic/claude-sonnet-5.5'), 'reviewer Sonnet allowed');
is_deeply([ ($P->rewrite_openrouter('x-ai/grok-4.7', 1))[0,1] ], ['supergrok', 'grok-4.7'], 'grok + budget -> Super Grok');
is_deeply([ ($P->rewrite_openrouter('x-ai/grok-4.7', 0))[0,1] ], ['openrouter', 'cohere/north-mini-code:free'], 'grok, no budget -> north-mini');
is_deeply([ ($P->rewrite_openrouter('deepseek/deepseek-v4-pro', 1))[0,1] ], ['openrouter', 'cohere/north-mini-code:free'], 'v4-pro -> north-mini even with budget');
my $r = Comserv::Model::AI2::Router->new;
is_deeply([ $r->_detect_provider('openrouter|deepseek/deepseek-v4-pro') ], ['openrouter', 'cohere/north-mini-code:free'], 'Router never resolves v4-pro');
isnt(($r->_detect_provider('openrouter|x-ai/grok-4.7'))[0], 'openrouter', 'Router never sends grok to OpenRouter');
my $rv = Comserv::Util::AI::CodeReviewer->new(root => "$FindBin::Bin/..");
unlike($rv->config->{fixer}, qr/v4-pro/, 'reviewer fixer is not v4-pro');
# 2) commit gate view
my $high = { ok => 1, model => 'anthropic/claude-sonnet-5.5', review => { verdict => 'fail', correctness => 4, security => 5,
             findings => [ { severity => 'high', file => 'a.pm', line => 3, issue => 'SQL injection' } ] } };
{ no warnings 'redefine'; local *Comserv::Util::AI::CodeReviewer::config = sub { { mode => 'block' } };
  my $v = $rv->gate_view($high);
  ok($v->{blocking} && !$v->{allow}, 'high finding blocks');
  is($v->{findings}[0]{issue}, 'SQL injection', 'finding shown');
  my $low = { %$high, review => { %{ $high->{review} }, findings => [ { severity => 'low', issue => 'naming' } ] } };
  ok(!$rv->gate_view($low)->{blocking}, 'low finding does not block');
}
my $cap = $rv->gate_view({ ok => 0, skipped => 1, reason => 'daily cap reached' });
ok($cap->{allow} && !$cap->{blocking} && $cap->{warning} =~ /daily cap/, 'cap hit -> warn and allow');
my $err = $rv->gate_view({ ok => 0, reason => 'review call failed: 500' });
ok($err->{allow} && $err->{warning} =~ /Not reviewed/, 'reviewer error -> warn and allow');
# 3) add-on stabilizer (native_host.py)
my $out = `python3 $FindBin::Bin/grokcom_stabilize_check.py $FindBin::Bin/../script/firefox-grokcom-usage/native_host.py 2>&1`;
is($? >> 8, 0, 'native_host stabilize: flapping/jump cases') or diag $out;
done_testing;
