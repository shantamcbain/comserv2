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

    if ($requested_model =~ /^grok/i) {
        return ('grok', $requested_model);
    }
    if ($requested_model =~ /^(gpt|claude|llama3|mixtral|groq|openrouter|or-)/i) {
        # External OpenAI-compatible / OpenRouter / x.AI model
        return ('external', $requested_model);
    }
    # Anything else (e.g. "llama3.1:latest", "phi4") is a local Ollama tag
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
    try {
        my $ollama = $c->model('AI2::Provider::Ollama');
        my $cfg    = $c->config->{Ollama} || {};
        my $host   = $cfg->{host} || 'localhost';
        my $port   = $cfg->{port} || 11434;
        if ($ollama && $ollama->check_connection($c, $host, $port)) {
            my $models = $ollama->list_models($c, $host, $port) || [];
            for my $m (@$models) {
                my $name = ref($m) ? ($m->{name} || '') : $m;
                next unless $name;
                push @all, {
                    name     => $name,
                    provider => 'ollama',
                    label    => "Ollama: $name",
                    local    => 1,
                };
            }
        }
    } catch {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
            'get_available_models', "Ollama discovery failed: $_");
    };

    # --- External (x.AI / OpenRouter) ---
    # Driven by key *resolution*, not by the presence of a UserApiKeys row.
    # A provider is shown (with its live model catalog) when a key can be
    # resolved (k8s secret / env var / DBEncy); otherwise it appears as a
    # non-selectable "configure key" note so the user knows why it's empty.
    # We never emit a bare service-name id (e.g. "grok") as a selectable
    # model — that would be sent to chat and fail with "model not found".
    my %external = (
        grok       => 'AI2::Provider::Grok',
        openrouter => 'AI2::Provider::OpenRouter',
    );
    for my $svc (sort keys %external) {
        my $cls  = $external{$svc};
        my $prov = try { $c->model($cls) } catch { undef };
        unless ($prov && $prov->can('list_models') && $prov->can('_resolve_api_key')) {
            push @all, { name => $svc . '_unconfigured', provider => $svc,
                         label => ucfirst($svc) . ' (unavailable)', local => 0,
                         needs_key => 1, disabled => 1 };
            next;
        }

        # Can we resolve a key? _resolve_api_key needs $c for session/DB; if it
        # returns nothing, the provider is configured-but-no-key.
        my $has_key = try { $prov->_resolve_api_key($c) } catch { undef };

        if ($has_key) {
            my $listed = try { $prov->list_models($c) } catch { undef };
            if ($listed && $listed->{success} && $listed->{models} && @{$listed->{models}}) {
                for my $m (@{$listed->{models}}) {
                    push @all, {
                        name     => $m->{id},
                        provider => $svc,
                        label    => ($m->{label} || $m->{id}) . " ($svc)",
                        local    => 0,
                    };
                }
                next;
            }
            # Key present but listing failed — surface the error rather than a stub.
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

    return \@all;
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
