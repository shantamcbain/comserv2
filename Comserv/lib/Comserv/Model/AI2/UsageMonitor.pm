package Comserv::Model::AI2::UsageMonitor;

use Moose;
use namespace::autoclean -except => [qw(try catch finally)];
use Try::Tiny;
use JSON qw(decode_json);
use DateTime;

extends 'Catalyst::Model';

has 'logger' => (
    is      => 'rw',
    lazy    => 1,
    default => sub { require Comserv::Util::Logging; Comserv::Util::Logging->instance },
);
has 'schema_override'       => ( is => 'rw', default => undef );
has 'golden_store_override' => ( is => 'rw', default => undef );

# Diagnostic rows that are not user AI calls (same exclusions as Usage.pm).
use constant EXCLUDED_REQUEST_TYPES => qw(grok_balance_check provider_snapshot);
use constant METADATA_SCAN_ROWS     => 2000;

# ===================================================================
# AI2::UsageMonitor — admin Ledger view for /ai/usage (ai_usage_logs).
# All aggregation is DBIx::Class group_by / functions — no raw SQL.
#
# Heuristics (documented on the page):
#  - error        = status != 'success'
#  - http_404     = error rows whose error_message contains '404'
#  - zero_token_ok = status 'success' with total_tokens 0/NULL, excluding the
#    ai2-grounding fallback (a deliberate no-model-call reply) — these are
#    "successes" that probably produced nothing billable/useful.
#  - grounded     = Ledger grounding columns when present; otherwise tallied
#    from metadata.grounding (written since 2026-09-24) for the period.
# ===================================================================

sub _schema {
    my ($self, $c) = @_;
    return $self->schema_override if $self->schema_override;
    return $c->model('DBEncy')->schema;
}

sub _log {
    my ($self, $c, $level, $sub, $msg) = @_;
    eval { $self->logger->log_with_details($c, $level, __FILE__, __LINE__, $sub, $msg) };
}

sub _base_rs {
    my ($self, $c, $since) = @_;
    return $self->_schema($c)->resultset('AiUsageLog')->search({
        'me.created_at'   => { '>=' => $since },
        'me.request_type' => [ -or => { -not_in => [ EXCLUDED_REQUEST_TYPES ] }, undef ],
    });
}

sub _grouped {
    my ($self, $rs, $keys, $key_as) = @_;
    my @rows;
    my $g = $rs->search({}, {
        select   => [ @$keys,
                      { count => 'me.id',               -as => 'calls' },
                      { sum   => 'me.total_tokens',     -as => 'tokens' },
                      { sum   => 'me.estimated_cost_usd', -as => 'cost' } ],
        as       => [ @$key_as, qw(calls tokens cost) ],
        group_by => $keys,
    });
    while (my $r = $g->next) {
        push @rows, { map { $_ => $r->get_column($_) } (@$key_as, qw(calls tokens cost)) };
    }
    return \@rows;
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
    my $zero_cond = { 'me.status' => 'success',
                      'me.provider' => { '!=' => 'ai2-grounding' },
                      -or => [ { 'me.total_tokens' => 0 }, { 'me.total_tokens' => undef } ] };
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

1;

__END__

=head1 NAME

Comserv::Model::AI2::UsageMonitor - admin Ledger / Golden Data monitor for /ai/usage

=head1 DESCRIPTION

Aggregates ai_usage_logs (the Ledger) with DBIx::Class: calls by day, provider
and model breakdown, success vs error (incl. 0-token "successes" and 404s),
tokens, logged cost, grounded vs Ungrounded Generation, and Golden Data store
counts by status.

=cut
