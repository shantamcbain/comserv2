package Comserv::Util::AI::PaidBlock;
# 2026-10-15 (Shanta): never bill OpenRouter for any grok id, and never use
# deepseek-v4-pro anywhere. Grok goes to Super Grok (prepaid) when it has
# budget, otherwise to the free north-mini. Pure functions, no $c.
use strict;
use warnings;

our $FREE_MODEL = 'cohere/north-mini-code:free';

sub is_grok_id   { my $m = $_[-1] // ''; return $m =~ /grok/i ? 1 : 0 }
sub is_banned_id { my $m = $_[-1] // ''; return $m =~ /deepseek-v4-pro|v4-pro/i ? 1 : 0 }

# OpenRouter must never be called with these ids.
sub blocked_on_openrouter {
    my $m = $_[-1] // '';
    return (is_grok_id($m) || is_banned_id($m)) ? 1 : 0;
}

# ($provider, $model, $note) for a request that would go to OpenRouter.
# $sg_ok = Super Grok has budget and a prepaid key.
sub rewrite_openrouter {
    my (undef, $model, $sg_ok) = @_;
    $model //= '';
    return ('openrouter', $model, '') unless blocked_on_openrouter($model);
    if (is_grok_id($model) && $sg_ok) {
        (my $bare = $model) =~ s{^(?:openrouter[|/])?(?:x-ai/)?}{}i;
        return ('supergrok', $bare, "paid OpenRouter $model blocked; using Super Grok $bare");
    }
    return ('openrouter', $FREE_MODEL, "paid OpenRouter $model blocked; using $FREE_MODEL");
}

1;
