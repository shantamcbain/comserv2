package Comserv::Model::AI2::ModelPick;

use Moose;
use namespace::autoclean -except => [qw(try catch finally)];
use Try::Tiny;

use Comserv::Util::Logging;

has 'logging' => (
    is      => 'ro',
    lazy    => 1,
    default => sub { Comserv::Util::Logging->instance },
);

=head1 NAME

Comserv::Model::AI2::ModelPick - choose a chat model from what is actually available

SuperGrok (prepaid), OpenRouter, and Ollama are three groups. xAI pay-per-token
is not a group. A model that is not in the live catalog, whose provider is
locked or unreachable, or that the operator killed, is not a choice.

For a hard task, a small installed Ollama model may pick among the candidates
(Ollama C<decide>). If that eval is down or times out, a local score picks
from the same list. The score never invents a slug.

=cut

# Dropdown auto-pins. These are not a user choice.
sub is_auto_pin {
    my ($class, $model) = @_;
    return 0 unless defined $model && length $model;
    $model =~ s/^[^|]+\|//;
    return $model =~ /^(?:cohere\/north-mini-code:free|nimble|tev1(?::[\d.]+b)?)$/i ? 1 : 0;
}

sub task_is_hard {
    my ($class, %ctx) = @_;
    return 1 if ($ctx{route} || '') eq 'escalate';
    return 1 if ($ctx{phase} || '') eq 'implement';
    my $p = $ctx{prompt} || $ctx{task} || '';
    return 1 if $p =~ /merge conflict|<<<<<<<|unmerged paths|fix that problem|resolve the (commit|merge|conflict)/i;
    return 0;
}

sub pick {
    my ($self, $c, %ctx) = @_;
    my $groups = $self->available_groups($c);
    my $n = 0;
    $n += scalar @{ $groups->{$_} || [] } for qw(supergrok openrouter ollama);
    unless ($n) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'pick',
            'No chat model available in supergrok, openrouter, or ollama');
        return { ok => 0, error => 'no available models' };
    }

    my $hard = $self->task_is_hard(%ctx);
    my $chosen;
    my $why = '';

    if ($hard && @{ $groups->{ollama} || [] } > 0 && $n > 1) {
        my $eval = $self->eval_with_ollama($c, $groups, $hard, \%ctx);
        if ($eval && $eval->{provider} && $eval->{model}) {
            $chosen = $eval;
            $why = 'ollama-eval via ' . ($eval->{eval_model} || 'local');
        }
        elsif ($eval && $eval->{error}) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'pick',
                "Ollama model eval failed, using score: $eval->{error}");
        }
    }

    unless ($chosen && $chosen->{provider}) {
        $chosen = $self->score_pick($groups, $hard);
        $why = $hard ? 'score:hard' : 'score:light';
    }

    unless ($chosen && $chosen->{provider} && $chosen->{model}) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'pick',
            'Score returned no model from a non-empty catalog');
        return { ok => 0, error => 'pick failed' };
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'pick',
        "Chose $chosen->{provider}|$chosen->{model} ($why) "
        . "groups sg=" . scalar(@{ $groups->{supergrok} })
        . " or=" . scalar(@{ $groups->{openrouter} })
        . " ol=" . scalar(@{ $groups->{ollama} }));

    return {
        ok       => 1,
        provider => $chosen->{provider},
        model    => $chosen->{model},
        why      => $why,
    };
}

# Live catalog, three groups, resource filters applied.
sub available_groups {
    my ($self, $c) = @_;
    my %groups = ( supergrok => [], openrouter => [], ollama => [] );

    my $router = eval { $c->model('AI2::Router') };
    unless ($router && $router->can('get_available_models')) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'available_groups',
            'Router get_available_models unavailable');
        return \%groups;
    }

    my $list = eval { $router->get_available_models($c, include_ollama => 1) } || [];
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'available_groups',
            "Catalog probe failed: $@");
        $list = [];
    }

    my $guard = ($router->can('supergrok_guard'))
        ? eval { $router->supergrok_guard($c) } : {};
    $guard = {} unless ref $guard eq 'HASH';
    my $sg_locked = $guard->{locked} ? 1 : 0;
    if ($sg_locked) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'available_groups',
            'SuperGrok locked (' . ($guard->{reason} || 'guard') . ') — omitted from choices');
    }

    my $priv = $self->_is_priv($c);
    my %seen;

    for my $m (@$list) {
        next unless $m && ref $m eq 'HASH';
        next if $m->{disabled} || $m->{needs_key} || $m->{unreachable};
        my $prov = lc($m->{provider} || '');
        # Pay-per-token xAI is not a routing group on this host.
        next if $prov eq 'grok';
        next unless $prov =~ /^(supergrok|openrouter|ollama)$/;
        next if $prov eq 'supergrok' && $sg_locked;
        next if $prov eq 'supergrok' && !$priv;

        my $name = $m->{name} || $m->{id} || '';
        $name =~ s/^[^|]+\|//;
        next unless length $name;
        next if $name =~ /_(?:unreachable|unconfigured|error|empty)$/;
        next if $name =~ /embed|rerank|whisper|tts|imagine|clip|bge|nomic/i;
        next if $router->can('_is_chat_model') && !$router->_is_chat_model($name);

        if ($router->can('_model_is_killed') && $router->_model_is_killed($c, $prov, $name)) {
            next;
        }

        my $free = $m->{free} || $name =~ /:free$/i ? 1 : 0;
        # OpenRouter has no auto-fill. Unknown or non-zero price is not "available
        # budget" for an automatic pick.
        next if $prov eq 'openrouter' && !$free;

        my $key = "$prov|$name";
        next if $seen{$key}++;
        push @{ $groups{$prov} }, {
            provider => $prov,
            model    => $name,
            free     => $free,
            local    => $prov eq 'ollama' ? 1 : 0,
        };
    }

    return \%groups;
}

# Smallest installed local model classifies the task. 20s cap — a cold large
# model must not block the editor turn; the score path runs if this fails.
sub eval_with_ollama {
    my ($self, $c, $groups, $hard, $ctx) = @_;
    my $eval_model = $self->_eval_model($groups->{ollama} || []);
    unless ($eval_model) {
        return { error => 'no small Ollama model for eval' };
    }

    my @pool = (
        @{ $groups->{supergrok} || [] },
        @{ $self->_cap($groups->{openrouter} || [], 24) },
        @{ $groups->{ollama} || [] },
    );
    return { error => 'empty eval pool' } unless @pool;

    my %criteria;
    my %by_key;
    my $i = 0;
    for my $cand (@pool) {
        $i++;
        my $key = 'm' . $i;
        $by_key{$key} = $cand;
        $criteria{$key} = $cand->{provider} . '|' . $cand->{model}
            . ($cand->{local} ? ' local' : '')
            . ($cand->{free} ? ' free' : '')
            . ($cand->{provider} eq 'supergrok' ? ' prepaid-capped' : '');
    }

    my $task = substr($ctx->{prompt} || $ctx->{task} || '', 0, 800);
    $task =~ s/\s+/ /g;
    my $state = ($hard ? 'Hard coding task. ' : 'Light task. ')
        . 'Pick the one available model most likely to finish it. '
        . 'Do not pick a model that is not listed. '
        . 'SuperGrok is prepaid and may be out of weekly budget — use it only when the task needs it. '
        . 'A trivial lookup should stay on a free or local model. '
        . "Task: $task";

    my $ollama = eval { $c->model('AI2::Provider::Ollama') };
    unless ($ollama && $ollama->can('decide')) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'eval_with_ollama',
            'Ollama decide() unavailable');
        return { error => 'decide unavailable' };
    }

    my $res = eval {
        $ollama->decide($c,
            model   => $eval_model,
            timeout => 20,
            state   => $state,
            questions => {
                pick => {
                    type         => 'choice',
                    instructions => 'Which listed model should do this task?',
                    criteria     => \%criteria,
                },
            },
        );
    };
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'eval_with_ollama',
            "decide threw: $@");
        return { error => "decide threw: $@" };
    }
    unless ($res && $res->{success}) {
        return { error => ($res && $res->{error}) || 'decide failed' };
    }

    my $key = '';
    my $answers = $res->{answers};
    if (ref $answers eq 'HASH') {
        my $pick = $answers->{pick};
        $key = ref $pick eq 'HASH' ? ($pick->{value} || $pick->{choice} || $pick->{answer} || '') : ($pick || '');
    }
    my $cand = $by_key{$key};
    unless ($cand) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'eval_with_ollama',
            "decide returned '$key' which is not in the candidate set");
        return { error => 'eval choice not in catalog' };
    }

    return {
        provider   => $cand->{provider},
        model      => $cand->{model},
        eval_model => $eval_model,
    };
}

sub score_pick {
    my ($self, $groups, $hard) = @_;
    $groups ||= {};
    my $sg = $groups->{supergrok} || [];
    my $or = $groups->{openrouter} || [];
    my $ol = $groups->{ollama} || [];

    if ($hard) {
        return $sg->[0] if @$sg;
        my ($code) = grep { $_->{model} =~ /code|coder|hy3|north-mini/i } @$or;
        return $code if $code;
        return $or->[0] if @$or;
        return $self->_largest_local($ol) if @$ol;
        return;
    }

    my $small = $self->_eval_model($ol);
    if ($small) {
        my ($row) = grep { $_->{model} eq $small } @$ol;
        return $row if $row;
    }
    return $ol->[0] if @$ol;
    return $or->[0] if @$or;
    return $sg->[0] if @$sg;
    return;
}

sub _eval_model {
    my ($self, $ol) = @_;
    return '' unless $ol && @$ol;
    my @names = map { $_->{model} } @$ol;
    for my $want (qw(tev1:0.8b tev1:4b nimble phi4:14b)) {
        return $want if grep { $_ eq $want } @names;
    }
    for my $n (@names) {
        return $n if $n =~ /(?:^|:)(0\.8b|1b|1\.5b|3b|4b)\b/i || $n =~ /^(tev1|nimble)/i;
    }
    return '';
}

sub _largest_local {
    my ($self, $ol) = @_;
    my $best = $ol->[0];
    my $best_n = 0;
    for my $row (@$ol) {
        my $n = 0;
        $n = $1 if ($row->{model} || '') =~ /(\d+(?:\.\d+)?)b/i;
        if ($n >= $best_n) {
            $best = $row;
            $best_n = $n;
        }
    }
    return $best;
}

sub _cap {
    my ($self, $list, $max) = @_;
    return [] unless $list && @$list;
    return $list if @$list <= $max;
    return [ @{$list}[ 0 .. $max - 1 ] ];
}

sub _is_priv {
    my ($self, $c) = @_;
    my $roles = eval { $c->session->{roles} } || [];
    $roles = [ split(/\s*,\s*/, $roles) ] unless ref $roles;
    return ( grep { $_ =~ /^(admin|developer)$/i } @$roles ) ? 1 : 0;
}

__PACKAGE__->meta->make_immutable;

1;
