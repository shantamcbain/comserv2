package Comserv::Model::AI::Usage;
use Moose;
use namespace::autoclean -except => [qw(try catch finally)];  # keep Try::Tiny subs (Perl 5.40)
use Try::Tiny;
use JSON;
use DateTime;
use LWP::UserAgent;
use Comserv::Util::Logging;

has 'logging' => (
    is      => 'ro',
    lazy    => 1,
    default => sub { Comserv::Util::Logging->instance },
);

=head1 NAME

Comserv::Model::AI::Usage - AI usage logging, cost estimation, and plan quota integration

=head1 DESCRIPTION

Central place to record every AI call (local + paid providers) for:
- Billing / overage tracking
- Plan quota enforcement (free daily local calls)
- Capacity monitoring

This replaces the giant _log_ai_usage private method that used to live in AI.pm.

=cut

=head2 log

    $usage->log($c, %args);

Required/important args:
    user_id, site_id, provider, model, prompt_tokens, completion_tokens, total_tokens
    duration_ms, request_type, conversation_id, status, error_message, ollama_host
    metadata (hashref)

Optional:
    guest_session_id, estimated_cost_usd

This method also reads the current membership plan and writes:
    plan_id, plan_ai_requests_per_day, within_free_quota, billing_status

=cut

sub log {
    my ($self, $c, %args) = @_;

    eval {
        my $schema = $c->model('DBEncy')->schema;
        return unless $schema;

        my $user_id     = $args{user_id}     // $c->session->{user_id};
        my $site_id     = $args{site_id}     // $c->session->{SiteID};
        my $guest_id    = $args{guest_session_id} // $c->session->{guest_session_id};
        my $provider    = $args{provider}    // 'ollama';
        my $model       = $args{model}       // 'unknown';
        my $pt          = $args{prompt_tokens}     // 0;
        my $ct          = $args{completion_tokens} // 0;
        my $tot         = $args{total_tokens}      // ($pt + $ct);
        my $dur_ms      = $args{duration_ms};
        my $req_type    = $args{request_type} // 'chat';
        my $conv_id     = $args{conversation_id};
        my $status      = $args{status} // 'success';
        my $err_msg     = $args{error_message};
        my $ollama_host = $args{ollama_host};
        my $ip          = $c->request ? $c->request->address : undef;
        my $meta        = $args{metadata} || {};

        $pt  += 0; $ct += 0; $tot += 0;

        my $cost = $args{estimated_cost_usd};
        unless (defined $cost) {
            $cost = $self->_estimate_cost_usd($provider, $model, $pt, $ct);
        }

        # === Plan quota integration ===
        my $plan_id = undef;
        my $plan_quota = 0;
        my $within_free = 1;
        my $bill_status = 'free';

        eval {
            my $memb_model = $c->model('Membership');
            if ($memb_model && $site_id) {
                $plan_quota = $memb_model->get_ai_daily_quota_for_site($c, $site_id, $user_id) || 0;

                my $active_mem = $memb_model->get_active_plan($c, $user_id, $site_id);
                $plan_id = $active_mem ? $active_mem->id : undef;

                my ($is_within, $used_today) = $memb_model->is_ai_call_within_free_quota($c, $site_id, $provider, $user_id);
                $within_free = $is_within ? 1 : 0;

                my $is_paid_provider = $provider && lc($provider) ne 'ollama';
                if ($is_paid_provider) {
                    $bill_status = 'paid_provider';
                } elsif ($plan_quota > 0 && !$within_free) {
                    $bill_status = 'overage';
                } else {
                    $bill_status = 'free';
                }

                $meta->{plan_quota} = $plan_quota;
                $meta->{used_today_before_this} = $used_today;
                $meta->{within_free_quota} = $within_free;
            }
        };

        $schema->resultset('AiUsageLog')->create({
            user_id                  => $user_id,
            site_id                  => $site_id,
            guest_session_id         => $guest_id,
            provider                 => $provider,
            model                    => $model,
            prompt_tokens            => $pt,
            completion_tokens        => $ct,
            total_tokens             => $tot,
            estimated_cost_usd       => $cost,
            duration_ms              => $dur_ms,
            request_type             => $req_type,
            conversation_id          => $conv_id,
            status                   => $status,
            error_message            => $err_msg,
            ip_address               => $ip,
            ollama_host              => $ollama_host,
            plan_id                  => $plan_id,
            plan_ai_requests_per_day => $plan_quota,
            within_free_quota        => $within_free,
            billing_status           => $bill_status,
            metadata                 => (ref($meta) ? encode_json($meta) : $meta),
        });

        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'log',
            sprintf("Logged AI usage: provider=%s model=%s tokens=%s/%s cost=%.6f site=%s user=%s status=%s",
                $provider, $model, $pt, $ct, $cost, $site_id//'-', $user_id//'-', $status));
    };
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'log',
            "Failed to write ai_usage_logs: $@");
    }
}

=head2 _estimate_cost_usd (internal)

Very rough per-token cost estimates. Used only when provider does not return usage.

=cut

sub _estimate_cost_usd {
    my ($self, $provider, $model, $prompt_tokens, $completion_tokens) = @_;

    $provider  ||= '';
    $model     ||= '';

    # Very rough pricing (2026 estimates) - update as needed
    my %pricing = (
        'grok' => {
            default => { prompt => 0.000002, completion => 0.000006 },
            'grok-4' => { prompt => 0.000002, completion => 0.000006 },
            'grok-4.6' => { prompt => 0.000002, completion => 0.000006 },
        },
        'supergrok' => {
            default => { prompt => 0.000002, completion => 0.000006 },
            'grok-4.6' => { prompt => 0.000002, completion => 0.000006 },
        },
        'openrouter' => {
            default => { prompt => 0.0000005, completion => 0.0000015 },
        },
        'openai' => {
            'gpt-4o' => { prompt => 0.000005, completion => 0.000015 },
            default  => { prompt => 0.000002, completion => 0.000002 },
        },
    );

    my $p = lc($provider);
    my $m = lc($model);

    my $rates = $pricing{$p} && $pricing{$p}{$m} ? $pricing{$p}{$m} : $pricing{$p}{default};
    $rates ||= { prompt => 0, completion => 0 };

    my $cost = ($prompt_tokens * $rates->{prompt}) + ($completion_tokens * $rates->{completion});
    return sprintf("%.6f", $cost);
}

sub _load_config {
    my ($self, $c) = @_;
    my $path;
    eval { $path = $c->path_to('root', 'config', 'ai_usage.json') if $c && $c->can('path_to') };
    $path ||= 'root/config/ai_usage.json';
    my $cfg = {
        alert_percent                 => 80,
        supergrok_monthly_limit_usd   => 30,
        supergrok_monthly_request_limit => 400,
    };
    if ($path && -e $path && open my $fh, '<', $path) {
        my $raw = do { local $/; <$fh> };
        close $fh;
        my $parsed = eval { decode_json($raw) };
        if (ref($parsed) eq 'HASH') {
            $cfg->{$_} = $parsed->{$_} for keys %$parsed;
        }
    }
    return $cfg;
}

# Daily rollup from ai_usage_logs — which models ran and what they cost.
sub daily_model_summary {
    my ($self, $c, $days) = @_;
    $days = 14 unless $days && $days =~ /^\d+$/;
    my @rows;
    eval {
        my $schema = $c->model('DBEncy')->schema or return;
        my $since = DateTime->now->subtract(days => $days)->ymd . ' 00:00:00';
        my $rs = $schema->resultset('AiUsageLog')->search({
            created_at    => { '>=' => $since },
            request_type  => { -not_in => [qw(grok_balance_check provider_snapshot)] },
        }, { order_by => { -desc => 'created_at' }, rows => 2000 });
        my %by;
        while (my $log = $rs->next) {
            my $day = '';
            if (my $ts = $log->created_at) {
                $day = $ts->can('ymd') ? $ts->ymd : substr("$ts", 0, 10);
            }
            my $prov = $log->provider || 'unknown';
            my $mod  = $log->model || 'unknown';
            next if $mod eq '_api_snapshot' || $mod eq 'xai-usage-check';
            my $k = "$day\t$prov\t$mod";
            $by{$k}{day}      = $day;
            $by{$k}{provider} = $prov;
            $by{$k}{model}    = $mod;
            $by{$k}{calls}   += 1;
            $by{$k}{ok}      += (($log->status || '') eq 'success') ? 1 : 0;
            $by{$k}{tokens}  += $log->total_tokens || 0;
            $by{$k}{cost}    += $log->estimated_cost_usd || 0;
        }
        @rows = sort { $b->{day} cmp $a->{day} || $a->{provider} cmp $b->{provider} || $a->{model} cmp $b->{model} }
                values %by;
        for my $r (@rows) {
            $r->{cost} = sprintf('%.4f', $r->{cost} || 0);
            $r->{cost_per_ok} = ($r->{ok} && $r->{ok} > 0)
                ? sprintf('%.5f', ($r->{cost} || 0) / $r->{ok})
                : '0.00000';
        }
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'daily_model_summary',
            "Failed to build daily model summary: $@");
    }
    return \@rows;
}

sub fetch_openrouter_status {
    my ($self, $c) = @_;
    my $out = { provider => 'openrouter', source => 'openrouter_auth_key', ok => 0 };
    my $key;
    eval {
        my $prov = $c->model('AI2::Provider::OpenRouter');
        $key = $prov->_resolve_api_key($c) if $prov && $prov->can('_resolve_api_key');
    };
    unless ($key) {
        $out->{error} = 'No OpenRouter API key';
        return $out;
    }
    my $ua = LWP::UserAgent->new(timeout => 10);
    my $res = eval {
        $ua->get('https://openrouter.ai/api/v1/auth/key',
            Authorization => "Bearer $key",
            Accept        => 'application/json',
        );
    };
    if ($@ || !$res) {
        $out->{error} = "OpenRouter request failed: $@";
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'fetch_openrouter_status', $out->{error});
        return $out;
    }
    $out->{http_status} = $res->code;
    unless ($res->is_success) {
        $out->{error} = 'OpenRouter returned ' . $res->status_line;
        return $out;
    }
    my $data = eval { decode_json($res->decoded_content) } || {};
    my $d = $data->{data} || $data;
    $out->{ok}          = 1;
    $out->{usage}       = 0 + ($d->{usage} // 0);
    $out->{limit}       = defined $d->{limit} ? 0 + $d->{limit} : undef;
    $out->{remaining}   = defined $d->{limit_remaining} ? 0 + $d->{limit_remaining} : undef;
    $out->{is_free_tier}= $d->{is_free_tier} ? 1 : 0;
    $out->{auto_fill}   = 0;
    if ($out->{limit} && $out->{limit} > 0) {
        $out->{pct} = sprintf('%.1f', 100 * $out->{usage} / $out->{limit});
    }
    $out->{exhausted} = (defined $out->{remaining} && $out->{remaining} <= 0) ? 1 : 0;
    return $out;
}

sub supergrok_month_status {
    my ($self, $c) = @_;
    my $cfg = $self->_load_config($c);
    my $out = {
        provider      => 'supergrok',
        source        => 'internal_logs+allowance',
        ok            => 0,
        limit_usd     => 0 + ($cfg->{supergrok_monthly_limit_usd} || 30),
        limit_calls   => 0 + ($cfg->{supergrok_monthly_request_limit} || 400),
        alert_percent => 0 + ($cfg->{alert_percent} || 80),
        spend_usd     => 0,
        calls         => 0,
    };
    eval {
        my $schema = $c->model('DBEncy')->schema or return;
        my $start = DateTime->now->truncate(to => 'month')->ymd . ' 00:00:00';
        # SuperGrok only — never mix xAI grok (auto-fill pay-per-token) into this meter.
        my $rs = $schema->resultset('AiUsageLog')->search({
            provider     => 'supergrok',
            created_at   => { '>=' => $start },
            request_type => { -not_in => [qw(grok_balance_check provider_snapshot)] },
            status       => 'success',
        });
        while (my $row = $rs->next) {
            next if ($row->model || '') =~ /^(xai-usage-check|_api_snapshot)$/;
            $out->{calls}     += 1;
            $out->{spend_usd} += $row->estimated_cost_usd || 0;
            $out->{tokens}    += $row->total_tokens || 0;
        }
        $out->{ok} = 1;
    };
    if ($@) {
        $out->{error} = "$@";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'supergrok_month_status',
            "Failed SuperGrok month rollup: $@");
    }
    $out->{spend_usd} = sprintf('%.4f', $out->{spend_usd} || 0);
    my $pct_usd   = $out->{limit_usd}   > 0 ? 100 * $out->{spend_usd} / $out->{limit_usd} : 0;
    my $pct_calls = $out->{limit_calls} > 0 ? 100 * $out->{calls} / $out->{limit_calls} : 0;
    $out->{pct} = sprintf('%.1f', $pct_usd > $pct_calls ? $pct_usd : $pct_calls);
    $out->{over_threshold} = ($out->{pct} + 0) >= $out->{alert_percent} ? 1 : 0;
    $out->{source} = 'internal_logs_only';
    $out->{live_quota} = 0;
    $out->{quota_note} = 'xAI does not publish SuperGrok remaining %. grok.com Settings → Usage is the 43% bar. Numbers below are only our logged SuperGrok chat turns.';
    return $out;
}

# xAI pay-per-token (provider grok) — auto-fill is ON. Informational only.
sub grok_month_status {
    my ($self, $c) = @_;
    my $out = {
        provider    => 'grok',
        source      => 'internal_logs',
        ok          => 0,
        auto_fill   => 1,
        spend_usd   => 0,
        calls       => 0,
        tokens      => 0,
    };
    eval {
        my $schema = $c->model('DBEncy')->schema or return;
        my $start = DateTime->now->truncate(to => 'month')->ymd . ' 00:00:00';
        my $rs = $schema->resultset('AiUsageLog')->search({
            provider     => 'grok',
            created_at   => { '>=' => $start },
            request_type => { -not_in => [qw(grok_balance_check provider_snapshot)] },
            status       => 'success',
        });
        while (my $row = $rs->next) {
            next if ($row->model || '') =~ /^(xai-usage-check|_api_snapshot|_alert_)/;
            $out->{calls}     += 1;
            $out->{spend_usd} += $row->estimated_cost_usd || 0;
            $out->{tokens}    += $row->total_tokens || 0;
        }
        $out->{ok} = 1;
    };
    if ($@) {
        $out->{error} = "$@";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'grok_month_status',
            "Failed xAI grok month rollup: $@");
    }
    $out->{spend_usd} = sprintf('%.4f', $out->{spend_usd} || 0);
    return $out;
}

# Fire a system-error audit when SuperGrok hits 80% — once per calendar day.
sub maybe_alert_supergrok {
    my ($self, $c, $status) = @_;
    $status ||= $self->supergrok_month_status($c);
    return $status unless $status->{over_threshold};

    my $already = 0;
    eval {
        my $schema = $c->model('DBEncy')->schema or return;
        my $today  = DateTime->now->ymd . ' 00:00:00';
        $already = $schema->resultset('AiUsageLog')->search({
            provider     => 'supergrok',
            model        => '_alert_supergrok',
            request_type => 'provider_snapshot',
            created_at   => { '>=' => $today },
        })->count;
    };
    if ($already) {
        $status->{alerted_today} = 1;
        return $status;
    }

    my $msg = sprintf(
        '[Error] SuperGrok usage at %s%% of monthly allowance (\$%s / \$%s, %s requests). Review /ai/usage',
        $status->{pct}, $status->{spend_usd}, $status->{limit_usd}, $status->{calls}
    );
    $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'maybe_alert_supergrok', $msg);
    eval {
        $self->log($c,
            provider          => 'supergrok',
            model             => '_alert_supergrok',
            request_type      => 'provider_snapshot',
            prompt_tokens     => 0,
            completion_tokens => 0,
            total_tokens      => 0,
            estimated_cost_usd=> $status->{spend_usd},
            status            => 'success',
            metadata          => { pct => $status->{pct}, alert => 1 },
        );
    };
    $status->{alerted_now} = 1;
    $status->{alert_msg}   = $msg;
    return $status;
}

sub snapshot_provider_status {
    my ($self, $c) = @_;
    my $or = $self->fetch_openrouter_status($c);
    my $sg = $self->maybe_alert_supergrok($c);
    my $xk = $self->grok_month_status($c);
    eval {
        if ($or->{ok}) {
            $self->log($c,
                provider          => 'openrouter',
                model             => '_api_snapshot',
                request_type      => 'provider_snapshot',
                estimated_cost_usd=> $or->{usage} || 0,
                prompt_tokens     => 0,
                completion_tokens => 0,
                total_tokens      => 0,
                status            => 'success',
                metadata          => { limit => $or->{limit}, remaining => $or->{remaining}, pct => $or->{pct} },
            );
        }
    };
    return { openrouter => $or, supergrok => $sg, grok => $xk };
}

1;

__PACKAGE__->meta->make_immutable;

__END__

=head1 USAGE (from thin controller or other models)

    $c->model('AI')->usage->log($c,
        provider => 'grok',
        model    => 'grok-4-fast-reasoning',
        prompt_tokens => 120,
        completion_tokens => 340,
        ...
    );

Or via facade helper:

    $c->model('AI')->log_usage($c, %args);

=cut