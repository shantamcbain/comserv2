package Comserv::Model::AI2::Router;

use Moose;
use namespace::autoclean -except => [qw(try catch finally)];  # keep Try::Tiny subs (Perl 5.40)

use Try::Tiny;
use JSON qw(encode_json decode_json);

use Comserv::Util::Logging;

extends 'Catalyst::Model';

has 'logging' => (
    is      => 'ro',
    lazy    => 1,
    default => sub { Comserv::Util::Logging->instance },
);

# ===================================================================
# AI2::Router — OpenRouter-style automatic model/provider switching.
#
# Single brain that decides, for a given request, which provider + model
# to use. Logic ported from v1 (Model::AI::Chat::_select_provider_and_model,
# Controller::AI::_select_model_for_context, Controller::AI::_get_current_ollama_config)
# and consolidated here so the controller stays thin.
#
# Fallback chain (like OpenRouter): try the user's explicit selection, then
# a context-appropriate default, then a generic fallback — preferring local
# Ollama when available to keep cost at zero, escalating to x.ai/OpenRouter
# for capability gaps.
# ===================================================================

# -------------------------------------------------------------------
# Provider detection from a requested model name
# -------------------------------------------------------------------
sub _detect_provider {
    my ($self, $requested_model) = @_;
    return ('ollama', $requested_model) unless $requested_model;

    my $bare = $requested_model;
    my $prefix = '';
    if ($bare =~ s/^([^|]+)\|//) {
        $prefix = lc($1);
    }
    if ($prefix eq 'supergrok' || $prefix eq 'grok-oauth') {
        return ('supergrok', $bare);
    }
    if ($prefix eq 'grok' || $bare =~ /^grok/i) {
        return ('grok', $bare);
    }
    if ($prefix eq 'openrouter' || $prefix eq 'external' || $bare =~ m{/}) {
        return ('external', $bare);
    }
    if ($requested_model =~ m{/}) {
        return ('external', $requested_model);
    }
    if ($requested_model =~ /^(gpt|claude|llama3|mixtral|groq|openrouter|or-|tencent)/i) {
        return ('external', $requested_model);
    }
    return ('ollama', $requested_model);
}

# -------------------------------------------------------------------
# Context-preference table — first installed match wins (OpenRouter-style).
# Ported from Controller::AI::_select_model_for_context.
# -------------------------------------------------------------------
my %CONTEXT_PREFS = (
    chat        => ['phi4', 'gemma4', 'qwen2.5', 'qwen3-coder'],
    helpdesk    => ['phi4', 'gemma4', 'qwen2.5'],
    ency        => ['qwen2.5', 'gemma4', 'phi4'],
    bmaster     => ['qwen2.5', 'gemma4', 'phi4'],
    csc         => ['phi4', 'gemma4', 'qwen2.5'],
    general     => ['phi4', 'gemma4', 'qwen2.5-coder', 'qwen3-coder'],
    navigation  => ['phi4', 'gemma4'],
    simple      => ['phi4', 'gemma4'],
    code        => ['qwen3-coder', 'qwen2.5-coder', 'phi4', 'gemma4'],
    developer   => ['qwen3-coder', 'qwen2.5-coder', 'phi4'],
    docker      => ['phi4', 'gemma4'],
);

my %ROLE_TO_CONTEXT = (
    helpdesk => 'helpdesk',
    ency     => 'ency',
    encycl   => 'ency',
    bmaster  => 'bmaster',
    beekeep  => 'bmaster',
    apiary   => 'bmaster',
    csc      => 'csc',
    code     => 'code',
    developer=> 'developer',
    docker   => 'docker',
    nav      => 'navigation',
    navagent => 'navigation',
);

# Read-only accessor for the context-preference table (used by the
# /ai2/diagnostics snapshot so the routing brain's choices are visible).
sub context_prefs {
    my ($self) = @_;
    return { %CONTEXT_PREFS };
}

sub _context_for {
    my ($self, $agent_id) = @_;
    $agent_id //= 'general';
    my $ctx = lc($agent_id);
    $ctx = 'helpdesk' if $ctx =~ /helpdesk/;
    $ctx = 'code'     if $ctx =~ /code|developer|starcoder/;
    $ctx = 'bmaster'  if $ctx =~ /bmast|beekeep|apiar/;
    $ctx = 'csc'      if $ctx =~ /^csc$/;
    $ctx = 'ency'     if $ctx =~ /^ency$/;
    $ctx = 'docker'   if $ctx =~ /docker/;
    $ctx = 'navigation' if $ctx =~ /nav/;
    $ctx = 'general'  unless exists $CONTEXT_PREFS{$ctx};
    return $ctx;
}

# Strip embeddings/rerankers/tts to avoid 400s from non-chat models.
sub _is_chat_model {
    my ($self, $name) = @_;
    return $name !~ /embed|rerank|bge|nomic|clip|whisper|tts/i;
}

# The Router identifies external models as "provider|slug" (e.g.
# "openrouter|tencent/hy3"). Providers want the BARE slug ("tencent/hy3"),
# not the prefixed form — sending "openrouter|tencent/hy3" to OpenRouter's API
# returns HTTP 400 "not a valid model ID". Strip the prefix once, here, so
# every caller (dispatch_chat, Chat::process) hands the provider a clean id.
sub _bare_model {
    my ($self, $model) = @_;
    return $model unless defined $model;
    $model =~ s/^[^|]+\|//;   # drop leading "provider|"
    return $model;
}

# True when the given "provider|model" external default can actually be served:
# an API key/secret resolves for that provider AND the model appears in its live
# catalog. Avoids silently defaulting to a model that will 401/404 — in which
# case we fall through to the local Ollama preference below.
sub _external_default_available {
    my ($self, $c, $external) = @_;
    return 0 unless $external && $external =~ /^([^|]+)\|(.+)$/;
    my ($svc, $model) = ($1, $2);

    my $cls = { grok => 'AI2::Provider::Grok', supergrok => 'AI2::Provider::Grok',
                openrouter => 'AI2::Provider::OpenRouter' }->{$svc};
    return 0 unless $cls;
    my $prov = try { $c->model($cls) } catch { undef };
    return 0 unless $prov && $prov->can('_resolve_api_key');

    # Key must resolve (k8s secret / env / DBEncy UserApiKeys).
    my $key = try { $prov->_resolve_api_key($c) } catch { undef };
    return 0 unless $key;

    # Model must exist in the live catalog (skip the network check if the
    # provider lacks list_models, e.g. some thin wrappers — then trust the key).
    return 1 unless $prov->can('list_models');
    my $listed = try { $prov->list_models($c) } catch { undef };
    return 1 unless $listed && $listed->{success} && $listed->{models};
    my %ids = map { ($_->{id} // '') => 1 } @{$listed->{models}};
    return $ids{$model} ? 1 : 0;
}

# -------------------------------------------------------------------
# select_model — the core routing decision.
#
#   $ctx keys: agent_id, page_context, requested_model, can_select,
#              installed_models (array of names/hashes), default_model
#
# Returns ($provider, $model) — provider is one of ollama|grok|external.
# -------------------------------------------------------------------
sub select_model {
    my ($self, $c, %ctx) = @_;

    my $requested   = $ctx{requested_model};
    my $installed   = $ctx{installed_models} // [];
    my $default     = $ctx{default_model};
    my $context_key = $self->_context_for($ctx{agent_id} // $ctx{page_context} // 'general');

    # 1) Explicit selection wins if the provider can serve it.
    if ($requested) {
        my ($prov, $model) = $self->_detect_provider($requested);
        return ($prov, $model);
    }

    # 1.5) App-wide DEFAULT: prefer the off-host OpenRouter model so automatic
    # selection never stalls the workstation by cold-loading a ~9GB local
    # Ollama weight. This is the SINGLE default used by every surface that
    # reaches the Router (chat widget, Git drafting, editor, focus-tune) so
    # behavior is consistent across the whole app. Only used when an external
    # key is actually resolvable AND the model is reachable.
    my $default_external = 'openrouter|tencent/hy3';
    if ($self->_external_default_available($c, $default_external)) {
        return ('external', $default_external);
    }

    # 2) Build a lookup of installed chat models (short name -> full name).
    my %installed;
    for my $m (@$installed) {
        my $name = ref($m) ? ($m->{name} || '') : ($m || '');
        next unless $name && $self->_is_chat_model($name);
        $installed{$name} = $name;
        (my $short = $name) =~ s/:.*$//;
        $installed{$short} = $name;
    }

    # 3) Context preference (first installed match wins).
    my $prefs = $CONTEXT_PREFS{$context_key} || $CONTEXT_PREFS{general};
    for my $pref (@$prefs) {
        for my $key (keys %installed) {
            if ($key =~ /\Q$pref\E/i) {
                return ('ollama', $installed{$key});
            }
        }
    }

    # 4) Default model if installed + chat-capable.
    if ($default && $self->_is_chat_model($default)) {
        return ('ollama', $default)
            if $installed{$default} || grep { $_ eq $default } values %installed;
    }

    # 5) Any installed chat model.
    my @chat = grep { $self->_is_chat_model($_) } values %installed;
    return ('ollama', $chat[0]) if @chat;

    # 6) Hardcoded safe fallback (local-first) — must match an installed model.
    return ('ollama', 'phi4:14b');
}

# -------------------------------------------------------------------
# select_best_model — controller convenience wrapper returning a list.
# -------------------------------------------------------------------
sub select_best_model {
    my ($self, $c, %opts) = @_;
    my ($prov, $model) = $self->select_model($c, %opts);
    return [$model, $prov];
}

# xAI (provider 'grok') auto-fills prepaid credits. SuperGrok (OAuth
# subscription) and OpenRouter do NOT. Credit-exhaustion on SuperGrok or
# OpenRouter must fall back to a free OpenRouter :free model, then Ollama.
# Never treat grok and supergrok as the same provider.
sub _credits_exhausted {
    my ($self, $error) = @_;
    return 0 unless defined $error && length $error;
    # 429 / rate-limit counts too: a throttled :free model is just as
    # unavailable as an empty balance — fall through to the next hop
    # (todo #2233: gemma-4-31b-it:free 429'd and the chain never engaged).
    return 1 if $error =~ /\b429\b|too many requests|rate.?limit/i;
    # Connection failures / DNS / timeouts are also "this hop is down"
    # (todo #2244: 500 Can't connect to openrouter.ai:443 — Name or service
    # not known) — fall through rather than surfacing a dead provider.
    return 1 if $error =~ /can'?t connect|connection (refused|reset|timed? ?out)|name or service not known|temporary failure in name resolution|\b500 can't connect|\btimed? ?out\b/i;
    return 1 if $error =~ /402\b|payment.?required|insufficient credit|out of credit|credit.?balance|can only afford|prepaid credit|usage limit|quota|weekly usage|limit_remaining|no auto-fill/i;
    return 0;
}

sub _provider_needs_credit_fallback {
    my ($self, $provider_name) = @_;
    return ($provider_name // '') =~ /^(supergrok|openrouter|external)$/ ? 1 : 0;
}

# First live OpenRouter :free model, then first chat-capable Ollama tag.
# No hardcoded model slugs — catalog is the source of truth.
sub pick_free_fallback {
    my ($self, $c, $skip_provider, $skip_model) = @_;
    my $catalog = try { $self->get_available_models($c) } catch {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'pick_free_fallback',
            "Catalog for fallback failed: $_");
        [];
    };
    $catalog = [] unless $catalog && ref($catalog) eq 'ARRAY';
    my ($free, $local);
    for my $m (@$catalog) {
        next unless ref $m eq 'HASH';
        next if $m->{disabled} || $m->{needs_key} || $m->{unreachable};
        my $name = $m->{name} // '';
        my $svc  = $m->{provider} || '';
        next unless length $name;
        next if $svc eq ($skip_provider // '') && $name eq ($skip_model // '');
        my $is_free  = $m->{free} || ($name =~ /:free$/);
        my $is_local = $m->{local} || ($svc eq 'ollama');
        if (!$free && $is_free && $svc =~ /^(openrouter|external)$/) {
            $free = { provider => 'openrouter', model => $name };
        }
        if (!$local && $is_local && $svc eq 'ollama' && $self->_is_chat_model($name)) {
            $local = { provider => 'ollama', model => $name };
        }
        last if $free && $local;
    }
    return ($free, $local);
}

sub _chat_one {
    my ($self, $c, $provider_name, $use_model, $messages) = @_;

    my $dispatch = {
        ollama     => 'AI2::Provider::Ollama',
        grok       => 'AI2::Provider::Grok',
        supergrok  => 'AI2::Provider::Grok',
        openrouter => 'AI2::Provider::OpenRouter',
        external   => 'AI2::Provider::OpenRouter',
    };
    my $prov_class = $dispatch->{$provider_name} || 'AI2::Provider::Ollama';
    my $provider = try { $c->model($prov_class) } catch { undef };
    unless ($provider && $provider->can('chat')) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_chat_one',
            "No client available for provider=$provider_name class=" . ($prov_class // 'undef'));
        return { success => 0, error => "No client available for provider $provider_name", provider => $provider_name };
    }

    my ($host, $port);
    if ($provider->can('resolve_host')) {
        ($host, $port) = $provider->resolve_host($c);
    }

    my $resp = try {
        $provider->chat($c,
            messages => $messages,
            model    => $self->_bare_model($use_model),
            host     => $host,
            port     => $port,
        );
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_chat_one',
            "Provider $provider_name threw: $_");
        undef;
    };

    unless ($resp && ref($resp) eq 'HASH') {
        return { success => 0, error => "Provider $provider_name returned nothing", provider => $provider_name };
    }
    $resp->{provider} ||= $provider_name;
    return $resp;
}

# Paid OpenRouter (no auto-fill) and SuperGrok (prepaid, no remaining-quota
# API) fall back to free OpenRouter then Ollama. xAI grok auto-fills — do
# not steal the turn away from grok on a credit error.
sub chat_with_fallback {
    my ($self, $c, $provider_name, $use_model, $messages) = @_;

    my $skip_paid = 0;
    my $pre_err;
    if ($self->_provider_needs_credit_fallback($provider_name)) {
        if ($provider_name =~ /^(openrouter|external)$/) {
            my $st = try { $c->model('AI')->usage->fetch_openrouter_status($c) } catch { undef };
            if ($st && $st->{ok} && defined $st->{remaining} && $st->{remaining} <= 0) {
                $skip_paid = 1;
                $pre_err = 'OpenRouter remaining credits are 0 (no auto-fill)';
                $self->logging->log_with_details($c, 'warning', __FILE__, __LINE__, 'chat_with_fallback',
                    $pre_err);
            }
        }
    }

    my $resp;
    unless ($skip_paid) {
        $resp = $self->_chat_one($c, $provider_name, $use_model, $messages);
        if ($resp && $resp->{success}) {
            return $resp;
        }
    }

    my $err = $pre_err || ($resp && $resp->{error}) || 'AI provider error';
    my $do_fallback = $self->_provider_needs_credit_fallback($provider_name)
        && ($skip_paid || $self->_credits_exhausted($err));

    unless ($do_fallback) {
        $resp ||= { success => 0, error => $err, provider => $provider_name };
        $resp->{provider} ||= $provider_name;
        return $resp;
    }

    my ($free, $local) = $self->pick_free_fallback($c, $provider_name, $use_model);
    for my $hop ($free, $local) {
        next unless $hop;
        $self->logging->log_with_details($c, 'warning', __FILE__, __LINE__, 'chat_with_fallback',
            "Paid $provider_name exhausted ($err); falling back to $hop->{provider} $hop->{model}");
        my $retry = $self->_chat_one($c, $hop->{provider}, $hop->{model}, $messages);
        if ($retry && $retry->{success}) {
            $retry->{provider}       = $hop->{provider};
            $retry->{fallback}       = 1;
            $retry->{fallback_from}  = $provider_name;
            $retry->{original_error} = $err;
            $retry->{original_model} = $use_model;
            return $retry;
        }
        my $hop_err = ($retry && $retry->{error}) || 'fallback hop failed';
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'chat_with_fallback',
            "Fallback hop $hop->{provider}/$hop->{model} failed: $hop_err");
    }

    $resp ||= { success => 0, error => $err, provider => $provider_name };
    $resp->{provider} ||= $provider_name;
    $resp->{error} = $err;
    return $resp;
}

# -------------------------------------------------------------------
# dispatch_chat — SINGLE place that turns (model name + messages) into a
# provider response for the v2 AI system. Used by BOTH the chat widget
# (Model::AI2::Chat::process) AND the AI Focus-Tune (Controller::Api
# api_focus_top5), so Ollama / Grok / OpenRouter all route through one
# code path and never bypass the provider layer (which is what made the
# tune silently fail on non-Ollama models).
# -------------------------------------------------------------------
sub dispatch_chat {
    my ($self, $c, $requested_model, $messages, %opts) = @_;

    my $can_select = $opts{can_select} // 1;
    my ($provider_name, $use_model) = $self->select_model($c,
        requested_model => $requested_model, can_select => $can_select);

    return $self->chat_with_fallback($c, $provider_name, $use_model, $messages);
}

# -------------------------------------------------------------------
# get_available_models — merged view across all providers.
#
# Local Ollama tags + external (x.ai / OpenRouter) catalog. External models
# come from the user's configured API keys; if none, only local is returned.
# Avoids raw SQL — reads keys via DBIx::Class resultset like v1 does.
# -------------------------------------------------------------------
sub get_available_models {
    my ($self, $c, %opts) = @_;

    my @all;

    # --- Local Ollama ---
    # v2 parity with v1 get_user_providers: ALWAYS emit Ollama entries so the
    # dropdown never collapses to just external providers. The controller
    # groups these flat per-model entries by provider. If Ollama is
    # unreachable at catalog time, emit a single unreachable sentinel (instead
    # of nothing) so the widget can show a clear note rather than hiding local AI.
    try {
        my $ollama = $c->model('AI2::Provider::Ollama');
        my ($host, $port) = $ollama->resolve_host($c);
        my $reachable = $ollama && $ollama->check_connection($c, $host, $port);
        if ($reachable) {
            my $models = $ollama->list_models($c, $host, $port) || [];
            my $added = 0;
            for my $m (@$models) {
                my $name = ref($m) ? ($m->{name} || '') : $m;
                next unless $name;
                push @all, {
                    id       => $name,
                    name     => $name,
                    provider => 'ollama',
                    label    => "Ollama: $name",
                    local    => 1,
                };
                $added++;
            }
            unless ($added) {
                # Reachable but no models installed — still surface the group.
                push @all, {
                    id       => 'ollama_empty',
                    name     => 'ollama_empty',
                    provider => 'ollama',
                    label    => 'Ollama (no models installed)',
                    local    => 1,
                    unreachable => 0,
                };
            }
        } else {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
                'get_available_models', "Ollama unreachable at $host:$port — emitting sentinel");
            push @all, {
                id          => 'ollama_unreachable',
                name        => 'ollama_unreachable',
                provider    => 'ollama',
                label       => "Ollama ($host:$port unreachable)",
                local       => 1,
                unreachable => 1,
            };
        }
    } catch {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
            'get_available_models', "Ollama discovery failed: $_");
        push @all, {
            id          => 'ollama_unreachable',
            name        => 'ollama_unreachable',
            provider    => 'ollama',
            label       => 'Ollama (unreachable)',
            local       => 1,
            unreachable => 1,
        };
    };

    # --- External (x.AI / OpenRouter) ---
    # Driven by key *resolution*, not by the presence of a UserApiKeys row.
    # A provider is shown (with its live model catalog) when a key can be
    # resolved (k8s secret / env var / DBEncy); otherwise it appears as a
    # non-selectable "configure key" note so the user knows why it's empty.
    # We never emit a bare service-name id (e.g. "grok") as a selectable
    # model — that would be sent to chat and fail with "model not found".
    my %external = (
        supergrok  => 'AI2::Provider::Grok',
        grok       => 'AI2::Provider::Grok',
        openrouter => 'AI2::Provider::OpenRouter',
    );
    for my $svc (qw(supergrok grok openrouter)) {
        my $cls  = $external{$svc};
        my $prov = try { $c->model($cls) } catch { undef };
        unless ($prov && $prov->can('list_models') && $prov->can('_resolve_api_key')) {
            push @all, { name => $svc . '_unconfigured', provider => $svc,
                         label => ucfirst($svc) . ' (unavailable)', local => 0,
                         needs_key => 1, disabled => 1 };
            next;
        }

        my $has_key;
        my $listed;
        if ($svc eq 'supergrok' && $prov->can('resolve_prepaid_key')) {
            $has_key = try { $prov->resolve_prepaid_key($c) } catch { undef };
            $listed  = try { $prov->list_models($c, undef, mode => 'prepaid') } catch { undef }
                if $has_key;
        }
        elsif ($svc eq 'grok' && $prov->can('resolve_paid_key')) {
            $has_key = try { $prov->resolve_paid_key($c) } catch { undef };
            $listed  = try { $prov->list_models($c, undef, mode => 'paid') } catch { undef }
                if $has_key;
        }
        else {
            $has_key = try { $prov->_resolve_api_key($c) } catch { undef };
            $listed  = try { $prov->list_models($c) } catch { undef } if $has_key;
        }

        if ($has_key) {
            if ($listed && $listed->{success} && $listed->{models} && @{$listed->{models}}) {
                for my $m (@{$listed->{models}}) {
                    push @all, {
                        name     => $m->{id},
                        provider => $svc,
                        label    => ($m->{label} || $m->{id}) . " ($svc)",
                        local    => 0,
                        prepaid  => ($svc eq 'supergrok' || $m->{prepaid}) ? 1 : 0,
                        pricing          => $m->{pricing}        || {},
                        price_prompt     => $m->{price_prompt}     // 0,
                        price_completion => $m->{price_completion} // 0,
                    };
                }
                next;
            }
            push @all, { name => $svc . '_error', provider => $svc,
                         label => ucfirst($svc) . ' (key set, list failed: '
                                 . ($listed->{error} // 'unknown') . ')',
                         local => 0, needs_key => 1, disabled => 1 };
        } else {
            push @all, { name => $svc . '_needs_key', provider => $svc,
                         label => ucfirst($svc) . ' (configure API key to list models)',
                         local => 0, needs_key => 1, disabled => 1 };
        }
    }

    # Sanitize: upstream provider JSON (Ollama /api/tags, OpenRouter /v1/models)
    # can occasionally return a malformed entry (a bare string or array instead
    # of a model object). Drop anything that isn't a hashref so the downstream
    # grouping in /ai2/providers and ModelCatalog never hits "Not a HASH
    # reference". Log the offending element tagged by provider so the source
    # (and the exact bad payload) is visible in the error audit.
    my @clean;
    for my $m (@all) {
        if (ref $m eq 'HASH') {
            push @clean, $m;
        } else {
            # We can't read a provider off a non-hash element; infer a hint from
            # the element shape so the log points at the likely culprit.
            my $hint = defined $m
                ? (ref $m ? ref($m) : "scalar '$m'")
                : 'undef';
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
                'get_available_models',
                "Dropping non-hash catalog element: $hint");
        }
    }
    @all = @clean;

    # ROLE FILTER — applied ONCE here, at the single source of truth, so every
    # consumer (ModelCatalog, /ai2/providers, the widget, /ai, git dashboard)
    # is role-filtered without each list re-implementing it. Tiers:
    #   guest  : free OpenRouter + Ollama local only (no paid, no Grok)
    #   member : free + cheap + mid (premium > $5 / 1M excluded, no Grok)
    #   priv   : everything (admin / developer / editor)
    @all = $self->_role_filter_models($c, \@all);

    return \@all;
}

# Keep only the models a role tier may see. Mirrors ModelCatalog's tiers so the
# two paths (direct Router use and ModelCatalog caching) agree.
sub _role_filter_models {
    my ($self, $c, $all) = @_;
    my $tier = $self->_role_tier($c);
    return @$all if $tier eq 'priv';
    my @out;
    for my $m (@$all) {
        next if $m->{disabled} || $m->{needs_key} || $m->{unreachable};
        my $svc  = $m->{provider} || '';
        my $free = $m->{free} || ( ($m->{name} // '') =~ /:free$/ ? 1 : 0 );
        my $local = $m->{local} || ( $svc eq 'ollama' ? 1 : 0 );
        if ($tier eq 'guest') {
            push @out, $m if $free || $local;
        } else { # member
            next if $svc eq 'grok' || $svc eq 'supergrok';
            my $pp = ($m->{price_prompt}     // 0) + 0;
            my $pc = ($m->{price_completion} // 0) + 0;
            my $max = ( $pp > $pc ) ? $pp : $pc;
            next if $max > 5;   # premium excluded for members
            push @out, $m;
        }
    }
    return \@out;
}

sub _role_tier {
    my ($self, $c) = @_;
    my $roles = eval { $c->session->{roles} } || [];
    $roles = [ split(/\s*,\s*/, $roles) ] unless ref $roles;
    my $is_guest = 1;
    my $is_priv  = 0;
    for my $r (@$roles) {
        next unless defined $r && length $r;
        $is_guest = 0 if $r =~ /^(admin|developer|editor|member|user)$/i;
        $is_priv  = 1 if $r =~ /^(admin|developer|editor)$/i;
    }
    return 'priv'  if $is_priv;
    return 'guest' if $is_guest;
    return 'member';
}

# -------------------------------------------------------------------
# get_recommended_models — role/context-aware recommendations for the UI.
# -------------------------------------------------------------------
sub get_recommended_models {
    my ($self, $c, %opts) = @_;
    my $context_key = $self->_context_for($opts{agent_id} // $opts{page_context} // 'general');
    my $prefs = $CONTEXT_PREFS{$context_key} || $CONTEXT_PREFS{general};

    my @rec;
    for my $p (@$prefs) {
        push @rec, { name => "$p:latest", label => ucfirst($p) . ' (recommended)', context => $context_key };
        last if @rec >= 3;
    }
    return \@rec;
}

# -------------------------------------------------------------------
# Branch list for the editor popup (git plumbing, safe fallback).
# -------------------------------------------------------------------
sub get_available_branches {
    my ($self, $c) = @_;

    try {
        my $project_root = $c->path_to('')->stringify;
        chdir $project_root or die "Cannot chdir to $project_root: $!";
        my @branches = `git branch --format='%(refname:short)' 2>&1`;
        chdir $ENV{'PWD'};
        if ($? != 0) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
                'get_available_branches', "Git failed: @branches");
            return ['main'];
        }
        chomp @branches;
        return \@branches || ['main'];
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'get_available_branches', "Exception: $_");
        return ['main'];
    };
}

# Placeholder routing stub retained for API compatibility.
sub route_request {
    my ($self, $c, %args) = @_;
    my ($prov, $model) = $self->select_model($c, %args);
    return { success => 1, provider => $prov, model => $model };
}

__PACKAGE__->meta->make_immutable;

1;
