package Comserv::Model::AI2::UsageMonitor;

use Moose;
use namespace::autoclean -except => [qw(try catch finally)];
use Try::Tiny;
use JSON qw(decode_json encode_json);
use JSON::PP ();
use DateTime;

use Comserv::Util::Logging;

extends 'Catalyst::Model';

has 'logging' => (
    is      => 'ro',
    lazy    => 1,
    default => sub { Comserv::Util::Logging->instance },
);
has 'schema_override'       => ( is => 'rw', default => undef );
has 'golden_store_override' => ( is => 'rw', default => undef );

# Diagnostic rows that are not user AI calls (same exclusions as Usage.pm).
use constant EXCLUDED_REQUEST_TYPES => qw(grok_balance_check provider_snapshot openrouter_call);
use constant METADATA_SCAN_ROWS     => 2000;

# Agent-effectiveness verdict thresholds. Deliberately few and explicit: a
# pairing is only called out when there is enough evidence to act on it, and the
# card states the rule so a call-out is never a black box. Tune here, not in the
# template. These must be declared before first use (strict subs resolves the
# bareword at compile time), hence their position at the top of the file.
use constant EFF_MIN_CALLS_FOR_VERDICT => 10;    # below this, do not judge
use constant EFF_OK_RATE_REPLACE       => 80;    # % of calls that succeeded
use constant EFF_OK_RATE_WATCH         => 95;
use constant EFF_FLAG_PER_CALL_WATCH   => 0.01;  # flagged sentences per call
use constant EFF_FLAG_PER_CALL_REPLACE => 0.50;

sub _schema {
    my ($self, $c) = @_;
    return $self->schema_override if $self->schema_override;
    return $c->model('DBEncy')->schema;
}

sub _log {
    my ($self, $c, $level, $sub, $msg) = @_;
    eval { $self->logging->log_with_details($c, $level, __FILE__, __LINE__, $sub, $msg) };
}

sub _since {
    my ($self, $days) = @_;
    $days = 14 unless $days && $days =~ /^\d+$/;
    $days = 90 if $days > 90;
    return ($days, DateTime->now->subtract(days => $days)->ymd . ' 00:00:00');
}

sub _base_rs {
    my ($self, $c, $since, $extra) = @_;
    my $cond = {
        'me.created_at'   => { '>=' => $since },
        'me.request_type' => [ -or => { -not_in => [ EXCLUDED_REQUEST_TYPES ] }, undef ],
        # Overrun-guard trip/restore rows are ops events, not AI call outcomes
        # (they were dragging ok_rate down as "errors" with 0 tokens).
        'me.status'       => { -not_in => [qw(trip restore)] },
    };
    if ($extra && ref $extra eq 'HASH') {
        $cond->{$_} = $extra->{$_} for keys %$extra;
    }
    return $self->_schema($c)->resultset('AiUsageLog')->search($cond);
}

sub _grouped {
    my ($self, $rs, $keys, $key_as) = @_;
    my @rows;
    my $g = $rs->search({}, {
        select   => [ @$keys,
                      { count => 'me.id',                 -as => 'calls' },
                      { sum   => 'me.total_tokens',       -as => 'tokens' },
                      { sum   => 'me.prompt_tokens',      -as => 'prompt_tokens' },
                      { sum   => 'me.completion_tokens',  -as => 'completion_tokens' },
                      { sum   => 'me.estimated_cost_usd', -as => 'cost' } ],
        as       => [ @$key_as, qw(calls tokens prompt_tokens completion_tokens cost) ],
        group_by => $keys,
    });
    while (my $r = $g->next) {
        push @rows, { map { $_ => $r->get_column($_) } (@$key_as, qw(calls tokens prompt_tokens completion_tokens cost)) };
    }
    return \@rows;
}

sub org_summary {
    my ($self, $c, %a) = @_;
    my ($days, $since) = $self->_since($a{days});
    my $extra = {};
    $extra->{'me.provider'} = $a{provider} if $a{provider};
    $extra->{'me.site_id'}  = $a{site_id}  if $a{site_id};
    $extra->{'me.model'}    = { like => '%' . $a{model} . '%' } if $a{model};

    my $out = {
        days   => $days,
        since  => $since,
        totals => { calls => 0, ok => 0, errors => 0, tokens => 0, prompt_tokens => 0,
                    completion_tokens => 0, cost => 0 },
        by_day => [], by_model => [], by_user => [], by_site => [],
        by_source => [], combinations => [], anomalies => [], recent => [],
        daily_eval => undef, hermes => {}, errors => [],
    };

    try {
        my $rs = $self->_base_rs($c, $since, $extra);
        my $day_fn = { date => 'me.created_at' };

        my $by_day_status = $self->_grouped($rs, [ $day_fn, 'me.status' ], [qw(day status)]);
        my %d;
        for my $r (@$by_day_status) {
            my $row = $d{ $r->{day} } ||= {
                day => $r->{day}, calls => 0, ok => 0, errors => 0,
                tokens => 0, prompt_tokens => 0, completion_tokens => 0, cost => 0,
            };
            $row->{calls}             += $r->{calls} || 0;
            $row->{tokens}            += $r->{tokens} || 0;
            $row->{prompt_tokens}     += $r->{prompt_tokens} || 0;
            $row->{completion_tokens} += $r->{completion_tokens} || 0;
            $row->{cost}              += $r->{cost} || 0;
            (($r->{status} // '') eq 'success')
                ? ($row->{ok} += $r->{calls})
                : ($row->{errors} += $r->{calls});
        }
        $out->{by_day} = [ map { $d{$_} } sort { $a cmp $b } keys %d ];

        my $by_pm = $self->_grouped($rs, [ 'me.provider', 'me.model', 'me.status' ], [qw(provider model status)]);
        my %m;
        for my $r (@$by_pm) {
            my $k = join("\t", $r->{provider} // '', $r->{model} // '');
            my $row = $m{$k} ||= {
                provider => $r->{provider}, model => $r->{model},
                calls => 0, ok => 0, errors => 0, tokens => 0, cost => 0,
            };
            $row->{calls}  += $r->{calls} || 0;
            $row->{tokens} += $r->{tokens} || 0;
            $row->{cost}   += $r->{cost} || 0;
            (($r->{status} // '') eq 'success')
                ? ($row->{ok} += $r->{calls})
                : ($row->{errors} += $r->{calls});
        }
        $out->{by_model} = [ sort { ($b->{calls}||0) <=> ($a->{calls}||0) } values %m ];

        my $by_src = $self->_grouped($rs, [ 'me.request_type' ], ['request_type']);
        $out->{by_source} = [ sort { ($b->{calls}||0) <=> ($a->{calls}||0) } @$by_src ];

        $out->{by_user} = $self->_by_user($rs);
        $out->{by_site} = $self->_by_site($c, $rs);
        $out->{combinations} = $self->_combinations($rs);
        $out->{recent} = $self->_recent($rs, 40);
        $out->{daily_eval} = $self->_latest_eval($c);

        for my $r (@{ $out->{by_day} }) {
            $out->{totals}{$_} += $r->{$_} || 0
                for qw(calls ok errors tokens prompt_tokens completion_tokens cost);
        }
        $self->_effectiveness($out);
        $out->{anomalies} = $self->_anomalies($c, $out, $rs);
    } catch {
        push @{ $out->{errors} }, "App ledger aggregation failed: $_";
        $self->_log($c, 'error', 'org_summary', "Ledger aggregation failed: $_");
    };

    $out->{hermes} = $self->hermes_summary($c, days => $days);
    $self->_merge_org_totals($out);
    $out->{agents} = $self->agents_active($c, $out->{hermes});
    $out->{openrouter} = $self->openrouter_live($c);
    $out->{supergrok_week} = $self->supergrok_week_from_hermes($c);
    $out->{failure_buckets} = eval { $self->failure_buckets($c, days => $days) } || { buckets => [], errors => ["$@"] };


    for my $r (@{ $out->{by_day} }, @{ $out->{by_model} }, @{ $out->{by_user} },
               @{ $out->{by_site} }, @{ $out->{by_source} }, @{ $out->{combinations} }) {
        next unless ref $r eq 'HASH';
        $r->{cost} = sprintf('%.4f', $r->{cost} || 0);
        $r->{ok_rate} = $r->{calls} ? sprintf('%.1f', 100 * ($r->{ok} || 0) / $r->{calls}) : '0.0';
        $r->{cost_per_ok} = ($r->{ok} && $r->{ok} > 0)
            ? sprintf('%.5f', ($r->{cost} || 0) / $r->{ok}) : '0.00000';
    }
    $out->{totals}{cost} = sprintf('%.4f', $out->{totals}{cost} || 0);
    $out->{org_totals}{cost} = sprintf('%.4f', $out->{org_totals}{cost} || 0)
        if $out->{org_totals};

    try {
        require Comserv::Model::AI2::KillSwitch;
        $out->{kill_switch} = Comserv::Model::AI2::KillSwitch->new->load($c);
    } catch {
        $out->{kill_switch} = { killed => [], error => "$_" };
    };

    return $out;
}

sub _effectiveness {
    my ($self, $out) = @_;
    for my $r (@{ $out->{by_model} || [] }) {
        my $calls = $r->{calls} || 0;
        my $cost  = $r->{cost}  || 0;
        $r->{avg_tokens} = $calls ? int(($r->{tokens} || 0) / $calls) : 0;
        $r->{error_rate} = $calls
            ? sprintf('%.1f', 100 * ($r->{errors} || 0) / $calls)
            : '0.0';
        # Money per successful call — the cost-effectiveness headline. A cheap
        # model that fails half its calls is worse than a dear one that works,
        # and raw totals hide that. undef when nothing succeeded (no ratio).
        $r->{cost_per_ok} = ($r->{ok} || 0) ? sprintf('%.4f', $cost / $r->{ok}) : undef;
    }
    return $out;
}

=head2 agent_effectiveness($c, %a)

Per-agent cost-effectiveness: which model is doing what work, for which
agent, at what cost, at what speed, and how often it fails.

The ledger's C<by_model> answers "what did each model cost"; this answers
"is that agent+model pairing worth keeping", which is the question a model
switch decision actually needs:

  calls / ok / errors / error_rate   quality + reliability
  cost / cost_per_ok                 money, normalised per success
  avg_tokens                         prompt weight
  avg_ms                             time (NULL-safe: averaged over the
                                     calls that recorded a duration only)

The agent dimension is C<feature> (the true calling feature, e.g. ai2_chat)
when schema-compare has added it, else C<request_type> which is always in the
AiUsageLog default SELECT. C<source> in the result says which was used, so a
reader can tell whether the agent column is exact or approximate.

=cut

sub agent_effectiveness {
    my ($self, $c, %a) = @_;
    my ($days, $since) = $self->_since($a{days});
    my $out = {
        days => $days, since => $since, source => 'request_type',
        by_agent => [], worst => [], totals => {}, errors => [],
    };

    try {
        my ($agent_col, $src) = $self->_agent_column($c);
        $out->{source} = $src;

        my $rs   = $self->_base_rs($c, $since);
        my $rows = $self->_eff_rows($rs, $agent_col);

        # Quality (grounded / flagged) is recorded per call, so it is folded in
        # as a second grouping rather than as extra metrics on the first query.
        my $qual = $self->_eff_quality($c, $rs, $agent_col);
        $out->{quality_source} = $qual->{source};

        my %agent;
        my @pairs;
        my $tot = { calls => 0, ok => 0, errors => 0, tokens => 0, cost => 0,
                    ms => 0, ms_n => 0, flagged => 0, recorded => 0,
                    grounded => 0, golden_hits => 0 };
        for my $k (keys %$rows) {
            my $raw = $rows->{$k};
            my $q = $qual->{by_pair}{$k};
            if ($q) {
                $raw->{$_} = $q->{$_} || 0 for qw(recorded grounded flagged golden_hits);
            }
            my $a = $agent{ $raw->{agent} } ||= {
                agent => $raw->{agent}, calls => 0, ok => 0, errors => 0,
                tokens => 0, cost => 0, ms => 0, ms_n => 0, flagged => 0,
                recorded => 0, grounded => 0, golden_hits => 0, models => [],
            };
            $self->_eff_add($a,   $raw);
            $self->_eff_add($tot, $raw);
            my $calc = $self->_eff_calc($raw);
            push @{ $a->{models} }, $calc;
            push @pairs, $calc;
        }

        for my $a (values %agent) {
            my $calc = $self->_eff_calc($a);
            $calc->{models} = [ sort { ($b->{ok} || 0) <=> ($a->{ok} || 0) }
                                @{ $a->{models} } ];
            push @{ $out->{by_agent} }, $calc;
        }
        $out->{by_agent} = [ sort { ($b->{calls} || 0) <=> ($a->{calls} || 0) }
                             @{ $out->{by_agent} } ];

        # "Which combinations are wasting our time and money" — pairs worth
        # acting on, worst first. cost_wasted is real spend that bought a failed
        # call (a failure still burns tokens), so it is a number, not a label.
        $out->{worst} = [
            sort { ($b->{cost_wasted} || 0) <=> ($a->{cost_wasted} || 0)
                   || ($b->{calls} || 0) <=> ($a->{calls} || 0) }
            grep { $_->{verdict} eq 'replace' || $_->{verdict} eq 'watch' }
            grep { ($_->{calls} || 0) >= EFF_MIN_CALLS_FOR_VERDICT }
            @pairs
        ];
        $out->{totals} = $self->_eff_calc($tot);
    } catch {
        push @{ $out->{errors} }, "Agent effectiveness failed: $_";
        $self->_log($c, 'error', 'agent_effectiveness', "Agent effectiveness failed: $_");
    };

    return $out;
}

# Grounded / flagged tallies per agent x provider x model, from whichever
# source is available: the Ledger columns once schema-compare has added them,
# else a bounded newest-first scan of metadata.grounding — the same dual-source
# approach as grounding_summary, so the card works before and after migration.
# Never dies: on failure the pairs carry no quality data and the verdict falls
# back to reliability + cost alone.
sub _eff_quality {
    my ($self, $c, $rs, $agent_col) = @_;
    my %by_pair;
    my $source = 'none';

    try {
        require Comserv::Util::AI::Ledger;
        if (Comserv::Util::AI::Ledger->columns_present($self->_schema($c))) {
            my $q = $rs->search({ 'me.grounded' => { '!=' => undef } }, {
                select   => [ $agent_col, 'me.provider', 'me.model', 'me.grounded',
                              { count => 'me.id',              -as => 'n' },
                              { sum   => 'me.flagged_count',    -as => 'fl' },
                              { sum   => 'me.golden_hit_count', -as => 'gh' } ],
                as       => [qw(agent provider model grounded n fl gh)],
                group_by => [ $agent_col, 'me.provider', 'me.model', 'me.grounded' ],
            });
            while (my $r = $q->next) {
                my $key = join("\t",
                    $r->get_column('agent')    // '(none)',
                    $r->get_column('provider') // '',
                    $r->get_column('model')    // '');
                my $p = $by_pair{$key}
                     ||= { recorded => 0, grounded => 0, flagged => 0, golden_hits => 0 };
                # Each group row is one (agent,provider,model,grounded) bucket.
                # recorded/grounded must be call counts, not bucket counts —
                # otherwise a pair with both grounded=0 and grounded=1 reads as
                # recorded=2 regardless of how many calls it actually had.
                my $n = $r->get_column('n') || 0;
                $p->{recorded}    += $n;
                $p->{grounded}    += $r->get_column('grounded') ? $n : 0;
                $p->{flagged}     += $r->get_column('fl') || 0;
                $p->{golden_hits} += $r->get_column('gh') || 0;
            }
            $source = 'columns';
        }
        else {
            # Pre-migration: tally metadata.grounding, bounded scan newest first.
            my $q = $rs->search({ 'me.metadata' => { -like => '%"grounding"%' } }, {
                columns  => [ $agent_col, 'me.provider', 'me.model', 'me.metadata' ],
                order_by => { -desc => 'me.id' },
                rows     => METADATA_SCAN_ROWS,
            });
            while (my $r = $q->next) {
                my $m = eval { decode_json($r->get_column('metadata') // '') } or next;
                my $gr = ref $m eq 'HASH' ? $m->{grounding} : undef;
                next unless ref $gr eq 'HASH';
                my $key = join("\t",
                    $r->get_column('agent')    // '(none)',
                    $r->get_column('provider') // '',
                    $r->get_column('model')    // '');
                my $p = $by_pair{$key}
                     ||= { recorded => 0, grounded => 0, flagged => 0, golden_hits => 0 };
                $p->{recorded}++;
                $p->{grounded}    += $gr->{grounded}           ? 1 : 0;
                $p->{flagged}     += $gr->{flagged_count}      || 0;
                $p->{golden_hits} += $gr->{golden_hit_count}   || 0;
            }
            $source = 'metadata';
        }
    } catch {
        $self->_log($c, 'warn', '_eff_quality', "Quality tally failed: $_");
    };

    return { source => $source, by_pair => \%by_pair };
}

sub _eff_add {
    my ($self, $into, $from) = @_;
    $into->{$_} += $from->{$_} || 0
        for qw(calls ok errors tokens cost ms ms_n flagged recorded grounded golden_hits);
    return $into;
}

# Verdict thresholds live at the top of the file (strict subs needs the
# barewords declared before first use).

sub _eff_calc {
    my ($self, $r) = @_;
    my $calls = $r->{calls} || 0;
    my $cost  = $r->{cost}  || 0;
    my $ok    = $r->{ok}    || 0;
    my $errors= $r->{errors}|| 0;
    my $ok_rate = $calls ? sprintf('%.1f', 100 * $ok / $calls) : '0.0';
    my $flag_pc = ($r->{recorded} && $r->{flagged})
        ? sprintf('%.3f', $r->{flagged} / $r->{recorded}) : undef;

    my $out = {
        %$r,
        ok_rate      => $ok_rate,
        error_rate   => $calls ? sprintf('%.1f', 100 * $errors / $calls) : '0.0',
        avg_tokens   => $calls ? int(($r->{tokens} || 0) / $calls) : 0,
        avg_ms       => ($r->{ms_n} || 0) ? int(($r->{ms} || 0) / $r->{ms_n}) : undef,
        cost         => sprintf('%.4f', $cost),
        # Money per successful call: the value-for-money headline. undef when
        # nothing succeeded — there is no ratio to quote.
        cost_per_ok  => $ok ? sprintf('%.4f', $cost / $ok) : undef,
        # Spend that bought a failure. A failed call still burns tokens.
        cost_wasted  => sprintf('%.4f', $calls ? $cost * $errors / $calls : 0),
        flagged_per_call => $flag_pc,
        grounded_rate    => $r->{recorded}
            ? sprintf('%.1f', 100 * ($r->{grounded} || 0) / $r->{recorded}) : undef,
    };
    my ($verdict, $why) = $self->_eff_verdict($out);
    $out->{verdict} = $verdict;
    $out->{why}     = $why;
    return $out;
}

# Turn the numbers into a decision. Only three outcomes, and every one is
# explained in words so the page says WHY a pairing is called out.
sub _eff_verdict {
    my ($self, $r) = @_;
    return ('unknown', 'too few calls to judge')
        if ($r->{calls} || 0) < EFF_MIN_CALLS_FOR_VERDICT;

    my $sev = 0;   # 0 = keep, 1 = watch, 2 = replace
    my @why;

    my $ok_rate = $r->{ok_rate} + 0;
    if ($ok_rate < EFF_OK_RATE_REPLACE) {
        $sev = 2;
        push @why, sprintf('only %.1f%% of calls succeeded', $ok_rate);
    }
    elsif ($ok_rate < EFF_OK_RATE_WATCH) {
        $sev = 1 if $sev < 1;
        push @why, sprintf('%.1f%% of calls succeeded', $ok_rate);
    }

    if (defined $r->{flagged_per_call}) {
        my $f = $r->{flagged_per_call} + 0;
        if ($f >= EFF_FLAG_PER_CALL_REPLACE) {
            $sev = 2;
            push @why, sprintf('%.2f uncited sentences flagged per call (hallucination)', $f);
        }
        elsif ($f >= EFF_FLAG_PER_CALL_WATCH) {
            $sev = 1 if $sev < 1;
            push @why, sprintf('%.2f uncited sentences flagged per call', $f);
        }
    }

    return ('keep', 'no reliability or grounding problem found') unless $sev;
    return ('watch', join('; ', @why)) if $sev == 1;
    return ('replace', join('; ', @why));
}

# Prefer the Ledger `feature` column (true calling feature). It ships in the
# later-added group alongside the grounding columns and is NOT in the
# AiUsageLog default SELECT, so probe it rather than assuming — grouping on a
# column that isn't in the DB yet would throw and blank the whole card.
sub _agent_column {
    my ($self, $c) = @_;
    my $has_feature = eval {
        $self->_schema($c)->resultset('AiUsageLog')
             ->search({}, { columns => ['me.feature'], rows => 1 })->first;
        1;
    } ? 1 : 0;
    return $has_feature ? ('me.feature', 'feature') : ('me.request_type', 'request_type');
}

# Group agent x provider x model x status, summing the raw measures. duration_ms
# is NULLable, so it is counted separately (count ignores NULLs) to keep avg_ms
# honest instead of dividing by every call.
sub _eff_rows {
    my ($self, $rs, $agent_col) = @_;
    my %row;
    try {
        my $q = $rs->search({}, {
            select => [
                $agent_col, 'me.provider', 'me.model', 'me.status',
                { count => 'me.id',                 -as => 'calls' },
                { sum   => 'me.total_tokens',       -as => 'tokens' },
                { sum   => 'me.estimated_cost_usd', -as => 'cost' },
                { sum   => 'me.duration_ms',        -as => 'ms' },
                { count => 'me.duration_ms',        -as => 'ms_n' },
            ],
            as       => [qw(agent provider model status calls tokens cost ms ms_n)],
            group_by => [ $agent_col, 'me.provider', 'me.model', 'me.status' ],
        });
        while (my $r = $q->next) {
            my $key = join("\t",
                $r->get_column('agent')    // '(none)',
                $r->get_column('provider') // '',
                $r->get_column('model')    // '',
            );
            my $e = $row{$key} ||= {
                agent    => $r->get_column('agent')    // '(none)',
                provider => $r->get_column('provider') // '',
                model    => $r->get_column('model')    // '',
                calls => 0, ok => 0, errors => 0,
                tokens => 0, cost => 0, ms => 0, ms_n => 0,
            };
            my $calls = $r->get_column('calls') || 0;
            $e->{calls}  += $calls;
            $e->{tokens} += $r->get_column('tokens') || 0;
            $e->{cost}   += $r->get_column('cost')   || 0;
            $e->{ms}     += $r->get_column('ms')     || 0;
            $e->{ms_n}   += $r->get_column('ms_n')   || 0;
            (($r->get_column('status') // '') eq 'success')
                ? ($e->{ok} += $calls)
                : ($e->{errors} += $calls);
        }
    };
    return \%row;
}

sub _by_user {
    my ($self, $rs) = @_;
    my @rows;
    try {
        my $g = $rs->search({}, {
            join     => 'user',
            select   => [ 'me.user_id', 'user.username',
                          { count => 'me.id', -as => 'calls' },
                          { sum => 'me.total_tokens', -as => 'tokens' },
                          { sum => 'me.estimated_cost_usd', -as => 'cost' } ],
            as       => [qw(user_id username calls tokens cost)],
            group_by => [ 'me.user_id', 'user.username' ],
        });
        my %ok;
        my $okg = $rs->search({ 'me.status' => 'success' }, {
            select   => [ 'me.user_id', { count => 'me.id', -as => 'n' } ],
            as       => [qw(user_id n)],
            group_by => [ 'me.user_id' ],
        });
        while (my $r = $okg->next) {
            $ok{ $r->get_column('user_id') // 0 } = $r->get_column('n') || 0;
        }
        while (my $r = $g->next) {
            my $uid = $r->get_column('user_id');
            push @rows, {
                user_id  => $uid,
                username => $r->get_column('username') || ($uid ? "user#$uid" : 'guest'),
                calls    => $r->get_column('calls') || 0,
                tokens   => $r->get_column('tokens') || 0,
                cost     => $r->get_column('cost') || 0,
                ok       => $ok{$uid // 0} || 0,
            };
        }
    };
    return [ sort { ($b->{calls}||0) <=> ($a->{calls}||0) } @rows ];
}

sub _by_site {
    my ($self, $c, $rs) = @_;
    my @rows;
    try {
        my $g = $rs->search({}, {
            select   => [ 'me.site_id',
                          { count => 'me.id', -as => 'calls' },
                          { sum => 'me.total_tokens', -as => 'tokens' },
                          { sum => 'me.estimated_cost_usd', -as => 'cost' } ],
            as       => [qw(site_id calls tokens cost)],
            group_by => [ 'me.site_id' ],
        });
        my %ok;
        my $okg = $rs->search({ 'me.status' => 'success' }, {
            select   => [ 'me.site_id', { count => 'me.id', -as => 'n' } ],
            as       => [qw(site_id n)],
            group_by => [ 'me.site_id' ],
        });
        while (my $r = $okg->next) {
            $ok{ $r->get_column('site_id') // 0 } = $r->get_column('n') || 0;
        }
        my %names;
        try {
            my $sites = $self->_schema($c)->resultset('Site')->search({}, { columns => [qw(id name)] });
            while (my $s = $sites->next) {
                $names{ $s->id } = $s->name;
            }
        };
        while (my $r = $g->next) {
            my $sid = $r->get_column('site_id');
            push @rows, {
                site_id  => $sid,
                sitename => $names{$sid // 0} || ($sid ? "site#$sid" : '(none)'),
                calls    => $r->get_column('calls') || 0,
                tokens   => $r->get_column('tokens') || 0,
                cost     => $r->get_column('cost') || 0,
                ok       => $ok{$sid // 0} || 0,
            };
        }
    };
    return [ sort { ($b->{calls}||0) <=> ($a->{calls}||0) } @rows ];
}

sub _combinations {
    my ($self, $rs) = @_;
    my %combo;
    try {
        my $q = $rs->search({ 'me.metadata' => { -like => '%fallback%' } }, {
            columns  => [qw(id provider model status metadata)],
            order_by => { -desc => 'me.id' },
            rows     => 1500,
        });
        while (my $r = $q->next) {
            my $m = eval { decode_json($r->get_column('metadata') // '') } or next;
            next unless ref $m eq 'HASH' && ($m->{fallback} || $m->{fallback_from});
            my $from = $m->{fallback_from} || '?';
            my $to   = ($r->get_column('provider') // '') . '/' . ($r->get_column('model') // '');
            my $k = "$from → $to";
            $combo{$k} ||= { combo => $k, calls => 0, ok => 0, errors => 0, tokens => 0, cost => 0 };
            $combo{$k}{calls}++;
            (($r->get_column('status') // '') eq 'success') ? $combo{$k}{ok}++ : $combo{$k}{errors}++;
        }
    };
    return [ sort { $b->{calls} <=> $a->{calls} } values %combo ];
}

sub _recent {
    my ($self, $rs, $n) = @_;
    my @rows;
    try {
        my $q = $rs->search({}, {
            order_by => { -desc => 'me.id' },
            rows     => $n || 40,
            columns  => [qw(id created_at user_id site_id provider model prompt_tokens
                            completion_tokens total_tokens estimated_cost_usd duration_ms
                            request_type status error_message)],
        });
        while (my $r = $q->next) {
            my $ts = $r->created_at;
            push @rows, {
                id         => $r->id,
                created_at => ($ts && $ts->can('iso8601')) ? $ts->iso8601 : "$ts",
                user_id    => $r->user_id,
                site_id    => $r->site_id,
                provider   => $r->provider,
                model      => $r->model,
                prompt_tokens     => $r->prompt_tokens || 0,
                completion_tokens => $r->completion_tokens || 0,
                total_tokens      => $r->total_tokens || 0,
                cost       => sprintf('%.4f', $r->estimated_cost_usd || 0),
                duration_ms=> $r->duration_ms,
                request_type => $r->request_type,
                status     => $r->status,
                error      => $r->error_message,
            };
        }
    };
    return \@rows;
}

sub _latest_eval {
    my ($self, $c) = @_;
    my $row;
    try {
        my $r = $self->_schema($c)->resultset('AiUsageLog')->search(
            { request_type => 'daily_eval' },
            { order_by => { -desc => 'me.id' }, rows => 1 },
        )->first;
        return unless $r;
        my $meta = eval { decode_json($r->metadata // '') } || {};
        $row = {
            created_at => ($r->created_at && $r->created_at->can('iso8601'))
                ? $r->created_at->iso8601 : ($r->created_at ? $r->created_at . '' : ''),
            model      => $r->model,
            provider   => $r->provider,
            evaluation => $meta->{evaluation} || $meta->{summary} || $r->error_message || '',
            metadata   => $meta,
        };
    };
    return $row;
}

sub _anomalies {
    my ($self, $c, $out, $rs) = @_;
    my @a;
    for my $r (@{ $out->{by_model} }) {
        next unless ($r->{calls} || 0) >= 5;
        # router/all_exhausted rows (model failover, §5e) are not a model.
        next if ($r->{provider} // '') eq 'router';
        my $err_rate = 100 * ($r->{errors} || 0) / $r->{calls};
        if ($err_rate >= 30) {
            push @a, {
                kind => 'error_spike',
                severity => $err_rate >= 60 ? 'high' : 'medium',
                text => sprintf('%s/%s error rate %.0f%% (%d/%d)',
                    $r->{provider}, $r->{model}, $err_rate, $r->{errors}, $r->{calls}),
                provider => $r->{provider}, model => $r->{model},
            };
        }
        if (($r->{ok} || 0) == 0 && ($r->{calls} || 0) >= 8) {
            push @a, {
                kind => 'dead_model', severity => 'high',
                text => sprintf('%s/%s has 0 successes in %d calls',
                    $r->{provider}, $r->{model}, $r->{calls}),
                provider => $r->{provider}, model => $r->{model},
            };
        }
    }
    if (@{ $out->{by_day} } >= 3) {
        my @days = @{ $out->{by_day} };
        my $today = $days[-1];
        my $prior = 0;
        my $n = 0;
        for my $i (0 .. $#days - 1) {
            $prior += $days[$i]{cost} || 0;
            $n++;
        }
        my $avg = $n ? $prior / $n : 0;
        if ($avg > 0 && ($today->{cost} || 0) >= 1 && ($today->{cost} || 0) > 3 * $avg) {
            push @a, {
                kind => 'cost_spike', severity => 'high',
                text => sprintf('Today est. $%.2f is >3x avg $%.2f', $today->{cost} || 0, $avg),
            };
        }
    }
    try {
        my $since15 = DateTime->now->subtract(minutes => 15)->strftime('%Y-%m-%d %H:%M:%S');
        my $g = $rs->search({ 'me.created_at' => { '>=' => $since15 } }, {
            select   => [ 'me.user_id', 'me.provider', 'me.model', { count => 'me.id', -as => 'n' } ],
            as       => [qw(user_id provider model n)],
            group_by => [ 'me.user_id', 'me.provider', 'me.model' ],
        });
        while (my $r = $g->next) {
            my $n = $r->get_column('n') || 0;
            next unless $n >= 20;
            push @a, {
                kind => 'thrash', severity => 'high',
                text => sprintf('user #%s %s/%s made %d calls in 15 min',
                    $r->get_column('user_id') // '?', $r->get_column('provider'),
                    $r->get_column('model'), $n),
                provider => $r->get_column('provider'),
                model    => $r->get_column('model'),
            };
        }
    };
    return \@a;
}

# input + output + cache + reasoning — SuperGrok OAuth often stores $0 cost
# but burns all of these. Do not drop cache_read (the bulk of Hermes loops).
my $HERMES_TOKEN_SQL = q{COALESCE(input_tokens,0)+COALESCE(output_tokens,0)
    +COALESCE(cache_read_tokens,0)+COALESCE(cache_write_tokens,0)
    +COALESCE(reasoning_tokens,0)};

sub hermes_summary {
    my ($self, $c, %a) = @_;
    my $days = ($a{days} && $a{days} =~ /^\d+$/) ? $a{days} : 14;
    my $out = {
        ok => 0, source => 'hermes_state.db', days => $days,
        totals => { calls => 0, api_calls => 0, tokens => 0, cost => 0, open => 0 },
        by_day => [], by_model => [], by_source => [], by_day_source => [], open_sessions => [],
    };
    my $db = $ENV{HERMES_STATE_DB} || '/home/shanta/.hermes/state.db';
    unless (-r $db) {
        $out->{error} = "Hermes state.db not readable at $db";
        return $out;
    }
    try {
        require DBI;
        my $dbh = DBI->connect("dbi:SQLite:dbname=$db", '', '', {
            RaiseError => 1, PrintError => 0, ReadOnly => 1,
        });
        my $since = time() - ($days * 86400);

        my $tot = $dbh->selectrow_hashref(
            qq{SELECT COUNT(*) AS calls,
                     COALESCE(SUM(COALESCE(api_call_count,0)),0) AS api_calls,
                     COALESCE(SUM($HERMES_TOKEN_SQL),0) AS tokens,
                     COALESCE(SUM(COALESCE(actual_cost_usd, estimated_cost_usd, 0)),0) AS cost
              FROM sessions WHERE started_at >= ?},
            undef, $since
        );
        $out->{totals}{calls}     = 0 + ($tot->{calls} || 0);
        $out->{totals}{api_calls} = 0 + ($tot->{api_calls} || 0);
        $out->{totals}{tokens}    = 0 + ($tot->{tokens} || 0);
        $out->{totals}{cost}      = 0 + ($tot->{cost} || 0);

        # Per-model from session_model_usage (splits a session that switched models).
        my $usage_n = eval {
            $dbh->selectrow_array('SELECT COUNT(*) FROM session_model_usage WHERE last_seen >= ?', undef, $since)
        };
        if ($usage_n) {
            my $u = $dbh->selectrow_hashref(
                qq{SELECT COALESCE(SUM(COALESCE(api_call_count,0)),0) AS api_calls,
                          COALESCE(SUM($HERMES_TOKEN_SQL),0) AS tokens,
                          COALESCE(SUM(COALESCE(actual_cost_usd, estimated_cost_usd, 0)),0) AS cost
                   FROM session_model_usage WHERE last_seen >= ?},
                undef, $since
            );
            $out->{totals}{api_calls} = 0 + ($u->{api_calls} || 0) if $u;
            $out->{totals}{tokens}    = 0 + ($u->{tokens} || 0) if $u;
            $out->{totals}{cost}      = 0 + ($u->{cost} || 0) if $u && ($u->{cost} || 0) > 0;
        }

        my $sth = $dbh->prepare(
            qq{SELECT date(started_at, 'unixepoch') AS day,
                     COUNT(*) AS calls,
                     COALESCE(SUM(COALESCE(api_call_count,0)),0) AS api_calls,
                     COALESCE(SUM($HERMES_TOKEN_SQL),0) AS tokens,
                     COALESCE(SUM(COALESCE(actual_cost_usd, estimated_cost_usd, 0)),0) AS cost
              FROM sessions WHERE started_at >= ?
              GROUP BY 1 ORDER BY 1}
        );
        $sth->execute($since);
        while (my $r = $sth->fetchrow_hashref) { push @{ $out->{by_day} }, $r }

        $sth = $dbh->prepare(
            qq{SELECT COALESCE(billing_provider,'(none)') AS provider,
                     COALESCE(model,'unknown') AS model,
                     COUNT(*) AS calls,
                     COALESCE(SUM(COALESCE(api_call_count,0)),0) AS api_calls,
                     COALESCE(SUM($HERMES_TOKEN_SQL),0) AS tokens,
                     COALESCE(SUM(COALESCE(actual_cost_usd, estimated_cost_usd, 0)),0) AS cost
              FROM session_model_usage WHERE last_seen >= ?
              GROUP BY 1,2 ORDER BY tokens DESC}
        );
        eval { $sth->execute($since) };
        if ($@) {
            $sth = $dbh->prepare(
                qq{SELECT COALESCE(billing_provider,'(none)') AS provider,
                         COALESCE(model,'unknown') AS model,
                         COUNT(*) AS calls,
                         COALESCE(SUM(COALESCE(api_call_count,0)),0) AS api_calls,
                         COALESCE(SUM($HERMES_TOKEN_SQL),0) AS tokens,
                         COALESCE(SUM(COALESCE(actual_cost_usd, estimated_cost_usd, 0)),0) AS cost
                  FROM sessions WHERE started_at >= ?
                  GROUP BY 1,2 ORDER BY tokens DESC}
            );
            $sth->execute($since);
        }
        while (my $r = $sth->fetchrow_hashref) { push @{ $out->{by_model} }, $r }

        $sth = $dbh->prepare(
            qq{SELECT COALESCE(source,'unknown') AS request_type,
                     COUNT(*) AS calls,
                     COALESCE(SUM(COALESCE(api_call_count,0)),0) AS api_calls,
                     COALESCE(SUM($HERMES_TOKEN_SQL),0) AS tokens,
                     COALESCE(SUM(COALESCE(actual_cost_usd, estimated_cost_usd, 0)),0) AS cost
              FROM sessions WHERE started_at >= ?
              GROUP BY 1 ORDER BY tokens DESC}
        );
        $sth->execute($since);
        while (my $r = $sth->fetchrow_hashref) { push @{ $out->{by_source} }, $r }

        # 14d grid for the stacked chart: one row per (day, hermes source).
        # Cost uses estimated_cost_usd only — actual_cost_usd is 0.0 on OAuth
        # and would zero the COALESCE.
        $sth = $dbh->prepare(
            qq{SELECT date(started_at, 'unixepoch') AS day,
                     COALESCE(source,'unknown') AS source,
                     COUNT(*) AS calls,
                     COALESCE(SUM(COALESCE(api_call_count,0)),0) AS api_calls,
                     COALESCE(SUM($HERMES_TOKEN_SQL),0) AS tokens,
                     COALESCE(SUM(COALESCE(estimated_cost_usd,0)),0) AS cost
              FROM sessions WHERE started_at >= ?
              GROUP BY 1,2 ORDER BY 1,2}
        );
        $sth->execute($since);
        while (my $r = $sth->fetchrow_hashref) { push @{ $out->{by_day_source} }, $r }

        $sth = $dbh->prepare(
            qq{SELECT id, source, model, billing_provider, started_at, last_activity_at,
                     COALESCE(api_call_count,0) AS api_calls,
                     ($HERMES_TOKEN_SQL) AS tokens
              FROM sessions WHERE ended_at IS NULL AND COALESCE(archived,0) = 0
              ORDER BY COALESCE(last_activity_at, started_at) DESC LIMIT 20}
        );
        $sth->execute();
        my $now = time();
        while (my $r = $sth->fetchrow_hashref) {
            my $last = 0 + ($r->{last_activity_at} || $r->{started_at} || 0);
            $r->{active} = ($last && ($now - $last) < 1800) ? 1 : 0;
            push @{ $out->{open_sessions} }, $r;
        }
        $out->{totals}{open} = 0 + @{ $out->{open_sessions} };

        $dbh->disconnect;
        $out->{ok} = 1;
        $out->{totals}{cost} = sprintf('%.4f', $out->{totals}{cost} || 0);
        for my $r (@{ $out->{by_day} }, @{ $out->{by_model} }, @{ $out->{by_source} },
                   @{ $out->{by_day_source} }) {
            $r->{cost} = sprintf('%.4f', $r->{cost} || 0);
        }
    } catch {
        $out->{error} = "$_";
        $self->_log($c, 'warn', 'hermes_summary', "Hermes overlay failed: $_");
    };
    return $out;
}

# Map a Ledger status + error_message to a stable reason bucket for the usage page.
sub classify_failure_reason {
    my ($self, $status, $err) = @_;
    $status = $status // '';
    $err    = $err // '';
    return 'success' if $status eq 'success';
    return 'all_exhausted' if $status eq 'all_exhausted' || $err =~ /all_exhausted|No AI model is available/i;
    return 'circuit_open'  if $err =~ /circuit_open|circuit open/i;
    return 'budget_cap'    if $err =~ /budget_cap|credits_exhausted|soft.?cap/i;
    return 'supergrok_locked' if $err =~ /supergrok_locked/i;
    return 'http_429' if $err =~ /\b429\b|rate.?limit/i;
    return 'http_402' if $err =~ /\b402\b|Payment Required|Insufficient credits/i;
    return 'http_404' if $err =~ /\b404\b|not a valid model|No endpoints/i;
    return 'http_401' if $err =~ /\b401\b|Unauthorized|invalid.?api.?key/i;
    return 'http_5xx' if $err =~ /\b50[0-9]\b/;
    return 'timeout'  if $err =~ /timeout|timed out|DeadlineExceeded/i;
    return 'empty'    if $err =~ /empty_output|empty content|zero_tokens_empty|postcheck_empty/i;
    return 'provider_error' if $err =~ /provider error|provider_error/i;
    return 'refused'  if $err =~ /refus|harm|safety/i;
    return 'timeout' if $status eq 'timeout';
    return 'other';
}

=head2 failure_buckets($c, days => 14)

Counts non-success Ledger rows (excluding guard trip/restore via _base_rs)
into reason buckets for /ai/usage and usage_live.

=cut

sub failure_buckets {
    my ($self, $c, %a) = @_;
    my ($days, $since) = $self->_since($a{days});
    my $out = { days => $days, since => $since, buckets => [], total_failures => 0, errors => [] };
    try {
        my $rs = $self->_base_rs($c, $since)->search({ 'me.status' => { '!=' => 'success' } }, {
            columns => [qw(id status error_message provider model request_type)],
            order_by => { -desc => 'me.id' }, rows => METADATA_SCAN_ROWS * 2,
        });
        my %b;
        while (my $r = $rs->next) {
            my $bucket = $self->classify_failure_reason($r->get_column('status'), $r->get_column('error_message'));
            my $row = $b{$bucket} ||= { reason => $bucket, count => 0, providers => {}, models => {} };
            $row->{count}++;
            $out->{total_failures}++;
            my $pv = $r->get_column('provider') // '-';
            my $md = $r->get_column('model') // '-';
            $row->{providers}{$pv}++;
            $row->{models}{$md}++;
        }
        $out->{buckets} = [
            map {
                my $x = $b{$_};
                +{ reason => $x->{reason}, count => $x->{count},
                   providers => [ sort { $x->{providers}{$b} <=> $x->{providers}{$a} } keys %{ $x->{providers} } ],
                   top_model => (sort { $x->{models}{$b} <=> $x->{models}{$a} } keys %{ $x->{models} })[0] }
            } sort { $b{$b}{count} <=> $b{$a}{count} || $a cmp $b } keys %b
        ];
    } catch {
        push @{ $out->{errors} }, "failure_buckets: $_";
    };
    return $out;
}


sub _merge_org_totals {
    my ($self, $out) = @_;
    my $h = $out->{hermes}{totals} || {};
    my $h_calls = $h->{api_calls} || $h->{calls} || 0;
    $out->{org_totals} = {
        calls  => ($out->{totals}{calls}  || 0) + $h_calls,
        tokens => ($out->{totals}{tokens} || 0) + ($h->{tokens} || 0),
        cost   => ($out->{totals}{cost}   || 0) + ($h->{cost}   || 0),
        app_calls    => $out->{totals}{calls} || 0,
        hermes_calls => $h_calls,
        hermes_sessions => $h->{calls} || 0,
    };
}

# Four surfaces the operator cares about. Grok Bot is process-only (no API bump).
sub agents_active {
    my ($self, $c, $hermes) = @_;
    $hermes ||= {};
    my @agents;

    my $h_open = $hermes->{open_sessions} || [];
    my $h_live = 0;
    $h_live++ for grep { $_->{active} } @$h_open;
    my $h_model = '';
    for my $s (@$h_open) {
        if ($s->{active} && $s->{model}) { $h_model = $s->{model}; last }
    }
    $h_model ||= (($hermes->{by_model} || [])->[0] || {})->{model} || '';
    push @agents, {
        id     => 'hermes',
        label  => 'Hermes',
        status => $hermes->{ok} ? ($h_live ? 'active' : 'idle') : 'down',
        detail => $hermes->{ok}
            ? sprintf('%d open session%s (%d live) · %s · %s tokens / %s API calls (window)',
                0 + @$h_open, (@$h_open == 1 ? '' : 's'), $h_live,
                ($h_model || 'no model'),
                $hermes->{totals}{tokens} || 0,
                $hermes->{totals}{api_calls} || 0)
            : ($hermes->{error} || 'state.db unread'),
        href   => '/ai/usage#hermes-ledger',
    };

    my $chat = $self->_app_agent_slice($c, 'chat', 30);
    push @agents, {
        id     => 'chat',
        label  => 'AI Chat',
        status => $chat->{recent} ? 'active' : ($chat->{window_calls} ? 'idle' : 'quiet'),
        detail => sprintf('%d calls in 30 min · %s tokens · last %s',
            $chat->{window_calls} || 0, $chat->{window_tokens} || 0,
            $chat->{last_at} || 'never'),
        href   => '/ai',
    };

    my $bot = $self->_grok_bot_alive();
    push @agents, {
        id     => 'grok_bot',
        label  => 'Grok Bot',
        status => $bot->{running} ? 'active' : 'down',
        detail => $bot->{running}
            ? sprintf('pid %s · process up (no API probe)', $bot->{pid} || '?')
            : 'not running on this host',
        href   => '/ai/eval',
    };

    my $ed = $self->_app_agent_slice($c, 'generate', 30);
    push @agents, {
        id     => 'editor',
        label  => 'AI Editor',
        status => $ed->{recent} ? 'active' : ($ed->{window_calls} ? 'idle' : 'quiet'),
        detail => sprintf('%d generate calls in 30 min · %s tokens · last %s',
            $ed->{window_calls} || 0, $ed->{window_tokens} || 0,
            $ed->{last_at} || 'never'),
        href   => '/ai2/editing_widget_popup',
    };

    return \@agents;
}

sub _app_agent_slice {
    my ($self, $c, $request_type, $minutes) = @_;
    my $out = { window_calls => 0, window_tokens => 0, last_at => '', recent => 0 };
    try {
        $minutes ||= 30;
        my $since = DateTime->now->subtract(minutes => $minutes)->strftime('%Y-%m-%d %H:%M:%S');
        my $rs = $self->_schema($c)->resultset('AiUsageLog')->search({
            'me.request_type' => $request_type,
            'me.created_at'   => { '>=' => $since },
        });
        $out->{window_calls}  = 0 + $rs->count;
        my $sum = $rs->search({}, {
            select => [ { sum => 'me.total_tokens' } ],
            as     => [ 'tokens' ],
        })->get_column('tokens')->first;
        $out->{window_tokens} = 0 + ($sum || 0);
        my $last = $self->_schema($c)->resultset('AiUsageLog')->search(
            { 'me.request_type' => $request_type },
            { order_by => { -desc => 'me.id' }, rows => 1 },
        )->single;
        $out->{last_at} = $last ? ('' . ($last->get_column('created_at') // '')) : '';
        $out->{recent}  = $out->{window_calls} ? 1 : 0;
    } catch {
        $out->{error} = "$_";
    };
    return $out;
}

sub _grok_bot_alive {
    my ($self) = @_;
    my $out = { running => 0, pid => undef };
    return $out unless -d '/proc';
    opendir my $dh, '/proc' or return $out;
    while (my $pid = readdir $dh) {
        next unless $pid =~ /^\d+$/;
        my $comm = '';
        if (open my $fh, '<', "/proc/$pid/comm") {
            $comm = <$fh> // '';
            close $fh;
            chomp $comm;
        }
        next unless $comm eq 'grok-bot';
        my $cmd = '';
        if (open my $fh, '<', "/proc/$pid/cmdline") {
            local $/;
            $cmd = <$fh> // '';
            close $fh;
            $cmd =~ s/\0/ /g;
        }
        next if $cmd =~ /--type=/;
        $out->{running} = 1;
        $out->{pid} = 0 + $pid;
        last;
    }
    closedir $dh;
    return $out;
}

# Live OpenRouter remaining — GET /api/v1/auth/key (already used by Model::AI::Usage).
sub openrouter_live {
    my ($self, $c) = @_;
    my $out = { ok => 0, provider => 'openrouter' };
    try {
        require Comserv::Model::AI::Usage;
        my $st = Comserv::Model::AI::Usage->new->fetch_openrouter_status($c);
        $out = $st if ref $st eq 'HASH';
    } catch {
        $out->{error} = "$_";
        $self->_log($c, 'warn', 'openrouter_live', "$_");
    };
    return $out;
}

# Hermes SuperGrok (xai-oauth) this UTC week. Not grok.com Settings → Usage.
sub supergrok_week_from_hermes {
    my ($self, $c) = @_;
    my $out = {
        ok => 0, source => 'hermes_state.db', live_quota => 0,
        note => 'xAI does not publish SuperGrok weekly %. This is Hermes xai-oauth only.',
        tokens => 0, api_calls => 0, sessions => 0,
    };
    my $db = $ENV{HERMES_STATE_DB} || '/home/shanta/.hermes/state.db';
    return $out unless -r $db;
    try {
        require DBI;
        require DateTime;
        my $now = DateTime->now->set_time_zone('UTC');
        my $start = $now->clone->truncate(to => 'week'); # Monday 00:00 UTC
        my $since = $start->epoch;
        my $dbh = DBI->connect("dbi:SQLite:dbname=$db", '', '', {
            RaiseError => 1, PrintError => 0, ReadOnly => 1,
        });
        my $tok = $HERMES_TOKEN_SQL;
        my $row = $dbh->selectrow_hashref(
            qq{SELECT COUNT(*) AS sessions,
                      COALESCE(SUM(COALESCE(api_call_count,0)),0) AS api_calls,
                      COALESCE(SUM($tok),0) AS tokens
               FROM sessions
               WHERE started_at >= ?
                 AND (COALESCE(billing_provider,'') IN ('xai-oauth','supergrok','xai')
                      OR COALESCE(model,'') LIKE '%grok%')},
            undef, $since
        );
        $out->{ok}        = 1;
        $out->{week_start}= $start->ymd;
        $out->{sessions}  = 0 + ($row->{sessions} || 0);
        $out->{api_calls} = 0 + ($row->{api_calls} || 0);
        $out->{tokens}    = 0 + ($row->{tokens} || 0);
        $dbh->disconnect;
    } catch {
        $out->{error} = "$_";
        $self->_log($c, 'warn', 'supergrok_week_from_hermes', "$_");
    };
    return $out;
}

sub ingest {
    my ($self, $c, %a) = @_;
    my $source = $a{source} || $a{request_type} || 'network';
    $source = 'network' unless $source =~ /^(hermes|grok_bot|daily_eval|network|chat)$/;
    my $usage = eval { $c->model('AI')->usage };
    return { ok => 0, error => 'usage model missing' } unless $usage;
    my $meta = $a{metadata};
    $meta = {} unless ref $meta eq 'HASH';
    $meta->{source} = $source;
    # Keep the caller's finer request type (e.g. guard_switch) in metadata.
    $meta->{event} = $a{request_type}
        if defined $a{request_type} && $a{request_type} =~ /^[a-z_]{1,40}$/ && $a{request_type} ne $source;
    $meta->{evaluation} = $a{evaluation} if defined $a{evaluation};
    $usage->log($c,
        provider          => $a{provider} || ($source eq 'grok_bot' ? 'grok' : 'hermes'),
        model             => $a{model} || ($source eq 'daily_eval' ? '_daily_eval' : 'unknown'),
        prompt_tokens     => $a{prompt_tokens} || 0,
        completion_tokens => $a{completion_tokens} || 0,
        total_tokens      => $a{total_tokens} || (($a{prompt_tokens}||0)+($a{completion_tokens}||0)),
        estimated_cost_usd=> $a{estimated_cost_usd},
        request_type      => $source,
        status            => $a{status} || 'success',
        error_message     => $a{error_message} || $a{error},
        user_id           => $a{user_id},
        site_id           => $a{site_id},
        metadata          => $meta,
    );
    return { ok => 1, source => $source };
}

sub _count_by {
    my ($self, $rs, $cond, $keys, $key_as) = @_;
    my %out;
    my $g = $rs->search($cond, {
        select   => [ @$keys, { count => 'me.id', -as => 'n' } ],
        as       => [ @$key_as, 'n' ],
        group_by => $keys,
    });
    while (my $r = $g->next) {
        my $k = join("\t", map { $r->get_column($_) // '' } @$key_as);
        $out{$k} = $r->get_column('n') || 0;
    }
    return \%out;
}

=head2 ledger_summary($c, days => 14)

Returns a hashref for root/ai/usage_ledger.tt: by_day, by_model, totals,
grounding, golden_store, heuristics, errors.

=cut

sub ledger_summary {
    my ($self, $c, %a) = @_;
    my $days = ($a{days} && $a{days} =~ /^\d+$/) ? $a{days} : 14;
    $days = 90 if $days > 90;
    my $since = DateTime->now->subtract(days => $days)->ymd . ' 00:00:00';
    my $out = { days => $days, since => $since, by_day => [], by_model => [],
                totals => { calls => 0, ok => 0, errors => 0, http_404 => 0, zero_token_ok => 0, tokens => 0, cost => 0 },
                errors => [] };

    my $day_fn = { date => 'me.created_at' };
    # Rows the Ledger flagged tokens_unreported (non-empty text from a
    # provider that reports no tokens, e.g. Ollama) are verified answers, not
    # suspect 0-token successes. Empty "successes" are now written as errors.
    my $zero_cond = { 'me.status' => 'success',
                      'me.provider' => { '!=' => 'ai2-grounding' },
                      -or => [ { 'me.total_tokens' => 0 }, { 'me.total_tokens' => undef } ],
                      -and => [ -or => [ { 'me.metadata' => undef },
                                         { 'me.metadata' => { -not_like => '%"tokens_unreported"%' } } ] ] };
    my $c404_cond = { 'me.status' => { '!=' => 'success' }, 'me.error_message' => { -like => '%404%' } };

    try {
        my $rs = $self->_base_rs($c, $since);

        # Calls by day (split by status), plus 0-token successes and 404s.
        my $by_day_status = $self->_grouped($rs, [ $day_fn, 'me.status' ], [qw(day status)]);
        my $zero_day = $self->_count_by($rs, $zero_cond, [ $day_fn ], ['day']);
        my $e404_day = $self->_count_by($rs, $c404_cond, [ $day_fn ], ['day']);
        my %d;
        for my $r (@$by_day_status) {
            my $row = $d{ $r->{day} } ||= { day => $r->{day}, calls => 0, ok => 0, errors => 0, tokens => 0, cost => 0 };
            $row->{calls}  += $r->{calls};
            $row->{tokens} += $r->{tokens} || 0;
            $row->{cost}   += $r->{cost} || 0;
            (($r->{status} // '') eq 'success') ? ($row->{ok} += $r->{calls}) : ($row->{errors} += $r->{calls});
        }
        for my $day (keys %d) {
            $d{$day}{zero_token_ok} = $zero_day->{$day} || 0;
            $d{$day}{http_404}      = $e404_day->{$day} || 0;
        }
        $out->{by_day} = [ map { $d{$_} } sort { $b cmp $a } keys %d ];

        # Provider / model breakdown.
        my $by_pm = $self->_grouped($rs, [ 'me.provider', 'me.model', 'me.status' ], [qw(provider model status)]);
        my $zero_pm = $self->_count_by($rs, $zero_cond, [ 'me.provider', 'me.model' ], [qw(provider model)]);
        my $e404_pm = $self->_count_by($rs, $c404_cond, [ 'me.provider', 'me.model' ], [qw(provider model)]);
        my %m;
        for my $r (@$by_pm) {
            my $k = join("\t", $r->{provider} // '', $r->{model} // '');
            my $row = $m{$k} ||= { provider => $r->{provider}, model => $r->{model}, calls => 0, ok => 0, errors => 0, tokens => 0, cost => 0 };
            $row->{calls}  += $r->{calls};
            $row->{tokens} += $r->{tokens} || 0;
            $row->{cost}   += $r->{cost} || 0;
            (($r->{status} // '') eq 'success') ? ($row->{ok} += $r->{calls}) : ($row->{errors} += $r->{calls});
        }
        for my $k (keys %m) {
            $m{$k}{zero_token_ok} = $zero_pm->{$k} || 0;
            $m{$k}{http_404}      = $e404_pm->{$k} || 0;
        }
        $out->{by_model} = [ sort { $b->{calls} <=> $a->{calls} } values %m ];

        for my $r (@{ $out->{by_day} }) {
            $out->{totals}{$_} += $r->{$_} || 0 for qw(calls ok errors http_404 zero_token_ok tokens cost);
        }
        for my $r (@{ $out->{by_day} }, @{ $out->{by_model} }) { $r->{cost} = sprintf('%.4f', $r->{cost} || 0) }
        $out->{totals}{cost} = sprintf('%.4f', $out->{totals}{cost});
    } catch {
        push @{ $out->{errors} }, "Ledger aggregation failed: $_";
        $self->_log($c, 'error', 'ledger_summary', "Ledger aggregation failed: $_");
    };

    $out->{grounding}    = $self->grounding_summary($c, $since);
    $out->{golden_store} = $self->golden_store_counts($c);
    # Agent x model cost-effectiveness. Answers "is this agent+model pairing
    # worth keeping" (cost per success, error rate, avg latency), which by_model
    # alone cannot — it has no agent dimension.
    $out->{agent_effectiveness} = $self->agent_effectiveness($c, days => $days);
    return $out;
}

=head2 grounding_summary($c, $since)

Grounded vs Ungrounded Generation. Source 'columns' once schema-compare has
added the Ledger columns; else 'metadata' (metadata.grounding); 'none' when
nothing has been recorded yet.

=cut

sub grounding_summary {
    my ($self, $c, $since) = @_;
    my $g = { source => 'none', recorded => 0, grounded => 0, ungrounded => 0,
              golden_hits => 0, candidate_hits => 0, flagged => 0, fallbacks => 0,
              columns_present => 0 };
    try {
        my $schema = $self->_schema($c);
        require Comserv::Util::AI::Ledger;
        my $rs = $self->_base_rs($c, $since);
        if (Comserv::Util::AI::Ledger->columns_present($schema)) {
            $g->{columns_present} = 1;
            my $q = $rs->search({ 'me.grounded' => { '!=' => undef } }, {
                select   => [ 'me.grounded',
                              { count => 'me.id', -as => 'n' },
                              { sum => 'me.golden_hit_count',    -as => 'gh' },
                              { sum => 'me.candidate_hit_count', -as => 'ch' },
                              { sum => 'me.flagged_count',       -as => 'fl' } ],
                as       => [qw(grounded n gh ch fl)],
                group_by => [ 'me.grounded' ],
            });
            while (my $r = $q->next) {
                my $n = $r->get_column('n') || 0;
                $g->{recorded} += $n;
                $r->get_column('grounded') ? ($g->{grounded} += $n) : ($g->{ungrounded} += $n);
                $g->{golden_hits}    += $r->get_column('gh') || 0;
                $g->{candidate_hits} += $r->get_column('ch') || 0;
                $g->{flagged}        += $r->get_column('fl') || 0;
            }
            $g->{fallbacks} = $rs->search({ 'me.provider' => 'ai2-grounding' })->count;
            $g->{source} = 'columns' if $g->{recorded};
            return;
        }
        # Pre-migration: tally metadata.grounding (bounded scan, newest first).
        my $q = $rs->search({ 'me.metadata' => { -like => '%"grounding"%' } }, {
            columns  => [qw(id provider metadata)],
            order_by => { -desc => 'me.id' },
            rows     => METADATA_SCAN_ROWS,
        });
        while (my $r = $q->next) {
            my $m = eval { decode_json($r->get_column('metadata') // '') } or next;
            my $gr = ref $m eq 'HASH' ? $m->{grounding} : undef;
            next unless ref $gr eq 'HASH';
            $g->{recorded}++;
            $gr->{grounded} ? $g->{grounded}++ : $g->{ungrounded}++;
            $g->{golden_hits}    += $gr->{golden_hit_count}    || 0;
            $g->{candidate_hits} += $gr->{candidate_hit_count} || 0;
            $g->{flagged}        += $gr->{flagged_count}       || 0;
            $g->{fallbacks}++ if ($r->get_column('provider') // '') eq 'ai2-grounding';
        }
        $g->{source} = 'metadata' if $g->{recorded};
    } catch {
        $g->{error} = "$_";
        $self->_log($c, 'warn', 'grounding_summary', "Grounding summary failed: $_");
    };
    return $g;
}

=head2 golden_store_counts($c)

Delegates to Comserv::Model::AI2::GoldenData::counts_by_status (table_missing
when schema-compare has not created ai_golden_data yet).

=cut

sub golden_store_counts {
    my ($self, $c) = @_;
    my $store = $self->golden_store_override;
    unless ($store) {
        require Comserv::Model::AI2::GoldenData;
        $store = Comserv::Model::AI2::GoldenData->new(
            ($self->schema_override ? (schema_override => $self->schema_override) : ()));
    }
    my $r = eval { $store->counts_by_status($c) } || { counts => {}, total => 0, error => "$@" };
    require Comserv::Util::AI::Glossary;
    $r->{status_today} = Comserv::Util::AI::Glossary->golden_status_today;
    return $r;
}


__PACKAGE__->meta->make_immutable;

# ===================================================================
# Model failover support (AISYSTEM plan §5e)
# ===================================================================

=head2 model_health_signals($c, hours => 24, verdict_days => 7)

What the Router failover needs from the monitor, computed with the SAME code
the usage page uses: C<_anomalies> (error_spike / dead_model) over the last
C<hours>, and the effectiveness verdict (C<_eff_calc> / C<_eff_verdict>)
per provider|model over C<verdict_days>, all agents summed. Returns
C<< { anomalies => [...], verdicts => { 'provider|model' => {verdict, why, calls, ok_rate} } } >>.
Provider C<external> is folded into C<openrouter>; router/all_exhausted rows
are ignored.

=cut

sub _fo_slug {
    my ($provider, $model) = @_;
    $provider = lc($provider // '');
    $provider = 'openrouter' if $provider eq 'external';
    return "$provider|" . ($model // '');
}

sub model_health_signals {
    my ($self, $c, %a) = @_;
    my $hours = ($a{hours} && $a{hours} =~ /^\d+$/) ? $a{hours} : 24;
    my $vdays = ($a{verdict_days} && $a{verdict_days} =~ /^\d+$/) ? $a{verdict_days} : 7;
    my $out = { anomalies => [], verdicts => {}, window_hours => $hours, verdict_days => $vdays };
    try {
        my $since = DateTime->now->subtract(hours => $hours)->strftime('%Y-%m-%d %H:%M:%S');
        my $rs = $self->_base_rs($c, $since, { 'me.provider' => { '!=' => 'router' } });
        my $by_pm = $self->_grouped($rs, [ 'me.provider', 'me.model', 'me.status' ], [qw(provider model status)]);
        my %m;
        for my $r (@$by_pm) {
            my $k = _fo_slug($r->{provider}, $r->{model});
            my ($p, $mod) = split /\|/, $k, 2;
            my $row = $m{$k} ||= { provider => $p, model => $mod, calls => 0, ok => 0, errors => 0 };
            $row->{calls} += $r->{calls} || 0;
            (($r->{status} // '') eq 'success') ? ($row->{ok} += $r->{calls}) : ($row->{errors} += $r->{calls});
        }
        $out->{anomalies} = [ grep { ($_->{kind} // '') =~ /^(error_spike|dead_model)$/ }
            @{ $self->_anomalies($c, { by_model => [ values %m ], by_day => [] }, $rs) } ];
    } catch {
        $self->_log($c, 'warn', 'model_health_signals', "anomaly window failed: $_");
    };
    try {
        my (undef, $vsince) = $self->_since($vdays);
        my $rs = $self->_base_rs($c, $vsince, { 'me.provider' => { '!=' => 'router' } });
        my ($agent_col) = $self->_agent_column($c);
        my $rows = $self->_eff_rows($rs, $agent_col);
        my $qual = $self->_eff_quality($c, $rs, $agent_col);
        my %agg;
        for my $k (keys %$rows) {
            my $raw = $rows->{$k};
            if (my $q = $qual->{by_pair}{$k}) { $raw->{$_} = $q->{$_} || 0 for qw(recorded grounded flagged golden_hits) }
            my $slug = _fo_slug($raw->{provider}, $raw->{model});
            my $a = $agg{$slug} ||= { calls => 0, ok => 0, errors => 0, tokens => 0, cost => 0,
                                      ms => 0, ms_n => 0, flagged => 0, recorded => 0, grounded => 0, golden_hits => 0 };
            $self->_eff_add($a, $raw);
        }
        for my $slug (keys %agg) {
            my $calc = $self->_eff_calc($agg{$slug});
            $out->{verdicts}{$slug} = { verdict => $calc->{verdict}, why => $calc->{why},
                                        calls => $calc->{calls}, ok_rate => $calc->{ok_rate} };
        }
    } catch {
        $self->_log($c, 'warn', 'model_health_signals', "verdicts failed: $_");
    };
    return $out;
}

=head2 fallover_summary($c, days => 14)

The "Fallover" section on /ai/usage (#fallover, admin) and the C<fallover>
key of /ai/usage_live. Shape (documented in AISYSTEMPlan §5e):

  { window_days, source => 'metadata.fallover',
    turns, answered_first, answered_after_failover, fallover_rate_pct,
    failed_attempts, failed_by_reason => { http_429 => n, ... },
    by_step  => [ { step, count } ], by_final_model => [ { model, count } ],
    all_exhausted => n, recent_all_exhausted => [ { id, created_at, purpose, attempts, skipped } ],
    recent_failovers => [ { id, created_at, final_model, attempt_no, fallback_from, fallback_reason } ],
    circuits => { open => [...], half_open => [...], closed_tracked => n },
    chains => { source, path, reason, chat => [...], docs => [...], coding => [...], title => [...], removed => [...] },
    caps => { openrouter_soft_cap_day_usd, ..._week_usd, ..._month_usd },
    spend => { ok, day, week, month },
    supergrok_guard => { locked, reason, checked, stale },
    hermes => { model_hops => [ { session_id, models => [...] } ], guard => {...} },
    errors => [] }

=cut

sub fallover_summary {
    my ($self, $c, %a) = @_;
    my ($days, $since) = $self->_since($a{days});
    my $out = {
        window_days => $days, since => $since, source => 'metadata.fallover',
        turns => 0, answered_first => 0, answered_after_failover => 0, fallover_rate_pct => '0.0',
        failed_attempts => 0, failed_by_reason => {}, by_step => [], by_final_model => [],
        all_exhausted => 0, recent_all_exhausted => [], recent_failovers => [],
        circuits => { open => [], half_open => [], closed_tracked => 0 },
        errors => [],
    };
    try {
        my $rs = $self->_base_rs($c, $since, { 'me.metadata' => { -like => '%"fallover"%' } });
        my $q = $rs->search({}, {
            columns  => [qw(id created_at provider model status metadata duration_ms error_message)],
            order_by => { -desc => 'me.id' },
            rows     => METADATA_SCAN_ROWS,
        });
        my (%step, %final);
        my $w = $out->{waste} = { failed => 0, free_failed => 0, ms => 0, free_ms => 0, retries => 0,
                                  http_402 => 0, http_429 => 0, free_429 => 0, by_model => {} };
        while (my $r = $q->next) {
            my $m = eval { decode_json($r->get_column('metadata') // '') } or next;
            my $fo = ref $m eq 'HASH' ? $m->{fallover} : undef;
            next unless ref $fo eq 'HASH';
            my $ts = $r->get_column('created_at') // '';
            my $st = $r->get_column('status') // '';
            if (($r->get_column('provider') // '') eq 'router' || ($fo->{reason} // '') eq 'all_exhausted') {
                $out->{all_exhausted}++;
                push @{ $out->{recent_all_exhausted} }, {
                    id => $r->get_column('id'), created_at => "$ts", purpose => $fo->{purpose},
                    requested => $fo->{requested}, attempts => $fo->{attempts} || [], skipped => $fo->{skipped} || [],
                } if @{ $out->{recent_all_exhausted} } < 20;
                next;
            }
            if (($fo->{outcome} // '') eq 'failed' || $st ne 'success') {
                $out->{failed_attempts}++;
                $out->{failed_by_reason}{ $fo->{fallback_reason} // 'unknown' }++;
                # Waste accounting (§5e item 7): time and retries burned on
                # failed attempts, split out for :free models and for the
                # 402 / 429 answers OpenRouter gives when there is no credit.
                my $mdl  = $r->get_column('model') // '';
                my $free = $mdl =~ /:free$/ ? 1 : 0;
                my $txt  = join ' ', ($fo->{fallback_reason} // ''), ($r->get_column('error_message') // '');
                my $ms   = $r->get_column('duration_ms') || 0;
                $w->{failed}++;
                $w->{ms} += $ms;
                $w->{retries} += $fo->{retries} || 0;
                $w->{http_402}++ if $txt =~ /\b402\b|insufficient|credit/i;
                if ($txt =~ /\b429\b|rate.?limit/i) { $w->{http_429}++; $w->{free_429}++ if $free }
                if ($free) { $w->{free_failed}++; $w->{free_ms} += $ms }
                my $bm = $w->{by_model}{ _fo_slug($r->get_column('provider'), $mdl) } ||= { failed => 0, ms => 0, retries => 0 };
                $bm->{failed}++; $bm->{ms} += $ms; $bm->{retries} += $fo->{retries} || 0;
                next;
            }
            $out->{turns}++;
            my $n = $fo->{attempt_no} || 1;
            ($n > 1 || ($fo->{chain_step} || 0) > 0) ? $out->{answered_after_failover}++ : $out->{answered_first}++;
            $step{ $fo->{chain_step} // 0 }++;
            $final{ $fo->{final_model} // _fo_slug($r->get_column('provider'), $r->get_column('model')) }++;
            push @{ $out->{recent_failovers} }, {
                id => $r->get_column('id'), created_at => "$ts", final_model => $fo->{final_model},
                attempt_no => $n, chain_step => $fo->{chain_step}, purpose => $fo->{purpose},
                fallback_from => $fo->{fallback_from}, fallback_reason => $fo->{fallback_reason},
            } if ($n > 1 || ($fo->{chain_step} || 0) > 0) && @{ $out->{recent_failovers} } < 20;
        }
        $out->{fallover_rate_pct} = $out->{turns}
            ? sprintf('%.1f', 100 * $out->{answered_after_failover} / $out->{turns}) : '0.0';
        $out->{by_step} = [ map { { step => $_ + 0, count => $step{$_} } } sort { $a <=> $b } keys %step ];
        $out->{by_final_model} = [ map { { model => $_, count => $final{$_} } }
                                   sort { $final{$b} <=> $final{$a} || $a cmp $b } keys %final ];
    } catch {
        push @{ $out->{errors} }, "fallover ledger scan failed: $_";
        $self->_log($c, 'warn', 'fallover_summary', "ledger scan failed: $_");
    };

    try {
        require Comserv::Util::AI::ModelHealth;
        my $h = Comserv::Util::AI::ModelHealth->new(path => Comserv::Util::AI::ModelHealth->default_path($c));
        for my $row (@{ $h->snapshot }) {
            if    ($row->{state} eq 'open')      { push @{ $out->{circuits}{open} }, $row }
            elsif ($row->{state} eq 'half_open') { push @{ $out->{circuits}{half_open} }, $row }
            else                                 { $out->{circuits}{closed_tracked}++ }
        }
    } catch { push @{ $out->{errors} }, "circuit state unreadable: $_" };

    try {
        require Comserv::Util::AI::ModelChains;
        my $ld = Comserv::Util::AI::ModelChains->load($c);
        $out->{chains} = { source => $ld->{source}, path => $ld->{path}, reason => $ld->{reason},
                           removed => $ld->{data}{removed} || [] };
        $out->{chains}{$_} = [ Comserv::Util::AI::ModelChains->chain($ld, $_) ]
            for @Comserv::Util::AI::ModelChains::PURPOSES;
        $out->{caps} = { map { $_ => Comserv::Util::AI::ModelChains->knob($ld, $_) }
            qw(openrouter_soft_cap_day_usd openrouter_soft_cap_week_usd openrouter_soft_cap_month_usd
               circuit_failure_threshold circuit_cooldown_minutes circuit_dead_cooldown_hours) };
    } catch { push @{ $out->{errors} }, "chains unreadable: $_" };

    try {
        my $router = $c->model('AI2::Router');
        my $sp = $router->openrouter_spend($c);
        $out->{spend} = { ok => $sp->{ok} ? 1 : 0, day => $sp->{day}, week => $sp->{week}, month => $sp->{month} };
        $out->{supergrok_guard} = $router->supergrok_guard($c);
        delete $out->{supergrok_guard}{path};
    } catch { push @{ $out->{errors} }, "spend/guard unavailable: $_" };

    # OpenRouter day / week / month / balance (GET /api/v1/key + /credits,
    # cached 60 s) - also under org.openrouter in /ai/usage_live.
    my $or = $self->openrouter_live($c);
    $out->{openrouter} = { map { ($_ => $or->{$_}) } grep { exists $or->{$_} }
        qw(ok day_usd week_usd month_usd balance_usd total_credits total_usage exhausted fetched_at error) };
    if (my $w = $out->{waste}) {
        $w->{by_model} = [ map { +{ model => $_, %{ $w->{by_model}{$_} } } }
                           sort { $w->{by_model}{$b}{failed} <=> $w->{by_model}{$a}{failed} } keys %{ $w->{by_model} } ];
        $w->{minutes} = sprintf('%.1f', $w->{ms} / 60000);
        $w->{free_minutes} = sprintf('%.1f', $w->{free_ms} / 60000);
        # No credit: OpenRouter answers 402 on paid models and throttles
        # :free models with 429 while the balance is <= 0.
        my $no_credit = (defined $or->{balance_usd} && $or->{balance_usd} <= 0) ? 1 : 0;
        $w->{no_credit_now} = $no_credit;
        $w->{credit_related} = $w->{http_402} + ($no_credit ? $w->{free_429} : 0);
    }
    $out->{rates}  = $self->app_rates($c, days => $days);
    $out->{hermes} = $self->hermes_fallover($c, days => $days);
    return $out;
}

=head2 app_rates($c, days => 14)

OK-rate per app request type from the ledger, so Focus-Tune runs
(request_type C<focustune>) and title generation are NOT mixed into the Chat
ok rate. C<< { chat => {calls, ok, pct}, focustune => {...}, title => {...}, other => {...} } >>.

=cut

sub app_rates {
    my ($self, $c, %a) = @_;
    my ($days, $since) = $self->_since($a{days});
    my $out = { window_days => $days };
    try {
        my $rs = $self->_schema($c)->resultset('AiUsageLog')->search({
            'me.created_at' => { '>=' => $since },
            'me.provider'   => { '!=' => 'router' },
        });
        my $n = $self->_count_by($rs, {}, [qw(me.request_type me.status)], [qw(request_type status)]);
        for my $k (keys %$n) {
            my ($rt, $st) = split /\t/, $k, 2;
            my $bucket = $rt eq 'chat' ? 'chat' : $rt eq 'focustune' ? 'focustune'
                       : ($rt =~ /title/ ? 'title' : $rt eq 'generate' ? 'ai_editor' : 'other');
            my $b = $out->{$bucket} ||= { calls => 0, ok => 0 };
            $b->{calls} += $n->{$k};
            $b->{ok}    += $n->{$k} if $st eq 'success';
        }
        for my $b (grep { ref $out->{$_} eq 'HASH' } keys %$out) {
            my $h = $out->{$b};
            $h->{pct} = $h->{calls} ? sprintf('%.1f', 100 * $h->{ok} / $h->{calls}) : '0.0';
        }
    } catch { $out->{error} = "$_" };
    return $out;
}

=head2 hermes_fallover($c, days => 14)

Hermes model hops read from ~/.hermes/state.db session_model_usage (a
session with more than one model = the Hermes fallback chain or a manual
/model switch fired mid-session), plus the SuperGrok guard state
(~/.hermes/supergrok_guard_state.json). Read-only.

=cut

sub hermes_fallover {
    my ($self, $c, %a) = @_;
    my $days = ($a{days} && $a{days} =~ /^\d+$/) ? $a{days} : 14;
    my $out = { ok => 0, model_hops => [], sessions_with_hops => 0, aux_calls => {},
                note => 'auxiliary tasks (title_generation, compression) are not counted as hops' };
    my $db = $ENV{HERMES_STATE_DB} || '/home/shanta/.hermes/state.db';
    if (-r $db) {
        try {
            require DBI;
            my $dbh = DBI->connect("dbi:SQLite:dbname=$db", '', '', { RaiseError => 1, PrintError => 0, ReadOnly => 1 });
            # Auxiliary tasks (title_generation, compression, vision ...) run on
            # their own model inside the same session; they are not hops.
            my $has_task = eval { $dbh->selectrow_array(q{SELECT COUNT(task) FROM session_model_usage LIMIT 1}); 1 };
            my $sth = $dbh->prepare(q{SELECT session_id, model, COALESCE(billing_provider,'') AS provider,
                                             COALESCE(api_call_count,0) AS api_calls, first_seen}
                                    . ($has_task ? q{, COALESCE(task,'') AS task} : q{, '' AS task})
                                    . q{ FROM session_model_usage WHERE last_seen >= ?
                                      ORDER BY session_id, first_seen});
            $sth->execute(time() - $days * 86400);
            my (%by, @order);
            while (my $r = $sth->fetchrow_hashref) {
                if (length $r->{task}) {
                    $out->{aux_calls}{ $r->{task} } += $r->{api_calls};
                    next;
                }
                push @order, $r->{session_id} unless $by{ $r->{session_id} };
                push @{ $by{ $r->{session_id} } }, { model => $r->{model}, provider => $r->{provider}, api_calls => 0 + $r->{api_calls} };
            }
            $dbh->disconnect;
            for my $sid (reverse @order) {
                next unless @{ $by{$sid} } > 1;
                $out->{sessions_with_hops}++;
                push @{ $out->{model_hops} }, { session_id => $sid, models => $by{$sid} }
                    if @{ $out->{model_hops} } < 20;
            }
            $out->{ok} = 1;
        } catch { $out->{error} = "$_" };
    } else {
        $out->{error} = "Hermes state.db not readable at $db";
    }
    my $gf = ($ENV{HOME} || '/home/shanta') . '/.hermes/supergrok_guard_state.json';
    if (-r $gf && open my $fh, '<:raw', $gf) {
        my $g = eval { decode_json(do { local $/; <$fh> }) };
        close $fh;
        $out->{guard} = { map { $_ => $g->{$_} } qw(mode off_today lock_reason daily_cap used_today checked last_switch) }
            if ref $g eq 'HASH';
    }
    return $out;
}



=head2 unified_usage($c, days => 14)

All AI usage in one table (AISYSTEM item 4): app ledger rows (chat, AI
editor = request_type generate, Focus-Tune, Ollama, Hermes ingests) and
Hermes state.db sessions, each tagged with branch, sitename and user, plus
the Today's Focus decision organizer. Read-only.
C<< { rows => [ {source, branch, sitename, user, calls, ok, tokens, cost} ], organizer => {...}, errors => [] } >>

=cut

sub unified_usage {
    my ($self, $c, %a) = @_;
    my ($days, $since) = $self->_since($a{days});
    my $out = { window_days => $days, rows => [], errors => [] };
    my %agg;
    my $add = sub {
        my ($src, $br, $site, $user, $n, $ok, $tok, $cost) = @_;
        my $k = join "\t", map { defined $_ && length $_ ? $_ : '-' } $src, $br, $site, $user;
        my $r = $agg{$k} ||= { calls => 0, ok => 0, tokens => 0, cost => 0 };
        $r->{calls} += $n; $r->{ok} += $ok; $r->{tokens} += $tok || 0; $r->{cost} += $cost || 0;
    };
    try {
        my %site = map { $_->id => ($_->name || 'site ' . $_->id) }
                   eval { $self->_schema($c)->resultset('Site')->search({}, { columns => [qw(id name)], rows => 500 })->all };
        my $q = $self->_base_rs($c, $since)->search({}, {
            columns  => [qw(id request_type provider status total_tokens estimated_cost_usd user_id site_id metadata)],
            order_by => { -desc => 'me.id' }, rows => METADATA_SCAN_ROWS * 2,
        });
        while (my $r = $q->next) {
            my $m  = eval { decode_json($r->get_column('metadata') // '{}') } || {};
            $m = {} unless ref $m eq 'HASH';
            my $rt = $r->get_column('request_type') // '';
            my $pv = $r->get_column('provider') // '';
            next if $pv eq 'router';
            my $src = $rt eq 'generate'  ? 'AI editor'
                    : $rt eq 'focustune' ? 'Focus-Tune'
                    : $rt =~ /title/     ? 'App title'
                    : ($rt eq 'hermes' || ($m->{source} // '') eq 'hermes') ? 'Hermes (ledger ingest)'
                    : $rt eq 'grok_bot'  ? 'Grok Bot (ingest)'
                    : $pv eq 'ollama'    ? 'Ollama (app)'
                    : 'App ' . ($rt || 'chat');
            my $sid = $r->get_column('site_id');
            $add->($src, $m->{branch}, ($m->{sitename} // (defined $sid ? $site{$sid} : undef)),
                   ($m->{username} // (defined $r->get_column('user_id') ? 'uid ' . $r->get_column('user_id') : undef)),
                   1, (($r->get_column('status') // '') eq 'success' ? 1 : 0),
                   $r->get_column('total_tokens'), $r->get_column('estimated_cost_usd'));
        }
    } catch { push @{ $out->{errors} }, "ledger scan failed: $_" };

    my $db = $ENV{HERMES_STATE_DB} || '/home/shanta/.hermes/state.db';
    if (-r $db) {
        try {
            require DBI;
            my $dbh = DBI->connect("dbi:SQLite:dbname=$db", '', '', { RaiseError => 1, PrintError => 0, ReadOnly => 1 });
            my $sth = $dbh->prepare(qq{
                SELECT COALESCE(git_branch,''), COALESCE(user_id,''), COALESCE(billing_provider,''),
                       COUNT(*), COALESCE(SUM(COALESCE(api_call_count,0)),0), COALESCE(SUM($HERMES_TOKEN_SQL),0),
                       COALESCE(SUM(COALESCE(actual_cost_usd, estimated_cost_usd, 0)),0)
                  FROM sessions WHERE started_at >= ?
                 GROUP BY 1, 2, 3});
            $sth->execute(DateTime->now->subtract(days => $days)->epoch);
            while (my @r = $sth->fetchrow_array) {
                $add->('Hermes ' . ($r[2] || 'session'), $r[0], 'workstation', ($r[1] || 'shanta'),
                       $r[4] || $r[3], $r[4] || $r[3], $r[5], $r[6]);
            }
            $dbh->disconnect;
        } catch { push @{ $out->{errors} }, "hermes state.db: $_" };
    }

    try {
        require Comserv::Util::AI::HealthChecks;
        my $org = Comserv::Util::AI::HealthChecks::organizer_state(app_root => eval { $c->path_to('') . '' } // '.');
        $out->{organizer} = $org;
        for my $b (@{ $org->{branches} }) {
            $add->("Ollama organizer ($b->{model})", $b->{branch}, 'workstation', 'decision rank',
                   $b->{asked} || 0, $b->{answered} || 0, $b->{input_tokens}, 0);
        }
    } catch { push @{ $out->{errors} }, "organizer: $_" };

    $out->{rows} = [ map {
        my ($s, $b, $si, $u) = split /\t/, $_, 4;
        +{ source => $s, branch => $b, sitename => $si, user => $u, %{ $agg{$_} },
           cost => sprintf('%.4f', $agg{$_}{cost}) }
    } sort { $agg{$b}{calls} <=> $agg{$a}{calls} || $a cmp $b } keys %agg ];
    return $out;
}

=head2 ai_health($c, days => 14)

Everything the "Health & preflight" card and the admin banners need:
stale-server preflight, meter staleness (alert > 6 h, logged hourly), our
own SuperGrok estimate, the SuperGrok guard switch banner, Ollama health
(Today's Focus), last guard events and the unified usage table.

=cut

sub ai_health {
    my ($self, $c, %a) = @_;
    require Comserv::Util::AI::HealthChecks;
    require Comserv::Util::AI::StalePreflight;
    my $H = 'Comserv::Util::AI::HealthChecks';
    my $root = eval { $c->path_to('') . '' } // '.';
    $root =~ s{/$}{};
    my $out = { errors => [] };
    my $or = $self->openrouter_live($c);
    $out->{openrouter} = { map { ($_ => $or->{$_}) } grep { exists $or->{$_} }
        qw(ok day_usd week_usd month_usd balance_usd total_credits total_usage exhausted fetched_at error) };
    $out->{meters} = Comserv::Util::AI::HealthChecks::meters(app_root => $root, openrouter => $or);
    Comserv::Util::AI::HealthChecks::log_stale_meters($out->{meters}, sub { $self->_log($c, $_[0], 'ai_health', $_[1]) });
    $out->{supergrok_estimate} = Comserv::Util::AI::HealthChecks::supergrok_estimate(app_root => $root);
    $out->{supergrok_pacing} = eval { $self->supergrok_pacing($c, with_jobs => $a{pacing_jobs}) }
        || { errors => [ "supergrok_pacing: " . ($@ || 'unknown') ] };
    try {
        my $g = $c->model('AI2::Router')->supergrok_guard($c);
        delete $g->{path};
        $out->{guard} = $g;
        $out->{guard_banner} = Comserv::Util::AI::HealthChecks::guard_banner($g);
    } catch { push @{ $out->{errors} }, "guard: $_" };
    eval {
        require Comserv::Util::AI::HermesOverrunGuard;
        $out->{overrun} = Comserv::Util::AI::HermesOverrunGuard->status;
        $out->{overrun_banner} = Comserv::Util::AI::HermesOverrunGuard::banner($out->{overrun});
        $out->{handoff_banner} = $out->{overrun}{handoff_banner} if $out->{overrun}{handoff_banner};
    };
    $out->{ollama} = Comserv::Util::AI::HealthChecks::ollama_health(journal => 1);
    $out->{preflight} = eval { Comserv::Util::AI::StalePreflight::check_all() } || [];
    push @{ $out->{errors} }, "preflight: $@" if $@;
    my $ev = ($ENV{HOME} || '/home/shanta') . '/.hermes/supergrok_guard_events.jsonl';
    if (open my $fh, '<', $ev) {
        my @l = <$fh>; close $fh;
        $out->{guard_events} = [ reverse grep { $_ } map { my $d = eval { decode_json($_) }; $d ? { %$d, at_pt => Comserv::Util::AI::HealthChecks::pt(Comserv::Util::AI::HealthChecks::iso_epoch($d->{at})) } : undef } @l[ ($#l > 4 ? $#l - 4 : 0) .. $#l ] ];
    }
    my $nf = ($ENV{HOME} || '/home/shanta') . '/.hermes/supergrok_notice.txt';
    if (open my $fh, '<', $nf) { local $/; ($out->{hermes_notice} = <$fh> // '') =~ s/\s+$//; close $fh }
    $out->{unified} = $self->unified_usage($c, days => $a{days});
    $out->{estimator} = eval {
        my $e = $self->usage_estimator($c);
        my $roles = eval { $c->session->{roles} } || [];
        $roles = [ split /,/, $roles ] unless ref $roles eq 'ARRAY';
        if (eval { $c->session->{username} } && grep { /^admin$/i } @$roles) {
            require Digest::SHA;
            $c->session->{ai_eval_csrf} ||= Digest::SHA::sha256_hex(time() . rand() . $$);
            $e->{csrf} = $c->session->{ai_eval_csrf};
        }
        require POSIX;
        { local $ENV{TZ} = 'America/Los_Angeles'; POSIX::tzset(); $e->{now_pt_input} = POSIX::strftime('%Y-%m-%d %H:%M', localtime); }
        POSIX::tzset();
        $e;
    } || { errors => [ "usage_estimator: $@" ], consumers => [] };
    return $out;
}

# Small, fast subset for the admin banner on /ai (no network, no journal).
sub ai_banner {
    my ($self, $c) = @_;
    require Comserv::Util::AI::HealthChecks;
    my $root = eval { $c->path_to('') . '' } // '.';
    my $out = {};
    try {
        my $g = $c->model('AI2::Router')->supergrok_guard($c);
        $out->{guard_banner} = Comserv::Util::AI::HealthChecks::guard_banner($g);
    } catch {};
    my $m = Comserv::Util::AI::HealthChecks::meters(app_root => $root);
    $out->{stale_meters} = $m->{stale};
    eval {
        require Comserv::Util::AI::HermesOverrunGuard;
        $out->{overrun} = Comserv::Util::AI::HermesOverrunGuard->status;
        $out->{overrun_banner} = Comserv::Util::AI::HermesOverrunGuard::banner($out->{overrun});
        $out->{handoff_banner} = $out->{overrun}{handoff_banner} if $out->{overrun}{handoff_banner};
    };
    return $out;
}


=head2 usage_estimator($c)

One usage estimator for every AI consumer (Grok Bot, Super Grok, OpenRouter,
Ollama): app-side estimate from the Ledger (DBIx::Class) + Hermes state.db,
normalized against manual readings (data/ai_usage_readings.jsonl, admin form
on /ai/usage#usage-estimator), the grok.com add-on and the OpenRouter API.
Pure maths in Comserv::Util::AI::UsageEstimator.

=cut

# ---------------------------------------------------------------------------
# Super Grok use-it-up pacing (Oct 8 2026) - Util::AI::SuperGrokPacing.
# Units = Hermes xai-oauth tokens per call from agent.log (zone-aware parse,
# HermesOverrunGuard::parse_api_calls) + app Ledger provider=supergrok tokens.
# Calibrated against Super Grok readings (manual form + grok.com add-on history).
# ---------------------------------------------------------------------------
our %SG_CALLS_CACHE;   # { key => "file:mtime|...", at => epoch, calls => [...] }

sub _hermes_xai_calls {
    my ($self, %a) = @_;
    my $dir = $a{log_dir} || ($ENV{HERMES_HOME} || (($ENV{HOME} || '/home/shanta') . '/.hermes')) . '/logs';
    my @files = grep { -r $_ } map { "$dir/agent.log$_" } ('.3', '.2', '.1', '');
    my $key = join '|', map { $_ . ':' . ((stat $_)[9] // 0) } @files;
    return $SG_CALLS_CACHE{calls}
        if $SG_CALLS_CACHE{key} && $SG_CALLS_CACHE{key} eq $key && time - ($SG_CALLS_CACHE{at} // 0) < 60;
    require Comserv::Util::AI::HermesOverrunGuard;
    my @c;
    for my $f (@files) {
        open my $fh, '<', $f or next;
        local $/; my $t = <$fh>; close $fh;
        push @c, grep { $_->{provider} eq 'xai-oauth' }
            @{ Comserv::Util::AI::HermesOverrunGuard::parse_api_calls($t, undef, all => 1, anchor => (stat $f)[9]) };
    }
    my %seen;
    @c = sort { $a->{t} <=> $b->{t} } grep { !$seen{"$_->{t}|$_->{session}|$_->{in}|$_->{out}"}++ } @c;
    %SG_CALLS_CACHE = (key => $key, at => time, calls => \@c);
    return \@c;
}

sub _supergrok_readings {
    my ($self, $root) = @_;
    require Comserv::Util::AI::UsageEstimator;
    require Comserv::Util::AI::HealthChecks;
    my @rd = grep { $_->{consumer} eq 'supergrok' } @{ Comserv::Util::AI::UsageEstimator::read_readings($root) };
    # grok.com add-on history (Build %) - the readings the add-on posts.
    if (open my $fh, '<', "$root/root/static/ai/grokcom_usage_history.jsonl") {
        while (my $l = <$fh>) {
            my $d = eval { JSON::PP->new->decode($l) } or next;
            next unless defined $d->{build} && $d->{build} =~ /^\d+(?:\.\d+)?$/;
            my $at = Comserv::Util::AI::HealthChecks::iso_epoch($d->{at}) or next;
            push @rd, { at => $at, value => 0 + $d->{build}, kind => 'used',
                        source => (($d->{reason} // '') =~ /^derived/ ? 'derived' : 'addon') };
        }
        close $fh;
    }
    return \@rd;
}

# Cheap meter freshness for /ai/eval (no agent.log parse).
sub supergrok_meter {
    my ($self, $c, %a) = @_;
    require Comserv::Util::AI::SuperGrokPacing;
    my $root = eval { $c->path_to('') . '' } // '.';
    $root =~ s{/$}{};
    return Comserv::Util::AI::SuperGrokPacing::meter_status(readings => $self->_supergrok_readings($root), now => $a{now} // time, last_seen => _grokcom_now($root));
}

# Live grok.com meter (add-on rewrites the file on every post; 'at' = last seen).
sub _grokcom_now {
    my ($root) = @_;
    return eval {
        require JSON::MaybeXS; open my $gfh, '<', "$root/root/static/ai/grokcom_usage.json" or die;
        local $/; my $j = JSON::MaybeXS::decode_json(<$gfh>); close $gfh;
        { value => $j->{build}, at => Comserv::Util::AI::HealthChecks::iso_epoch($j->{at}) };
    };
}

sub supergrok_pacing {
    my ($self, $c, %a) = @_;
    require Comserv::Util::AI::SuperGrokPacing;
    require Comserv::Util::AI::UsageEstimator;
    require Comserv::Util::AI::HealthChecks;
    my $P   = 'Comserv::Util::AI::SuperGrokPacing';
    my $now = $a{now} // time;
    my $root = eval { $c->path_to('') . '' } // '.';
    $root =~ s{/$}{};
    my @err;
    my @rd = @{ $self->_supergrok_readings($root) };
    my $anchor = $P->can('default_anchor')->();
    my $calls = $a{calls} || eval { $self->_hermes_xai_calls(%a) } || [];
    push @err, "agent.log: $@" if $@;
    my $utc = sub { my @t = gmtime $_[0]; sprintf('%04d-%02d-%02d %02d:%02d:%02d', $t[5] + 1900, $t[4] + 1, @t[3, 2, 1, 0]) };
    my $ledger_tok = sub {
        my ($from, $to) = @_;
        return 0 if $a{no_ledger};
        my $r = eval {
            $self->_base_rs($c, $utc->($from), { 'me.provider' => 'supergrok',
                'me.created_at' => { '>=' => $utc->($from), '<' => $utc->($to) } })
                ->search({}, { select => [ { sum => 'me.total_tokens' } ], as => ['t'] })->first;
        };
        return $r ? 0 + ($r->get_column('t') // 0) : 0;
    };
    my $units = sub {
        my ($from, $to) = @_;
        my $t = 0;
        my $w = $P->can('call_weight');
        for (@$calls) { next if $_->{t} < $from; last if $_->{t} >= $to; $t += ($_->{in} + $_->{out}) * $w->($_) }
        return ($t + $ledger_tok->($from, $to)) / 1e6;
    };
    my $fit = $P->can('fit_rate')->(readings => \@rd, units => $units, now => $now, anchor => $anchor);
    # Live meter: grok.com add-on rewrites this file on every post (history only on change).
    my $gnow = _grokcom_now($root);
    my $p = $P->can('pacing')->(readings => \@rd, units => $units, rate => $fit->{rate}, now => $now, anchor => $anchor,
        ($gnow ? (meter_now => $gnow) : ()),
        alert_cfg => (eval { $self->pacing_config($c)->{alerts} } || {}),
        daily_cfg => (eval { $self->pacing_config($c)->{daily} } || {}));
    $p->{calibration} = $fit;
    $p->{meter} = $P->can('meter_status')->(readings => \@rd, now => $now, last_seen => $gnow);
    # Daily switch state written by ~/.hermes/scripts/supergrok_daily_guard.py (owner).
    if (open my $gfh, '<', "$root/root/static/ai/supergrok_guard.json") {
        local $/; my $g = eval { JSON::PP->new->decode(<$gfh>) } || {}; close $gfh;
        $p->{guard} = { map { ($_ => $g->{$_}) } qw(mode off_today lock_reason lock_date switch_alias switch_model checked decision_source daily_cap used_today) };
    }
    push @{ $p->{warnings} }, $p->{meter}{prompt} if $p->{meter}{stale};
    my $cfg = $self->pacing_config($c);
    $p->{auto_queue} = $cfg->{auto_queue} ? 1 : 0;
    if ($p->{endgame} || $a{with_jobs}) {
        $p->{jobs} = eval { $self->_pacing_jobs($c) } || [];
        push @err, "jobs: $@" if $@;
        $_->{hermes} = $P->can('hermes_command')->($_, worktree => $cfg->{worktree}) for @{ $p->{jobs} };
    }
    $p->{errors} = \@err;
    $p->{source} = 'Hermes agent.log xai-oauth tokens + Ledger supergrok tokens, calibrated on Super Grok readings';
    return $p;
}

sub pacing_config_file { my ($self, $c) = @_; my $r = eval { $c->path_to('') . '' } // '.'; $r =~ s{/$}{}; "$r/data/supergrok_pacing.json" }

sub pacing_config {
    my ($self, $c) = @_;
    my $f = $self->pacing_config_file($c);
    my $d = {};
    if (open my $fh, '<', $f) { local $/; $d = eval { JSON::PP->new->decode(<$fh>) } || {}; close $fh }
    return { auto_queue => ($d->{auto_queue} ? 1 : 0), worktree => $d->{worktree}, alerts => (ref $d->{alerts} eq 'HASH' ? $d->{alerts} : {}),
             daily => { map { ($_ => $d->{$_}) } grep { defined $d->{$_} } qw(week_off_at extra_today_pct extra_today_date allow_overrun_date day_start_hour) },
             updated_by => $d->{updated_by}, updated_at => $d->{updated_at} };
}

sub set_auto_queue {
    my ($self, $c, $on, $by) = @_;
    my $f = $self->pacing_config_file($c);
    my $d = {};
    if (open my $fh, '<', $f) { local $/; $d = eval { JSON::PP->new->decode(<$fh>) } || {}; close $fh }
    $d->{auto_queue} = $on ? JSON::PP::true() : JSON::PP::false();
    $d->{updated_by} = $by;
    $d->{updated_at} = time;
    open my $out, '>', "$f.tmp" or return "cannot write $f: $!";
    print $out JSON::PP->new->canonical->pretty->encode($d);
    close $out;
    rename "$f.tmp", $f or return "rename failed: $!";
    $self->_log($c, 'info', 'set_auto_queue', 'Super Grok auto-queue ' . ($on ? 'ON' : 'OFF') . ' by ' . ($by // '?'));
    return undef;
}

# Backlog for the endgame list (DBIx::Class only).
sub _pacing_jobs {
    my ($self, $c) = @_;
    my $schema = $self->_schema($c);
    my (@tickets, @props, @todos);
    eval {
        @tickets = map { { id => $_->id, number => $_->ticket_number, subject => $_->subject, priority => $_->priority, status => $_->status } }
            $schema->resultset('SupportTicket')->search({ status => { -in => [qw(open in_progress pending new)] } },
                { order_by => { -desc => 'created_at' }, rows => 30 })->all;
    };
    eval {
        @props = map { { id => $_->id, title => $_->title, status => $_->status, change_type => $_->change_type, report_id => $_->report_id } }
            $schema->resultset('AiEvalProposal')->search({ status => { -in => [qw(proposed approved)] } },
                { order_by => { -desc => 'id' }, rows => 30 })->all;
    };
    my $root = eval { $c->path_to('') . '' } // '.'; $root =~ s{/$}{};
    my %rank;
    if (open my $fh, '<', "$root/data/ai_rank_order.json") {
        local $/; my $d = eval { JSON::PP->new->decode(<$fh>) } || {}; close $fh;
        for my $b (values %{ $d->{branches} || {} }) {
            for my $id (keys %{ $b->{rows} || {} }) {
                my $r = $b->{rows}{$id};
                $rank{$id} = { score => $r->{score}, reason => $r->{reason} }
                    if !$rank{$id} || ($r->{score} // 0) > ($rank{$id}{score} // 0);
            }
        }
    }
    eval {
        my @ids = keys %rank;
        my @rows = @ids ? $schema->resultset('Todo')->search(
            { record_id => { -in => \@ids }, status => { -not_in => [ 3, 4, 'DONE', 'Completed', 'completed', 'Closed', 'closed', 'Done' ] } },
            { columns => [qw(record_id subject priority)] })->all : ();
        @todos = map { { id => $_->record_id, subject => $_->subject, priority => $_->priority,
                         rank_score => $rank{ $_->record_id }{score}, reason => $rank{ $_->record_id }{reason} } } @rows;
    };
    return Comserv::Util::AI::SuperGrokPacing::recommend_jobs(tickets => \@tickets, proposals => \@props, todos => \@todos);
}

sub usage_estimator {
    my ($self, $c, %a) = @_;
    require Comserv::Util::AI::UsageEstimator;
    require Comserv::Util::AI::HealthChecks;
    my $E   = 'Comserv::Util::AI::UsageEstimator';
    my $now = $a{now} // time;
    my $root = eval { $c->path_to('') . '' } // '.';
    $root =~ s{/$}{};
    my $out = { consumers => [], errors => [], readings_file => 'data/ai_usage_readings.jsonl' };
    my $all = Comserv::Util::AI::UsageEstimator::read_readings($root);
    my %by; push @{ $by{ $_->{consumer} } }, $_ for @$all;
    $out->{recent_readings} = [ reverse @$all[ ($#$all > 9 ? $#$all - 9 : 0) .. $#$all ] ] if @$all;

    my $utc = sub { my @t = gmtime $_[0]; sprintf('%04d-%02d-%02d %02d:%02d:%02d', $t[5] + 1900, $t[4] + 1, @t[3, 2, 1, 0]) };
    # Ledger: (count, cost) since/until epoch with extra conditions (DBIx::Class).
    my $ledger = sub {
        my ($since, $extra, $until) = @_;
        my $r = eval {
            my %x = %{ $extra || {} };
            $x{'me.created_at'} = { '>=' => $utc->($since), (defined $until ? ('<' => $utc->($until)) : ()) };
            $self->_base_rs($c, $utc->($since), \%x)->search({}, {
                select => [ { count => 'me.id' }, { sum => 'me.estimated_cost_usd' } ], as => [qw(n cost)],
            })->first;
        };
        push @{ $out->{errors} }, "ledger: $@" if $@;
        return $r ? (0 + ($r->get_column('n') // 0), 0 + ($r->get_column('cost') // 0)) : (0, 0);
    };
    # Hermes state.db (external SQLite, read-only; same pattern as hermes_summary).
    my $db = $ENV{HERMES_STATE_DB} || (($ENV{HOME} || '/home/shanta') . '/.hermes/state.db');
    my $hermes = sub {
        my ($since, $where, $until) = @_;
        return (0, 0) unless -r $db;
        my @r = eval {
            require DBI;
            my $dbh = DBI->connect("dbi:SQLite:dbname=$db", '', '', { RaiseError => 1, PrintError => 0, ReadOnly => 1 });
            my @v = $dbh->selectrow_array(
                "SELECT COALESCE(SUM(COALESCE(api_call_count,0)),0), COALESCE(SUM(COALESCE(actual_cost_usd, estimated_cost_usd, 0)),0)
                   FROM sessions WHERE started_at >= ? AND started_at < ? AND ($where)", undef, $since, $until // $now + 1);
            $dbh->disconnect; @v;
        };
        push @{ $out->{errors} }, "hermes: $@" if $@;
        return @r ? (0 + $r[0], 0 + $r[1]) : (0, 0);
    };
    my $W_XAI = q{COALESCE(billing_provider,'') IN ('xai-oauth','supergrok','xai') OR COALESCE(model,'') LIKE '%grok%'};
    my $W_OR  = q{COALESCE(billing_provider,'') = 'openrouter'};
    my $W_OL  = q{COALESCE(billing_provider,'') LIKE 'ollama%' OR COALESCE(billing_provider,'') = 'custom'};
    my $read = sub { my $f = shift; open my $fh, '<', $f or return {}; local $/; my $d = eval { JSON::PP->new->decode(<$fh>) }; ref $d eq 'HASH' ? $d : {} };

    # ---- Grok Bot: every logged Bot event (turns, routine runs incl. failed, teammate
    # wakes, CSC developer agent HelpDesk activations) x a per-event % fitted from
    # manual reading deltas (UsageEstimator::bot_burn); % per hour when no events.
    {
        require Time::Local;
        my $since = $now - 21 * 86400;
        my $epoch = sub {
            my $v = shift; return undef unless defined $v;
            $v = "$v"; $v =~ s/T/ /;
            my @p = $v =~ /^(\d{4})-(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)/ or return undef;
            return Time::Local::timegm($p[5], $p[4], $p[3], $p[2], $p[1] - 1, $p[0]);
        };
        my %kind_map = (turn => 'turn', grok_bot => 'turn', chat => 'turn',
            routine_run => 'routine_run', routine => 'routine_run', daily_eval => 'routine_run', eval => 'routine_run',
            wake => 'wake', teammate_wake => 'wake', teammate => 'wake',
            csc_helpdesk => 'csc_helpdesk', helpdesk => 'csc_helpdesk', csc => 'csc_helpdesk', csc_developer => 'csc_helpdesk');
        my (@events, %src);
        my @rows = eval {
            $self->_base_rs($c, $utc->($since), { 'me.request_type' => [qw(grok_bot daily_eval)] })->search({}, {
                columns => [qw(created_at status metadata request_type)], order_by => 'me.created_at' })->all;
        };
        push @{ $out->{errors} }, "bot events: $@" if $@;
        for my $r (@rows) {
            my $at = $epoch->($r->get_column('created_at')) or next;
            my $meta = eval { JSON::PP->new->decode($r->get_column('metadata') // '{}') } || {};
            my $rt = $r->get_column('request_type') // '';
            my $k = $rt eq 'daily_eval' ? 'routine_run' : ($kind_map{ lc($meta->{event} // $meta->{kind} // 'turn') } // 'turn');
            push @events, { at => $at, kind => $k, status => $r->get_column('status') // 'success', from => "ledger:$rt" };
            $src{"ledger $rt"}++;
        }
        # Routine runs that only left an eval report (no daily_eval Ledger row within 2 h).
        my @reps = eval {
            $self->_schema($c)->resultset('AiEvalReport')->search({ 'me.created_at' => { '>=' => $utc->($since) } },
                { columns => [qw(created_at updated_at source)] })->all;
        };
        for my $r (@reps) {
            my %seen;
            for my $col (qw(created_at updated_at)) {
                my $at = $epoch->($r->get_column($col)) or next;
                next if $seen{$at}++;
                next if grep { $_->{kind} eq 'routine_run' && abs($_->{at} - $at) < 7200 } @events;
                push @events, { at => $at, kind => 'routine_run', status => 'success', from => 'eval_report' };
                $src{'eval reports'}++;
            }
        }
        my $bb = $E->can('bot_burn')->(readings => $by{grok_bot} || [], events => \@events, now => $now);
        my $rate = $bb->{pct_per_event} // 0.5;
        my $units = sub { my ($s, $u) = @_; scalar grep { $_->{at} > $s && (!defined $u || $_->{at} <= $u) } @events };
        my $n24 = $units->($now - 86400);
        my $e = $E->can('estimate')->(consumer => 'grok_bot', now => $now, readings => $by{grok_bot} || [], rate => $rate,
            units_since => sub { $units->($_[0]) }, burn_24h => $n24,
            (defined $bb->{pct_per_hour} && $bb->{method} eq 'per_hour' ? (burn_per_hour => $bb->{pct_per_hour}) : ()),
            notes => [
                sprintf('Counted: %d Bot events in 21 d (%s). Event kinds: Grok Bot turns, routine runs (failed included), teammate wakes, CSC developer agent HelpDesk activations - post them to /ai/usage_ingest source=grok_bot request_type=turn|routine_run|wake|csc_helpdesk.',
                    scalar(@events), (%src ? join(', ', map { "$_ $src{$_}" } sort keys %src) : 'none logged')),
                ($bb->{method} eq 'per_event'
                    ? sprintf('Calibration: %.2f %% per event fitted from %d reading interval(s).', $bb->{pct_per_event}, scalar @{ $bb->{pairs} })
                    : $bb->{method} eq 'per_hour'
                    ? sprintf('Calibration: no events between readings, so %.2f %%/h from %d reading interval(s) - ESTIMATED, not counted.', $bb->{pct_per_hour}, scalar @{ $bb->{pairs} })
                    : 'Calibration: not enough same-cycle readings yet (default 0.5 %/event).'),
                @{ $bb->{notes} || [] } ]);
        if (defined $bb->{estimate}) {
            $e->{estimate} = $bb->{estimate};
            $e->{estimate_fmt} = $bb->{estimate_fmt} . ($bb->{estimated_pct} > 0 ? ' (est.)' : '');
            if (defined $e->{burn_per_hour} && defined $e->{hours_to_reset}) {
                $e->{projection} = $bb->{estimate} + $e->{burn_per_hour} * $e->{hours_to_reset};
                $e->{projection_fmt} = sprintf('%.1f%%', $e->{projection});
                $e->{over_at_reset} = $e->{projection} >= 100 ? 1 : 0;
            }
        }
        $e->{bot_burn} = $bb;
        push @{ $out->{consumers} }, $e;
    }
    # ---- Super Grok: Hermes xai-oauth calls + app supergrok chat x 0.05 %; add-on reading.
    {
        my $rate = $Comserv::Util::AI::HealthChecks::PCT_PER_CALL || 0.05;
        my $sg = $read->("$root/root/static/ai/supergrok_guard.json");
        my $g  = $read->("$root/root/static/ai/grokcom_usage.json");
        my $reset = Comserv::Util::AI::HealthChecks::iso_epoch($sg->{reset_at});
        my @rd = @{ $by{supergrok} || [] };
        my $gat = Comserv::Util::AI::HealthChecks::iso_epoch($g->{at});
        if (defined $g->{build} && $gat) {
            my ($ar) = $E->can('make_reading')->(consumer => 'supergrok', value => $g->{build}, kind => 'used',
                at => $gat, source => 'addon', note => 'grok.com add-on (Build %)', now => $now);
            @rd = sort { $a->{at} <=> $b->{at} } (@rd, $ar) if $ar;
        }
        my $f = { 'me.provider' => 'supergrok' };
        my $units = sub { my ($s, $u) = @_; ($hermes->($s, $W_XAI, $u))[0] + ($ledger->($s, $f, $u))[0] };
        my $rs = $E->can('next_reset')->($reset, $now, 7);
        my $cs = defined $rs ? $rs - 7 * 86400 : $now - 7 * 86400;
        my $e = $E->can('estimate')->(consumer => 'supergrok', now => $now, readings => \@rd, rate => $rate, reset_at => $reset,
            units_since => sub { $units->($_[0]) }, app_cycle => $units->($cs) * $rate,
            app_at_reading => sub { $_[0] < $cs ? undef : $units->($cs, $_[0]) * $rate },
            burn_24h => $units->($now - 86400),
            notes => [ "App-side: Hermes xai-oauth api calls + app supergrok chats x $rate %/call; add-on reading " .
                       ($gat ? 'last ' . Comserv::Util::AI::HealthChecks::pt($gat) : 'none') ]);
        push @{ $out->{consumers} }, $e;
    }
    # ---- OpenRouter: Ledger openrouter $ + Hermes openrouter $; reading = OpenRouter API week.
    {
        my $or = eval { $self->openrouter_live($c) } || {};
        my @t = gmtime $now; my $dow = ($t[6] + 6) % 7;   # Monday 00:00 UTC week
        require Time::Local;
        my $week_start = Time::Local::timegm(0, 0, 0, $t[3], $t[4], $t[5]) - $dow * 86400;
        my @rd = @{ $by{openrouter} || [] };
        if ($or->{ok} && defined $or->{week_usd}) {
            my ($ar) = $E->can('make_reading')->(consumer => 'openrouter', value => sprintf('%.4f', $or->{week_usd}), kind => 'used',
                at => ($or->{fetched_at} || $now), source => 'api', note => 'OpenRouter /auth/key usage_weekly', now => $now + 300);
            @rd = sort { $a->{at} <=> $b->{at} } (@rd, $ar) if $ar;
        }
        my $f = { 'me.provider' => 'openrouter' };
        my $cost = sub { my ($s, $u) = @_; ($hermes->($s, $W_OR, $u))[1] + ($ledger->($s, $f, $u))[1] };
        my (undef, $ed) = $ledger->($week_start, { 'me.provider' => 'openrouter', 'me.request_type' => 'generate' });
        my (undef, $hm) = $hermes->($week_start, $W_OR);
        my (undef, $ap) = $ledger->($week_start, $f);
        my $e = $E->can('estimate')->(consumer => 'openrouter', now => $now, readings => \@rd, rate => 1,
            reset_at => $week_start + 7 * 86400, cap => 11.50,
            units_since => sub { $cost->($_[0]) }, app_cycle => $cost->($week_start),
            app_at_reading => sub { $_[0] < $week_start ? undef : $cost->($week_start, $_[0]) },
            burn_24h => $cost->($now - 86400),
            notes => [ sprintf('App-side this week: Hermes $%.2f, app $%.2f (AI editor $%.2f). Caps $1.65/day, $11.50/week, $50/month (Hermes overrun guard).', $hm, $ap, $ed),
                       ($or->{ok} ? sprintf('OpenRouter API: day $%.2f, week $%.2f, month $%.2f, balance $%.2f', map { $or->{$_} // 0 } qw(day_usd week_usd month_usd balance_usd)) : 'OpenRouter API unavailable') ]);
        $e->{breakdown} = { hermes => $hm, app => $ap, ai_editor => $ed };
        # Unlogged-spend reconciliation (billed vs Ledger + Hermes).
        $e->{reconcile} = eval {
            require Time::Local;
            my @g = gmtime $now;
            my $day_start = Time::Local::timegm(0, 0, 0, @g[3, 4, 5]);
            my $prices = $self->_openrouter_prices($root);
            my $hermes_tokens = sub {
                my ($since) = @_;
                return {} unless -r $db;
                require DBI;
                my $dbh = DBI->connect("dbi:SQLite:dbname=$db", '', '', { RaiseError => 1, PrintError => 0, ReadOnly => 1 });
                my $rows = $dbh->selectall_arrayref(
                    "SELECT model, SUM(COALESCE(input_tokens,0)), SUM(COALESCE(output_tokens,0)), SUM(COALESCE(cache_read_tokens,0))
                       FROM sessions WHERE started_at >= ? AND ($W_OR) GROUP BY model", undef, $since);
                $dbh->disconnect;
                return { map { ($_->[0] // '' => { in => $_->[1], out => $_->[2], cache_read => $_->[3] }) } @$rows };
            };
            my $part = sub {
                my ($since) = @_;
                my (undef, $audit) = $ledger->($since, { 'me.request_type' => 'openrouter_call' });
                my (undef, $feat)  = $ledger->($since, $f);
                my (undef, $hc)    = $hermes->($since, $W_OR);
                my $tok = $hermes_tokens->($since);
                return { app_audit => $audit, app_feature => $feat, hermes_est => $hc,
                         (%$prices ? (hermes_full => Comserv::Util::AI::UsageEstimator::price_tokens($tok, $prices, cache_full => 1)) : ()) };
            };
            Comserv::Util::AI::UsageEstimator::reconcile(
                threshold => 0.50,
                day  => { billed => ($or->{ok} ? $or->{day_usd} : undef), %{ $part->($day_start) } },
                week => { billed => ($or->{ok} ? $or->{week_usd} : undef), days => (($now - $week_start) / 86400 || 1), %{ $part->($week_start) } },
            );
        } || { error => "reconcile: $@" };
        push @{ $out->{consumers} }, $e;
    }
    # ---- Ollama: local calls (no cap, rolling 7 days).
    {
        my $f = { 'me.provider' => 'ollama' };
        my $calls = sub { ($hermes->($_[0], $W_OL))[0] + ($ledger->($_[0], $f))[0] };
        my $e = $E->can('estimate')->(consumer => 'ollama', now => $now, readings => $by{ollama} || [], rate => 1,
            app_cycle => $calls->($now - 7 * 86400), burn_24h => $calls->($now - 86400),
            units_since => ($by{ollama} ? sub { $calls->($_[0]) } : undef),
            notes => [ 'Local, no cap: calls in the last 7 days (Ledger provider=ollama + Hermes ollama sessions)' ]);
        push @{ $out->{consumers} }, $e;
    }
    return $out;
}


# Public OpenRouter price list (free endpoint), cached 24 h in
# data/ai_openrouter_prices.json: { model => [prompt, completion, cache_read] } $/token.
sub _openrouter_prices {
    my ($self, $root) = @_;
    my $f = "$root/data/ai_openrouter_prices.json";
    my $cached = eval { open my $fh, '<', $f or die; local $/; decode_json(<$fh>) };
    return $cached->{prices} if ref $cached eq 'HASH' && ($cached->{at} // 0) > time - 86400 && ref $cached->{prices} eq 'HASH';
    my $p = eval {
        require HTTP::Tiny;
        my $r = HTTP::Tiny->new(timeout => 10)->get('https://openrouter.ai/api/v1/models');
        die "HTTP $r->{status}\n" unless $r->{success};
        my %p;
        for my $m (@{ decode_json($r->{content})->{data} || [] }) {
            my $pr = $m->{pricing} || {};
            $p{ $m->{id} } = [ 0 + ($pr->{prompt} // 0), 0 + ($pr->{completion} // 0),
                               (defined $pr->{input_cache_read} ? 0 + $pr->{input_cache_read} : undef) ];
        }
        \%p;
    };
    if ($p && %$p) {
        if (open my $fh, '>', "$f.tmp") { print $fh encode_json({ at => time, prices => $p }); close $fh; rename "$f.tmp", $f }
        return $p;
    }
    return ref $cached eq 'HASH' && ref $cached->{prices} eq 'HASH' ? $cached->{prices} : {};
}

1;
