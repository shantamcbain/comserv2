package Comserv::Util::AI::ModelHealth;

# ===================================================================
# Circuit breaker per provider+model for the AI2 Router failover
# (AISYSTEM plan §5e). State lives in a small JSON file under data/
# (data/ai_model_health.json) so it works before any table exists and
# survives restarts. Writes are atomic (temp file + rename) under an
# flock on "<file>.lock".
#
#   closed     normal; consecutive failures counted
#   open       skipped until cooldown_until (dead 404/410 or dead_model:
#              circuit_dead_cooldown_hours, else circuit_cooldown_minutes)
#   half_open  cooldown elapsed: exactly ONE probe call is let through
#              (probe_started_at); success closes, failure re-opens.
#
# With no path (no Catalyst context, e.g. unit tests of other modules)
# state is kept in memory only, so nothing outside the test is touched.
# ===================================================================

use strict;
use warnings;
use JSON ();
use Fcntl qw(:flock);
use File::Temp ();
use File::Basename qw(dirname);

use constant PROBE_TTL_S        => 180;    # a probe older than this is presumed lost
use constant ANOMALY_QUIET_S    => 86400;  # after a probe closes a circuit, ignore the 24h anomaly window
use constant DEAD_REASONS       => qw(http_404 http_410);
# Reasons that say "this hop is unavailable". Others (bad_request,
# postcheck_empty) still fail over but do not trip the breaker.
use constant CIRCUIT_REASONS    => qw(http_404 http_410 http_429 http_402 http_5xx timeout
                                      unreachable empty_output zero_tokens zero_tokens_empty auth credits);

sub new {
    my ($class, %a) = @_;
    return bless {
        path  => $a{path},
        now   => $a{now} || sub { time },
        mem   => { version => 1, models => {} },
    }, $class;
}

sub default_path {
    my ($class, $c) = @_;
    return $ENV{COMSERV_AI_HEALTH_FILE} if $ENV{COMSERV_AI_HEALTH_FILE};
    return eval { $c && $c->can('path_to') ? $c->path_to('data', 'ai_model_health.json') . '' : undef };
}

sub normalize_slug {
    my ($class, $provider, $model) = @_;
    $provider = lc($provider // '');
    $provider = 'openrouter' if $provider eq 'external';
    $model //= '';
    $model =~ s/^[^|]+\|//;
    return "$provider|$model";
}

sub _now { $_[0]{now}->() }

sub _read_file {
    my ($self) = @_;
    my $p = $self->{path};
    return { version => 1, models => {} } unless $p && -f $p;
    open my $fh, '<:raw', $p or return { version => 1, models => {} };
    my $raw = do { local $/; <$fh> };
    close $fh;
    my $d = eval { JSON->new->utf8->decode($raw) };
    $d = { version => 1, models => {} } unless ref $d eq 'HASH';
    $d->{models} = {} unless ref $d->{models} eq 'HASH';
    return $d;
}

sub _write_file {
    my ($self, $d) = @_;
    my $p = $self->{path};
    my $dir = dirname($p);
    my $tmp = File::Temp->new(DIR => $dir, TEMPLATE => '.ai_model_health_XXXXXX', UNLINK => 0);
    binmode $tmp, ':raw';
    print {$tmp} JSON->new->utf8->canonical->pretty->encode($d) or die "write failed: $!\n";
    close $tmp or die "close failed: $!\n";
    chmod 0644, $tmp->filename;
    unless (rename $tmp->filename, $p) { my $e = $!; unlink $tmp->filename; die "rename failed: $e\n" }
    return 1;
}

# _update(sub { my $state = shift; ...; return $ret }) — locked read-modify-write.
sub _update {
    my ($self, $fn) = @_;
    unless ($self->{path}) {
        return $fn->($self->{mem});
    }
    my $ret;
    open my $lk, '>>', "$self->{path}.lock" or return $fn->($self->_read_file);   # degrade: no persist
    flock($lk, LOCK_EX);
    my $d = $self->_read_file;
    $ret = $fn->($d);
    $d->{updated_at} = $self->_now;
    eval { $self->_write_file($d) };
    flock($lk, LOCK_UN);
    close $lk;
    return $ret;
}

sub state_all {
    my ($self) = @_;
    return $self->{path} ? $self->_read_file : $self->{mem};
}

sub _entry {
    my ($d, $slug) = @_;
    return $d->{models}{$slug} ||= { state => 'closed', consecutive_failures => 0,
                                     total_failures => 0, total_successes => 0 };
}

# check($slug) -> { allow, state, probe, cooldown_remaining_s, reason }
sub check {
    my ($self, $slug) = @_;
    my $now = $self->_now;
    my $peek = $self->state_all->{models}{$slug};
    return { allow => 1, state => 'closed', probe => 0 }
        unless $peek && ($peek->{state} // 'closed') ne 'closed';
    return $self->_update(sub {
        my ($d) = @_;
        my $e = _entry($d, $slug);
        my $st = $e->{state} // 'closed';
        if ($st eq 'open') {
            my $left = ($e->{cooldown_until} || 0) - $now;
            return { allow => 0, state => 'open', probe => 0, cooldown_remaining_s => $left,
                     reason => $e->{open_reason} } if $left > 0;
            $e->{state} = 'half_open';
            $e->{probe_started_at} = $now;
            return { allow => 1, state => 'half_open', probe => 1, reason => $e->{open_reason} };
        }
        if ($st eq 'half_open') {
            if (($e->{probe_started_at} || 0) > $now - PROBE_TTL_S) {
                return { allow => 0, state => 'half_open', probe => 0, reason => 'probe_in_flight',
                         cooldown_remaining_s => 0 };
            }
            $e->{probe_started_at} = $now;
            return { allow => 1, state => 'half_open', probe => 1, reason => $e->{open_reason} };
        }
        return { allow => 1, state => 'closed', probe => 0 };
    });
}

sub record_success {
    my ($self, $slug) = @_;
    my $now = $self->_now;
    return $self->_update(sub {
        my ($d) = @_;
        my $e = _entry($d, $slug);
        my $was = $e->{state} // 'closed';
        $e->{closed_by_probe_at} = $now if $was ne 'closed';
        $e->{state} = 'closed';
        $e->{consecutive_failures} = 0;
        $e->{last_success_at} = $now;
        $e->{total_successes}++;
        delete @$e{qw(probe_started_at cooldown_until opened_at)};
        return { state => 'closed', was => $was };
    });
}

sub _cooldown_s {
    my ($reason, $k) = @_;
    my $dead = grep { $_ eq ($reason // '') } (DEAD_REASONS, 'dead_model');
    return $dead ? int(($k->{circuit_dead_cooldown_hours} // 24) * 3600)
                 : int(($k->{circuit_cooldown_minutes}    // 15) * 60);
}

# record_failure($slug, $reason, %knobs) -> { state, opened => 0|1 }
sub record_failure {
    my ($self, $slug, $reason, %k) = @_;
    my $now = $self->_now;
    my $counts = grep { $_ eq ($reason // '') } CIRCUIT_REASONS;
    my $thr = $k{circuit_failure_threshold} || 3;
    return $self->_update(sub {
        my ($d) = @_;
        my $e = _entry($d, $slug);
        $e->{last_failure_reason} = $reason;
        $e->{last_failure_at} = $now;
        $e->{total_failures}++;
        return { state => $e->{state} // 'closed', opened => 0, counted => 0 } unless $counts;
        $e->{consecutive_failures}++;
        my $st = $e->{state} // 'closed';
        my $dead = grep { $_ eq $reason } DEAD_REASONS;
        if ($st eq 'half_open' || $e->{consecutive_failures} >= $thr || $dead) {
            $e->{state} = 'open';
            $e->{opened_at} = $now;
            $e->{open_reason} = $st eq 'half_open' ? "probe_failed:$reason"
                              : $dead ? $reason : "consecutive_failures:$reason";
            $e->{cooldown_until} = $now + _cooldown_s($reason, \%k);
            delete $e->{probe_started_at};
            return { state => 'open', opened => 1, counted => 1 };
        }
        return { state => $st, opened => 0, counted => 1 };
    });
}

# apply_anomalies(\@anomalies, %knobs): error_spike / dead_model from
# UsageMonitor::_anomalies open a CLOSED circuit, unless a probe closed it
# within the anomaly window (the 24h ledger window still holds the old
# failures — re-opening on them would never let the model back in) or the
# breaker saw a success more recently than the cooldown.
sub apply_anomalies {
    my ($self, $anoms, %k) = @_;
    my $now = $self->_now;
    my @hits = grep { ref $_ eq 'HASH' && ($_->{kind} // '') =~ /^(error_spike|dead_model)$/
                      && defined $_->{provider} && defined $_->{model}
                      && $_->{provider} ne 'router' } @{ $anoms || [] };
    return [] unless @hits;
    return $self->_update(sub {
        my ($d) = @_;
        my @opened;
        for my $a (@hits) {
            my $slug = __PACKAGE__->normalize_slug($a->{provider}, $a->{model});
            my $e = _entry($d, $slug);
            next unless ($e->{state} // 'closed') eq 'closed';
            next if ($e->{closed_by_probe_at} || 0) > $now - ANOMALY_QUIET_S;
            my $cool = _cooldown_s($a->{kind}, \%k);
            next if ($e->{last_success_at} || 0) > $now - $cool;
            $e->{state} = 'open';
            $e->{opened_at} = $now;
            $e->{open_reason} = $a->{kind};
            $e->{cooldown_until} = $now + $cool;
            push @opened, $slug;
        }
        return \@opened;
    });
}

# snapshot() -> [ { slug, state, open_reason, cooldown_remaining_s, ... } ] non-closed first
sub snapshot {
    my ($self) = @_;
    my $now = $self->_now;
    my $d = $self->state_all;
    my @rows;
    for my $slug (sort keys %{ $d->{models} || {} }) {
        my $e = $d->{models}{$slug};
        my $left = ($e->{state} // '') eq 'open' ? (($e->{cooldown_until} || 0) - $now) : 0;
        $left = 0 if $left < 0;
        push @rows, {
            slug => $slug, state => $e->{state} // 'closed',
            open_reason => $e->{open_reason}, last_failure_reason => $e->{last_failure_reason},
            consecutive_failures => $e->{consecutive_failures} || 0,
            cooldown_remaining_s => $left,
            cooldown_until => $e->{cooldown_until}, opened_at => $e->{opened_at},
            last_failure_at => $e->{last_failure_at}, last_success_at => $e->{last_success_at},
            total_failures => $e->{total_failures} || 0, total_successes => $e->{total_successes} || 0,
            # "ready for probe": open with the cooldown elapsed
            probe_due => (($e->{state} // '') eq 'open' && $left == 0) ? 1 : 0,
        };
    }
    return [ sort { ($a->{state} eq 'closed') <=> ($b->{state} eq 'closed') || $a->{slug} cmp $b->{slug} } @rows ];
}

1;

__END__

=head1 NAME

Comserv::Util::AI::ModelHealth - per provider+model circuit breaker (data/ai_model_health.json)

=head1 SYNOPSIS

    my $h = Comserv::Util::AI::ModelHealth->new(path => Comserv::Util::AI::ModelHealth->default_path($c));
    my $chk = $h->check('openrouter|google/gemma-4-26b-a4b-it:free');   # {allow, state, probe}
    $h->record_failure($slug, 'http_429', circuit_failure_threshold => 3, circuit_cooldown_minutes => 15);
    $h->record_success($slug);

=cut
