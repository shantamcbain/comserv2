package Comserv::Model::AI2::UsageMonitor;

use Moose;
use namespace::autoclean -except => [qw(try catch finally)];
use Try::Tiny;
use JSON qw(decode_json encode_json);
use DateTime;

use Comserv::Util::Logging;

extends 'Catalyst::Model';

has 'logging' => (
    is      => 'ro',
    lazy    => 1,
    default => sub { Comserv::Util::Logging->instance },
);
has 'schema_override' => ( is => 'rw', default => undef );

# Diagnostic rows that are not user AI calls.
use constant EXCLUDED_REQUEST_TYPES => qw(grok_balance_check provider_snapshot);

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
    for my $r (@{ $out->{by_model} }) {
        $r->{avg_tokens} = $r->{calls} ? int(($r->{tokens} || 0) / $r->{calls}) : 0;
    }
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

sub hermes_summary {
    my ($self, $c, %a) = @_;
    my $days = ($a{days} && $a{days} =~ /^\d+$/) ? $a{days} : 14;
    my $out = {
        ok => 0, source => 'hermes_state.db', days => $days,
        totals => { calls => 0, tokens => 0, cost => 0 },
        by_day => [], by_model => [], by_source => [],
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
            q{SELECT COUNT(*) AS calls,
                     COALESCE(SUM(COALESCE(input_tokens,0)+COALESCE(output_tokens,0)),0) AS tokens,
                     COALESCE(SUM(COALESCE(actual_cost_usd, estimated_cost_usd, 0)),0) AS cost
              FROM sessions WHERE started_at >= ?},
            undef, $since
        );
        $out->{totals}{calls}  = 0 + ($tot->{calls} || 0);
        $out->{totals}{tokens} = 0 + ($tot->{tokens} || 0);
        $out->{totals}{cost}   = 0 + ($tot->{cost} || 0);

        my $sth = $dbh->prepare(
            q{SELECT date(started_at, 'unixepoch') AS day,
                     COUNT(*) AS calls,
                     COALESCE(SUM(COALESCE(input_tokens,0)+COALESCE(output_tokens,0)),0) AS tokens,
                     COALESCE(SUM(COALESCE(actual_cost_usd, estimated_cost_usd, 0)),0) AS cost
              FROM sessions WHERE started_at >= ?
              GROUP BY 1 ORDER BY 1}
        );
        $sth->execute($since);
        while (my $r = $sth->fetchrow_hashref) { push @{ $out->{by_day} }, $r }

        $sth = $dbh->prepare(
            q{SELECT COALESCE(billing_provider,'(none)') AS provider,
                     COALESCE(model,'unknown') AS model,
                     COUNT(*) AS calls,
                     COALESCE(SUM(COALESCE(input_tokens,0)+COALESCE(output_tokens,0)),0) AS tokens,
                     COALESCE(SUM(COALESCE(actual_cost_usd, estimated_cost_usd, 0)),0) AS cost
              FROM sessions WHERE started_at >= ?
              GROUP BY 1,2 ORDER BY calls DESC}
        );
        $sth->execute($since);
        while (my $r = $sth->fetchrow_hashref) { push @{ $out->{by_model} }, $r }

        $sth = $dbh->prepare(
            q{SELECT COALESCE(source,'unknown') AS request_type,
                     COUNT(*) AS calls,
                     COALESCE(SUM(COALESCE(input_tokens,0)+COALESCE(output_tokens,0)),0) AS tokens,
                     COALESCE(SUM(COALESCE(actual_cost_usd, estimated_cost_usd, 0)),0) AS cost
              FROM sessions WHERE started_at >= ?
              GROUP BY 1 ORDER BY calls DESC}
        );
        $sth->execute($since);
        while (my $r = $sth->fetchrow_hashref) { push @{ $out->{by_source} }, $r }

        $dbh->disconnect;
        $out->{ok} = 1;
        $out->{totals}{cost} = sprintf('%.4f', $out->{totals}{cost} || 0);
        for my $r (@{ $out->{by_day} }, @{ $out->{by_model} }, @{ $out->{by_source} }) {
            $r->{cost} = sprintf('%.4f', $r->{cost} || 0);
        }
    } catch {
        $out->{error} = "$_";
        $self->_log($c, 'warn', 'hermes_summary', "Hermes overlay failed: $_");
    };
    return $out;
}

sub _merge_org_totals {
    my ($self, $out) = @_;
    my $h = $out->{hermes}{totals} || {};
    $out->{org_totals} = {
        calls  => ($out->{totals}{calls}  || 0) + ($h->{calls}  || 0),
        tokens => ($out->{totals}{tokens} || 0) + ($h->{tokens} || 0),
        cost   => ($out->{totals}{cost}   || 0) + ($h->{cost}   || 0),
        app_calls    => $out->{totals}{calls} || 0,
        hermes_calls => $h->{calls} || 0,
    };
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

__PACKAGE__->meta->make_immutable;
1;
