package Comserv::Model::AI::Usage;
use Moose;
use namespace::autoclean;
use Try::Tiny;
# Perl 5.40: namespace::autoclean strips imported try/catch; re-import after
# its BEGIN so the Try::Tiny idiom keeps working (perl-try-tiny-autoclean-debug).
INIT { Try::Tiny->import }
use JSON;
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