package Comserv::Util::AI::FreeModel;
# One rule for "is this model step free?" (Nov 8 2026). Used by ModelPick
# (automatic picks), Router::capable_chain_pick and the ModelChains probation
# check, so the three can no longer drift apart.
#
# Free = local Ollama, an OpenRouter id ending ':free', or an OpenRouter model
# on the verified 0/0 list below. Anything else is paid.
use strict;
use warnings;

# OpenRouter models priced 0/0 WITHOUT a ':free' suffix. Add a model only after
# checking data/ai_openrouter_prices.json AND https://openrouter.ai/api/v1/models.
# Verified Nov 8 2026: stealth/crouton-alpha is 0/0 in both. stealth/ox-alpha is
# listed in neither, so it is NOT here (treated as paid).
our %ZERO_PRICED_FREE = map { ($_ => 1) } qw(stealth/crouton-alpha);

# is_zero_priced($openrouter_model_id) -> 1/0
sub is_zero_priced { my ($class, $m) = @_; return (defined $m && $ZERO_PRICED_FREE{$m}) ? 1 : 0 }

# is_free_step($provider, $model, catalog_free => 0|1) -> 1/0
# catalog_free: the live catalog's own free flag (ModelPick passes it).
sub is_free_step {
    my ($class, $prov, $model, %o) = @_;
    $prov = lc($prov // '');
    $model //= '';
    return 1 if $prov eq 'ollama';
    return 0 unless $prov eq 'openrouter' && length $model;
    return 1 if $o{catalog_free};
    return 1 if $model =~ /:free\z/i;
    return $class->is_zero_priced($model);
}

1;
