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

# ---------------------------------------------------------------------------
# Hermes coding chain (todo #2564)
#
# The AI editor and every code-editing agent (programming, gitfix-analysis) must
# walk the SAME order Hermes itself uses, instead of letting the generic score
# pick land on whatever happens to be free — that is how a 3B vision model
# (ollama|qwen2.5vl:3b) ended up "coding" a plan.
#
# The order is READ AT REQUEST TIME from ~/.hermes/config.yaml (model.default +
# fallback_providers) and ~/.hermes/guard_model_switch.json (the guard's live
# "from"/"to"), never from a hardcoded copy: when the daily guard switches
# Hermes, this follows automatically.
# ---------------------------------------------------------------------------

# Agents that write/analyse code and therefore need a capable coding model.
sub is_coding_agent {
    my ($class, $agent) = @_;
    return 0 unless defined $agent && length $agent;
    my $a = lc $agent;
    return 1 if $a =~ /^(?:programming|coding|code|editor|implement)$/;
    return 1 if $a =~ /git[-_]?fix/;          # gitfix, gitfix-analysis, git-fix
    return 1 if $a =~ /^analy[sz]e$/ && ($ENV{AI2_ANALYZE_IS_CODING} // 1);
    return 0;
}

# The editor surface as a whole: code agents plus documentation. One definition
# so the controller, Router and ChatIntent cannot drift apart (todo #2564 — a
# gitfix-analysis request was not recognised as an editor agent, so it paid for
# the 125s LLM classifier and lost the coding route).
sub is_editor_agent {
    my ($class, $agent) = @_;
    return 0 unless defined $agent && length $agent;
    my $a = lc $agent;
    return 1 if $a =~ /^(?:documentation|docs)$/;
    return $class->is_coding_agent($a) ? 1 : 0;
}

sub hermes_chain_paths {
    my $home = $ENV{HOME} || '';
    return (
        ($ENV{HERMES_CONFIG}    || ($home ? "$home/.hermes/config.yaml"            : '')),
        ($ENV{HERMES_GUARD_SWITCH} || ($home ? "$home/.hermes/guard_model_switch.json" : '')),
    );
}

# Raw "provider/model" ids, in Hermes order, deduped.
sub hermes_chain {
    my ($self, $c) = @_;
    my ($cfg_path, $sw_path) = $self->hermes_chain_paths;

    # Parsed once per file generation (mtime+size), not per request-loop.
    my @st = map { (defined $_ && length $_ && -f $_) ? (stat _)[9, 7] : (0, 0) } $cfg_path, $sw_path;
    my $sig = join(':', @st);
    our %CHAIN_CACHE;
    if ($CHAIN_CACHE{sig} && $CHAIN_CACHE{sig} eq $sig) {
        return $CHAIN_CACHE{entries};
    }

    my (@entries, %seen, @errors);
    my $push = sub {
        my ($raw, $source) = @_;
        return unless defined $raw && length $raw;
        my ($prov, $model) = $self->_map_chain_entry($raw);
        return unless $prov && $model;
        return if $seen{"$prov|$model"}++;
        push @entries, { raw => $raw, provider => $prov, model => $model, source => $source };
    };

    my $sw;
    if ($sw_path && length $sw_path && -f $sw_path) {
        $sw = eval {
            open my $fh, '<:raw', $sw_path or die "$!\n";
            my $raw = do { local $/; <$fh> };
            close $fh;
            require JSON;
            JSON::decode_json($raw);
        };
        if (!ref $sw) {
            push @errors, 'guard_model_switch.json unreadable';
            $sw = undef;
        }
    }

    # SuperGrok head: whatever Hermes switched AWAY from is the allotment model.
    $push->($sw->{from}, 'supergrok-head') if ref $sw eq 'HASH' && $sw->{from};
    # Current Hermes model (guard switch target) comes next.
    $push->($sw->{to}, 'guard-switch') if ref $sw eq 'HASH' && $sw->{to};

    my $cfg;
    if ($cfg_path && length $cfg_path && -f $cfg_path) {
        $cfg = eval { require YAML::XS; YAML::XS::LoadFile($cfg_path) };
        if (!ref $cfg) {
            push @errors, 'config.yaml unreadable';
            $cfg = undef;
        }
    } else {
        push @errors, 'config.yaml not found';
    }

    if (ref $cfg eq 'HASH') {
        my $m = ref $cfg->{model} eq 'HASH' ? $cfg->{model} : {};
        if (($m->{default} // '') ne '') {
            $push->((($m->{provider} // 'openrouter') . '/' . $m->{default}), 'primary');
        }
        my $fb = ref $cfg->{fallback_providers} eq 'ARRAY' ? $cfg->{fallback_providers} : [];
        for my $f (@$fb) {
            next unless ref $f eq 'HASH' && ($f->{model} // '') ne '';
            $push->((($f->{provider} // 'openrouter') . '/' . $f->{model}), 'fallback');
        }
    }

    if ($c && ref $c && @errors) {
        eval {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
                'hermes_chain', 'Hermes chain partially read: ' . join('; ', @errors));
        };
    }

    $CHAIN_CACHE{sig}     = $sig;
    $CHAIN_CACHE{entries} = \@entries;
    return \@entries;
}

# "openrouter/x/y" -> (openrouter, x/y); "xai-oauth/grok-4.7" -> (supergrok, grok-4.7)
sub _map_chain_entry {
    my ($self, $raw) = @_;
    return unless defined $raw && length $raw;
    my ($p, $m) = split m{/}, $raw, 2;
    return unless defined $m && length $m;
    return ('supergrok',  $m) if $p =~ /^(?:xai-oauth|xai|supergrok|grok)$/i;
    return ('openrouter', $m) if $p =~ /^(?:openrouter|or)$/i;
    return ('ollama',     $m) if $p =~ /^(?:ollama-launch|ollama|local)$/i;
    return;
}

# Live catalog as a flat "provider|model" set. Liveness == what the providers
# actually report right now (OpenRouter models list / api cache, Ollama /api/tags).
sub live_model_set {
    my ($self, $c) = @_;
    my %live;
    my $router = eval { $c->model('AI2::Router') } or return \%live;
    my $list = eval { $router->get_available_models($c, include_ollama => 1) } || [];
    for my $m (@$list) {
        next unless ref $m eq 'HASH';
        next if $m->{disabled} || $m->{needs_key} || $m->{unreachable};
        my $prov = lc($m->{provider} || '');
        next unless $prov =~ /^(?:supergrok|openrouter|ollama)$/;
        my $name = $m->{name} || $m->{id} || '';
        next unless length $name;
        next if $name =~ /_(?:unreachable|unconfigured|error|empty)$/;
        $live{"$prov|$name"} = 1;
        (my $bare = $name) =~ s/:latest$//;
        $live{"$prov|$bare"} = 1;
    }
    return \%live;
}

# Vision-only or sub-7B: fine for classification, never for writing code.
sub is_weak_for_coding {
    my ($class, $model) = @_;
    return 1 unless defined $model && length $model;
    my $m = lc $model;
    return 1 if $m =~ /(?:^|[\/|:_-])(?:vl|vision|llava|moondream|minicpm-v|clip|bakllava)/;
    return 1 if $m =~ /qwen2\.5vl|qwen2\.?5-vl/;
    if ($m =~ /(\d+(?:\.\d+)?)\s*b(?:[:_-]|\z)/) {
        return 1 if $1 < 7;
    }
    return 0;
}

# Walk the chain in order; first entry that is live and guard-allowed wins.
# Returns (result_hashref_or_undef, log_line).
sub pick_from_chain {
    my ($self, $c, %o) = @_;
    my $chain = $o{chain} || [];
    my $live  = $o{live}  || {};
    my $guard = $o{guard} || {};
    my $agent = $o{agent} // '';
    my $phase = $o{phase} // '';

    my (@tried, $chosen);
    for my $e (@$chain) {
        my ($prov, $model) = ($e->{provider}, $e->{model});
        my $key = "$prov|$model";
        my $skip;
        if ($prov eq 'supergrok') {
            $skip = 'guard locked (' . ($guard->{reason} || 'allowance used') . ')'
                if $guard->{locked};
        }
        elsif ($prov eq 'openrouter') {
            # Paid xAI-on-OpenRouter is never a coding pick (operator rule).
            $skip = 'paid OpenRouter grok' if $model =~ m{^x-ai/}i;
            $skip ||= 'not in live catalog' unless $live->{$key};
        }
        elsif ($prov eq 'ollama') {
            (my $bare = $model) =~ s/:latest$//;
            $skip = 'not installed (absent from /api/tags)'
                unless $live->{$key} || $live->{"ollama|$bare"};
        }

        if ($skip) { push @tried, "$key ($skip)"; next }
        push @tried, "$key (live)";
        $chosen = { %$e };
        last;
    }

    my $line = sprintf('agent=%s phase=%s chain=[%s] chose=%s',
        ($agent || '(none)'), ($phase || '(none)'),
        (@tried ? join(' ', @tried) : '(empty)'),
        ($chosen ? "$chosen->{provider}|$chosen->{model}" : 'none'));

    return (undef, $line) unless $chosen;

    return ({
        ok        => 1,
        provider  => $chosen->{provider},
        model     => $chosen->{model},
        why       => 'hermes-chain:' . ($chosen->{source} || 'chain'),
        chain_used => $chosen->{raw},
        weak      => $self->is_weak_for_coding($chosen->{model}) ? 1 : 0,
    }, $line);
}

# Coding agents: Hermes chain first, then the normal catalog with a quality
# floor. Returns undef to let the caller fall through to the generic pick.
sub coding_pick {
    my ($self, $c, %ctx) = @_;
    my $agent = $ctx{agent_id} || $ctx{agent} || '';
    my $phase = $ctx{phase} || '';

    my $chain = $ctx{chain}        || $self->hermes_chain($c);
    my $live  = $ctx{live_models}  || $self->live_model_set($c);
    my $guard = $ctx{guard};
    unless (ref $guard eq 'HASH') {
        my $router = eval { $c->model('AI2::Router') };
        $guard = ($router && $router->can('supergrok_guard'))
            ? (eval { $router->supergrok_guard($c) } || {}) : {};
    }

    my ($res, $line) = $self->pick_from_chain($c,
        chain => $chain, live => $live, guard => $guard, agent => $agent, phase => $phase);

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
        'coding_chain_pick', $line);

    if ($res) {
        if ($res->{weak}) {
            # Only reachable if the guard switch itself points at a small model.
            $res->{notice} = sprintf(
                'The Hermes coding chain handed over %s, which is a small/vision model — code answers may be poor.',
                $res->{model});
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
                'coding_chain_pick', $res->{notice});
        }
        return $res;
    }

    # Chain exhausted. Allow the catalog only for models fit to write code.
    my $groups = $self->available_groups($c);
    my (@ok, @weak);
    for my $prov (qw(supergrok openrouter ollama)) {
        for my $row (@{ $groups->{$prov} || [] }) {
            my $hit = { provider => $prov, model => $row->{model}, free => $row->{free}, local => $row->{local} };
            if ($self->is_weak_for_coding($row->{model})) { push @weak, $hit }
            else { push @ok, $hit }
        }
    }
    if (@ok) {
        my $best = $self->score_pick({ supergrok => [grep { $_->{provider} eq 'supergrok' } @ok],
                                       openrouter => [grep { $_->{provider} eq 'openrouter' } @ok],
                                       ollama     => [grep { $_->{provider} eq 'ollama' } @ok] },
                                     $self->task_is_hard(%ctx));
        if ($best && $best->{provider}) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
                'coding_chain_pick', $line . " -> no live chain entry; catalog fallback $best->{provider}|$best->{model}");
            return { ok => 1, provider => $best->{provider}, model => $best->{model},
                     why => 'catalog-coding-fallback' };
        }
    }

    # Nothing capable is live. Use the least-bad model but SAY SO.
    my $last = $self->score_pick($groups, $self->task_is_hard(%ctx));
    if ($last && $last->{provider}) {
        # Rebuild the skip-reason list from the chain log line.
        (my $reasons = $line) =~ s/^.*chain=\[//;
        $reasons =~ s/\] chose=.*$//;
        my $notice = sprintf(
            'No Hermes coding model is live (%s). Using %s|%s, a small/vision model — code answers will be unreliable.',
            ($reasons || 'chain empty'), $last->{provider}, $last->{model});
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
            'coding_chain_pick', $line . " -> WEAK fallback $last->{provider}|$last->{model}: $notice");
        return { ok => 1, provider => $last->{provider}, model => $last->{model},
                 why => 'weak-last-resort', weak => 1, notice => $notice };
    }

    $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
        'coding_chain_pick', $line . ' -> nothing live at all');
    return { ok => 0, error => 'no live coding model', notice =>
        'No coding model is live right now — check OpenRouter/Ollama on /ai/usage.' };
}


sub pick {
    my ($self, $c, %ctx) = @_;
    my $agent = $ctx{agent_id} || $ctx{agent} || '';
    my $phase = $ctx{phase} || '';

    # Code-editing agents follow the Hermes chain (todo #2564) before the
    # generic score. A hand-picked model never reaches here (select_model
    # returns early for a real user pick), so this cannot override the user.
    if (!$ctx{user_picked} && $self->is_coding_agent($agent)) {
        my $coding = $self->coding_pick($c, %ctx);
        if ($coding && $coding->{ok} && $coding->{provider} && $coding->{model}) {
            return $coding;
        }
        if ($coding && $coding->{notice}) {
            # Remember the reason so the caller can tell the user instead of
            # silently falling through to a weak local model.
            $ctx{_notice} = $coding->{notice};
            if ($c && ref $c && $c->can('stash')) {
                eval { $c->stash->{ai2_model_notice} = $coding->{notice} };
            }
        }
    }

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
        "Chose $chosen->{provider}|$chosen->{model} ($why) agent=" . ($agent || '(none)')
        . ' phase=' . ($phase || '(none)')
        . " groups sg=" . scalar(@{ $groups->{supergrok} })
        . " or=" . scalar(@{ $groups->{openrouter} })
        . " ol=" . scalar(@{ $groups->{ollama} })
        . (($ctx{_notice} || '') ne '' ? " notice=$ctx{_notice}" : ''));

    return {
        ok       => 1,
        provider => $chosen->{provider},
        model    => $chosen->{model},
        why      => $why,
        (($ctx{_notice} || '') ne '' ? (notice => $ctx{_notice}) : ()),
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

        my $free = $self->is_free_step($prov, $name, catalog_free => $m->{free}) ? 1 : 0;
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

# is_free_step($provider, $model): see Comserv::Util::AI::FreeModel (single rule).
sub is_free_step {
    my ($class, @a) = @_;
    require Comserv::Util::AI::FreeModel;
    return Comserv::Util::AI::FreeModel->is_free_step(@a);
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
