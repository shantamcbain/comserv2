package Comserv::Model::AI::ModelManager;
use Moose;
use namespace::autoclean -except => [qw(try catch finally)];  # keep Try::Tiny subs (Perl 5.40)
use Try::Tiny;
use JSON;
use Comserv::Util::Logging;

has 'logging' => (
    is      => 'ro',
    lazy    => 1,
    default => sub { Comserv::Util::Logging->instance },
);

=head1 NAME

Comserv::Model::AI::ModelManager - Safe, centralized retrieval of available AI models

=head1 DESCRIPTION

This replaces the crashy inline code that used to live in AI.pm index/chat
that queried UserApiKeys, parsed metadata, and hardcoded fallbacks on every request.

Key improvements from the main branch fixes:
- No heavy work in page load paths unless explicitly asked.
- Graceful degradation.
- Separate concerns: listing vs. using a model.
- Supports Ollama + external providers (grok, openai, groq, etc.) via DB keys.
- Filters retired / non-chat models.

=cut

=head2 get_available_models

    my $models = $mgr->get_available_models($c, %opts);

%opts:
    can_select_model => 0/1   (from roles)
    include_local      => 1   (default)
    include_external   => 1   (default)

Returns arrayref of { name, provider, label, ... }

This is the method that was introduced to stop the crashes.

=cut

sub get_available_models {
    my ($self, $c, %opts) = @_;

    my $can_select = $opts{can_select_model} // 0;
    my $include_local = exists $opts{include_local} ? $opts{include_local} : 1;
    my $include_external = exists $opts{include_external} ? $opts{include_external} : 1;

    my @models = ();

    # --- Local Ollama models (safe, fast check) ---
    if ($include_local) {
        eval {
            my $ollama = $c->model('Ollama');
            # Use a very short timeout so we never hang the UI
            my $test = Comserv::Model::Ollama->new(
                host    => $ollama->host,
                port    => $ollama->port,
                timeout => 2
            );
            if ($test && $test->check_connection()) {
                my $list = $ollama->list_models() || [];
                for my $m (@$list) {
                    my $name = ref($m) ? ($m->{name} || $m) : $m;
                    next unless $name;
                    push @models, {
                        name     => $name,
                        provider => 'ollama',
                        label    => "$name (local)",
                        local    => 1,
                    };
                }
            }
        };
        if ($@) {
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__,
                'get_available_models', "Ollama not reachable for model list: $@");
        }
    }

    # --- External providers via UserApiKeys (the part that used to crash) ---
    if ($include_external) {
        my $user_id = $c->session->{user_id};
    return () unless $user_id;

        eval {
            my $schema = $c->model('DBEncy')->schema;
            return unless $schema;

            my $is_admin = $can_select;  # reuse the flag

            # Get distinct active services the user (or any for admin) has keys for
            my $key_rs = $schema->resultset('UserApiKeys')->search({
                is_active => 1,
                $is_admin ? () : (user_id => $user_id),
            }, {
                columns  => ['service'],
                distinct => 1,
            });

            while (my $k = $key_rs->next) {
                my $service = lc($k->service || '');
                next unless $service;

                # Fetch one key (prefer user's, then any for admins)
                my $key_obj;
                if ($is_admin) {
                    $key_obj = $schema->resultset('UserApiKeys')->search(
                        { service => $service, is_active => 1 },
                        { order_by => { -desc => 'user_id = ?' } }  # prefer own if present
                    )->first;
                } else {
                    $key_obj = $schema->resultset('UserApiKeys')->search(
                        { user_id => $user_id, service => $service, is_active => 1 }
                    )->first;
                }
                next unless $key_obj && $key_obj->api_key_encrypted;

                my $meta = eval { $key_obj->get_metadata() } || {};
                my $synced = $meta->{available_models};

                if ($synced && ref($synced) eq 'ARRAY' && @$synced) {
                    for my $m (@$synced) {
                        my $id = $m->{id} || $m->{name} || '';
                        next unless $id;
                        next if $self->_is_retired_model($service, $id);
                        my $label = $self->_make_label($service, $id);
                        push @models, {
                            name     => $id,
                            provider => $service,
                            label    => $label,
                            external => 1,
                        };
                    }
                } else {
                    # Safe hardcoded fallbacks per provider (never crash on empty)
                    push @models, $self->_default_models_for_service($service);
                }
            }
        };
        if ($@) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
                'get_available_models', "Error fetching external models (safe fallback used): $@");
        }
    }

    # Deduplicate by name+provider
    my %seen;
    @models = grep { !$seen{ ($_->{provider}||'') . '::' . ($_->{name}||'') }++ } @models;

    return \@models;
}

sub _is_retired_model {
    my ($self, $service, $id) = @_;
    $id = lc($id // '');
    return 1 if $id =~ /^grok-(imagine|video)/;
    return 1 if $id =~ /^grok-build-/;          # retired in later fixes
    return 1 if $id =~ /deprecated|retired/i;
    return 0;
}

sub _make_label {
    my ($self, $service, $id) = @_;
    my $label = $id;
    $label =~ s/-/ /g;
    $label = ucfirst($label);
    return "$label (" . ucfirst($service) . ")";
}

sub _default_models_for_service {
    my ($self, $service) = @_;
    $service = lc($service // '');

    if ($service eq 'grok' || $service eq 'xai') {
        return (
            { name => 'grok-4-fast-reasoning',     provider => 'grok', label => 'Grok 4 Fast Reasoning (xAI)', external => 1 },
            { name => 'grok-4-fast-non-reasoning', provider => 'grok', label => 'Grok 4 Fast (xAI)', external => 1 },
            { name => 'grok-3',                    provider => 'grok', label => 'Grok 3 (xAI)', external => 1 },
            { name => 'grok-3-mini',               provider => 'grok', label => 'Grok 3 Mini (xAI)', external => 1 },
        );
    }

    if ($service eq 'openai') {
        return (
            { name => 'gpt-4o', provider => 'openai', label => 'GPT-4o (OpenAI)', external => 1 },
            { name => 'gpt-4o-mini', provider => 'openai', label => 'GPT-4o Mini (OpenAI)', external => 1 },
        );
    }

    if ($service eq 'groq') {
        return (
            { name => 'llama3-70b-8192', provider => 'groq', label => 'Llama 3 70B (Groq)', external => 1 },
            { name => 'mixtral-8x7b-32768', provider => 'groq', label => 'Mixtral 8x7B (Groq)', external => 1 },
        );
    }

    return ();
}

=head2 get_external_models

Thin wrapper that returns only external (non-local) models.
Used by Controller::AI::index to populate the external dropdown.

=cut

sub get_external_models {
    my ($self, $c) = @_;
    my $all = $self->get_available_models($c,
        include_local    => 0,
        include_external => 1,
    );
    return grep { $_->{external} } @$all;
}


1;

__PACKAGE__->meta->make_immutable;