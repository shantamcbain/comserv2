package Comserv::Model::AI2::Router;

use Moose;
use namespace::autoclean;

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
    chat        => ['llama3.1', 'llama3', 'deepseek-r1', 'mistral'],
    helpdesk    => ['llama3.1', 'llama3', 'mistral'],
    ency        => ['phi4', 'llama3.1', 'llama3', 'mistral'],
    bmaster     => ['phi4', 'llama3.1', 'llama3', 'mistral'],
    csc         => ['llama3.1', 'llama3', 'mistral'],
    general     => ['llama3.1', 'llama3', 'mistral'],
    navigation  => ['llama3.1', 'llama3'],
    simple      => ['llama3.1', 'llama3'],
    code        => ['starcoder2', 'qwen2.5-coder', 'qwen-coder', 'codellama', 'llama3.1'],
    developer   => ['starcoder2', 'qwen2.5-coder', 'codellama', 'llama3.1'],
    docker      => ['starcoder2', 'qwen2.5-coder', 'llama3.1'],
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

    # 6) Hardcoded safe fallback (local-first).
    return ('ollama', 'llama3.1:latest');
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

    # --- External (x.ai / OpenRouter) from configured keys ---
    try {
        my $schema = $c->model('DBEncy')->schema;
        my $rs = $schema->resultset('UserApiKeys')->search(
            { is_active => '1' },
            { order_by => 'service' },
        );
        my %seen;
        while (my $k = $rs->next) {
            my $svc = $k->service || next;
            next if $seen{$svc}++;
            push @all, {
                name     => $svc,
                provider => $svc,   # grok / openai / openrouter
                label    => ucfirst($svc) . ' (external)',
                local    => 0,
            };
        }
    } catch {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
            'get_available_models', "External key read failed: $_");
    };

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
