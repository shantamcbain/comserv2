#!/usr/bin/env perl
# Nov 21 2026: the editor's coding chain must lead with Super Grok after the
# daily guard switches BACK to it (from=particle-1, to=xai-oauth/grok-4.7).
# Before the fix, the switch's 'from' was always put first, so particle-1 won.
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;
use File::Temp qw(tempdir);
use JSON ();

use_ok('Comserv::Model::AI2::ModelPick');

my $dir = tempdir(CLEANUP => 1);
my $cfg = "$dir/config.yaml";
my $sw  = "$dir/guard_model_switch.json";
open my $fh, '>', $cfg or die $!;
print $fh <<'Y';
model:
  provider: xai-oauth
  default: grok-4.7
fallback_providers:
  - provider: openrouter
    model: particle-ai/particle-1
  - provider: openrouter
    model: baidu/ernie-5.5-flash-preview:free
Y
close $fh;
local $ENV{HERMES_CONFIG}       = $cfg;
local $ENV{HERMES_GUARD_SWITCH} = $sw;

my $mp = Comserv::Model::AI2::ModelPick->new;
my $write = sub {
    my ($from, $to, $gen) = @_;
    %Comserv::Model::AI2::ModelPick::CHAIN_CACHE = ();
    open my $o, '>', $sw or die $!;
    print $o JSON::encode_json({ from => $from, to => $to, generation => $gen });
    close $o;
};
my $keys = sub { [ map { "$_->{provider}|$_->{model}" } @{ $mp->hermes_chain(undef) } ] };
my $live = { 'openrouter|particle-ai/particle-1' => 1, 'openrouter|baidu/ernie-5.5-flash-preview:free' => 1 };

# 1. Switch BACK to Super Grok (the live Nov 19 10:40 AM state).
$write->('openrouter/particle-ai/particle-1', 'xai-oauth/grok-4.7', 20);
my $k = $keys->();
is($k->[0], 'supergrok|grok-4.7', 'switch back to Super Grok: grok-4.7 leads the chain');
my ($pick) = $mp->pick_from_chain(undef, chain => $mp->hermes_chain(undef), live => $live,
    guard => { locked => 0 }, agent => 'programming', phase => 'analyze');
is($pick && "$pick->{provider}|$pick->{model}", 'supergrok|grok-4.7', 'editor analyze picks Super Grok when unlocked');
ok((grep { $_ eq 'openrouter|particle-ai/particle-1' } @$k), 'particle-1 still in the chain as a fallback');

($pick) = $mp->pick_from_chain(undef, chain => $mp->hermes_chain(undef), live => $live,
    guard => { locked => 1, reason => 'allowance used' }, agent => 'programming', phase => 'analyze');
is($pick && $pick->{model}, 'particle-ai/particle-1', 'guard locked: falls over to particle-1');

# 2. Switch AWAY from Super Grok: the old model is still the head (unchanged).
$write->('xai-oauth/grok-4.7', 'openrouter/particle-ai/particle-1', 21);
$k = $keys->();
is($k->[0], 'supergrok|grok-4.7', 'switch away: Super Grok still heads (skipped only when locked)');
is($k->[1], 'openrouter|particle-ai/particle-1', 'switch away: guard target is next');
is($mp->hermes_chain(undef)->[0]{source}, 'supergrok-head', 'switch away: head tagged supergrok-head');

# 3. Neither side is Super Grok: no fake head.
$write->('openrouter/particle-ai/particle-1', 'openrouter/baidu/ernie-5.5-flash-preview:free', 22);
$k = $keys->();
is($k->[0], 'openrouter|baidu/ernie-5.5-flash-preview:free', 'non-Grok from is not promoted to head');

done_testing;
