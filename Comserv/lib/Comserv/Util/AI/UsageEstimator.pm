package Comserv::Util::AI::UsageEstimator;

# One usage estimator for every AI consumer (Oct 3 2026): Grok Bot, Super Grok,
# OpenRouter (Hermes, app, AI editor) and Ollama.
#  - app-side estimate from the Ledger (AiUsageLog via DBIx::Class, gathered in
#    Model::AI2::UsageMonitor::usage_estimator) + Hermes state.db call counts;
#  - normalized against backups: manual readings (admin form on /ai/usage,
#    data/ai_usage_readings.jsonl) and the grok.com add-on / OpenRouter API;
#  - per consumer: estimate vs latest reading, drift, reset, burn, projection.
# Readings are stored as spoken: no refund logic, conflicts are flagged only.

use strict;
use warnings;
use JSON::PP ();
use POSIX qw(strftime);
use Time::Local qw(timelocal);

our @CONSUMERS = (
    { id => 'grok_bot',   label => 'Grok Bot',   unit => '%', cycle_days => 7 },
    { id => 'supergrok',  label => 'Super Grok', unit => '%', cycle_days => 7 },
    { id => 'openrouter', label => 'OpenRouter (Hermes, app, AI editor)', unit => '$', cycle_days => 7, cap => 11.50 },
    { id => 'ollama',     label => 'Ollama (local)', unit => 'calls', cycle_days => 7 },
);
our %CONSUMER = map { ($_->{id} => $_) } @CONSUMERS;
our @KINDS   = qw(used left unconfirmed);
our @SOURCES = qw(manual addon api spoken screenshot other);

my $J = JSON::PP->new->canonical->utf8;

sub readings_file { my ($root) = @_; ($root // '.') . '/data/ai_usage_readings.jsonl' }

sub pt {
    my ($e) = @_;
    return '' unless defined $e && $e > 0;
    local $ENV{TZ} = 'America/Los_Angeles'; POSIX::tzset();
    my $s = strftime('%a %b %d %H:%M PT', localtime $e);
    return $s;
}

# "2026-10-03 08:07" / "2026-10-03T08:07" (PT) / epoch / ISO with offset -> epoch
sub parse_time {
    my ($s, $now) = @_;
    return $now // time unless defined $s && length $s;
    return 0 + $s if $s =~ /^\d{9,11}$/;
    if ($s =~ /^(\d{4})-(\d\d)-(\d\d)[ T](\d\d):(\d\d)(?::(\d\d))?(?:\.\d+)?\s*(Z|[+-]\d\d:?\d\d)?$/) {
        my ($Y, $M, $D, $h, $m, $sec, $tz) = ($1, $2, $3, $4, $5, $6 // 0, $7);
        if (defined $tz) {
            require Time::Local;
            my $e = Time::Local::timegm($sec, $m, $h, $D, $M - 1, $Y);
            if ($tz ne 'Z') { my ($sg, $oh, $om) = $tz =~ /([+-])(\d\d):?(\d\d)/; $e -= ($sg eq '-' ? -1 : 1) * ($oh * 3600 + $om * 60) }
            return $e;
        }
        local $ENV{TZ} = 'America/Los_Angeles'; POSIX::tzset();
        return timelocal($sec, $m, $h, $D, $M - 1, $Y);
    }
    return undef;
}

# Validate + normalise a reading. Returns (reading, undef) or (undef, error).
sub make_reading {
    my (%r) = @_;
    my $now = delete $r{now} // time;
    my $c = $CONSUMER{ $r{consumer} // '' } or return (undef, 'unknown consumer');
    my $v = $r{value} // '';
    $v =~ s/^\s+|\s+$//g; $v =~ s/[%\$]//g;
    return (undef, 'value must be a number') unless $v =~ /^\d+(?:\.\d+)?$/;
    my $kind = $r{kind} // 'used';
    return (undef, 'kind must be used, left or unconfirmed') unless grep { $_ eq $kind } @KINDS;
    my $at = parse_time($r{at}, $now);
    return (undef, 'timestamp not understood (use YYYY-MM-DD HH:MM PT)') unless defined $at;
    return (undef, 'timestamp is in the future') if $at > $now + 300;
    my $src = $r{source} // 'manual';
    $src = 'other' unless grep { $_ eq $src } @SOURCES;
    my $reset = (defined $r{reset_at} && length $r{reset_at}) ? parse_time($r{reset_at}, $now) : undef;
    if (!defined $reset && defined $r{reset_in_hours} && $r{reset_in_hours} =~ /^\d+(?:\.\d+)?$/) {
        $reset = $at + int($r{reset_in_hours} * 3600);
    }
    return ({
        consumer => $c->{id}, value => 0 + $v, unit => $r{unit} // $c->{unit}, kind => $kind,
        at => $at, at_pt => pt($at), source => $src,
        (defined $reset ? (reset_at => $reset, reset_pt => pt($reset)) : ()),
        (defined $r{note} && length $r{note} ? (note => substr($r{note}, 0, 300)) : ()),
        (defined $r{entered_by} ? (entered_by => $r{entered_by}) : ()),
        entered_at => $now,
    }, undef);
}

sub append_reading {
    my ($root, $rd) = @_;
    my $f = readings_file($root);
    open my $fh, '>>', $f or return "cannot write $f: $!";
    print $fh $J->encode($rd), "\n";
    close $fh;
    return undef;
}

sub read_readings {
    my ($root) = @_;
    open my $fh, '<', readings_file($root) or return [];
    my @r = grep { ref $_ eq 'HASH' && $_->{consumer} } map { eval { $J->decode($_) } } grep { /\S/ } <$fh>;
    close $fh;
    return [ sort { $a->{at} <=> $b->{at} || ($a->{entered_at} // 0) <=> ($b->{entered_at} // 0) } @r ];
}

# Used value of a reading (as spoken; 'left' converted against 100 % or the cap).
sub used_of {
    my ($rd, $cap) = @_;
    return undef unless $rd;
    return $rd->{value} unless $rd->{kind} eq 'left';
    my $full = $rd->{unit} eq '%' ? 100 : $cap;
    return defined $full ? $full - $rd->{value} : undef;
}

# Conflict flags: a later 'used' reading below an earlier one in the same cycle
# (no reset between). Flag only - nothing is adjusted or refunded.
sub conflicts {
    my ($readings, %o) = @_;
    my @out;
    my @r = grep { $_->{kind} ne 'unconfirmed' } @$readings;
    for my $i (1 .. $#r) {
        my ($p, $q) = ($r[$i - 1], $r[$i]);
        my ($pu, $qu) = (used_of($p, $o{cap}), used_of($q, $o{cap}));
        next unless defined $pu && defined $qu && $qu < $pu;
        my $reset_between = 0;
        for my $rs (grep { defined } $p->{reset_at}, $o{reset_at}) {
            my $x = $rs; my $cd = ($o{cycle_days} || 7) * 86400;
            $x -= $cd while $x > $q->{at};
            $reset_between = 1 if $x > $p->{at} && $x <= $q->{at};
        }
        next if $reset_between;
        push @out, sprintf('%s%s used at %s, then %s%s used at %s with no reset in between - conflict flagged, not adjusted',
            _fmt($pu, $p->{unit}), '', $p->{at_pt}, _fmt($qu, $q->{unit}), '', $q->{at_pt});
    }
    for my $q (grep { $_->{kind} eq 'unconfirmed' } @$readings) {
        push @out, sprintf('%s at %s: used/left unconfirmed (as used: %s used; as left: %s used)',
            _fmt($q->{value}, $q->{unit}), $q->{at_pt}, _fmt($q->{value}, $q->{unit}),
            ($q->{unit} eq '%' ? _fmt(100 - $q->{value}, '%') : '?'))
            if $q eq $readings->[-1];
    }
    return \@out;
}

sub _fmt {
    my ($v, $u) = @_;
    return '?' unless defined $v;
    return sprintf('$%.2f', $v) if ($u // '') eq '$';
    return sprintf('%.1f%%', $v) if ($u // '') eq '%';
    return sprintf('%.0f %s', $v, $u // '');
}

sub next_reset {
    my ($reset, $now, $cycle_days) = @_;
    return undef unless defined $reset;
    my $cd = ($cycle_days || 7) * 86400;
    $reset += $cd while $reset <= $now;
    return $reset;
}

# Pure per-consumer estimate.
# in: consumer, now, readings (this consumer, sorted), rate (unit per call;
#     undef for $/calls consumers where units are already in the unit),
#     units_since => coderef(epoch) -> units (calls or $) since epoch,
#     app_cycle => app-only estimate for the current cycle (unit),
#     app_at_reading => coderef(epoch) app-only estimate at that time,
#     burn_24h => units in last 24 h, reset_at, cap, live (authoritative reading hash).
sub estimate {
    my (%in) = @_;
    my $c   = $CONSUMER{ $in{consumer} } or die "unknown consumer";
    my $now = $in{now} // time;
    my @rd  = @{ $in{readings} || [] };
    my $latest = $rd[-1];
    my $rate = $in{rate} // 1;
    my $reset = next_reset($in{reset_at} // ($latest ? $latest->{reset_at} : undef), $now, $c->{cycle_days});
    my $cycle_start = defined $reset ? $reset - $c->{cycle_days} * 86400 : undef;
    my $lu = used_of($latest, $in{cap});
    my $latest_in_cycle = $latest && (!defined $cycle_start || $latest->{at} >= $cycle_start) ? 1 : 0;

    my $norm;
    if ($latest && defined $lu && $latest_in_cycle && $in{units_since}) {
        $norm = $lu + ($in{units_since}->($latest->{at}) // 0) * $rate;
    } elsif (defined $in{app_cycle}) {
        $norm = $in{app_cycle};
    }
    my $drift;
    if ($latest && defined $lu && $in{app_at_reading}) {
        my $a = $in{app_at_reading}->($latest->{at});
        $drift = $a - $lu if defined $a;
    }
    my $burn_h = defined $in{burn_24h} ? $in{burn_24h} * $rate / 24 : undef;
    my $hours_left = defined $reset ? ($reset - $now) / 3600 : undef;
    my $proj = (defined $norm && defined $burn_h && defined $hours_left) ? $norm + $burn_h * $hours_left : undef;
    my $limit = $c->{unit} eq '%' ? 100 : $in{cap};
    my $out = {
        consumer => $c->{id}, label => $c->{label}, unit => $c->{unit},
        estimate => $norm, estimate_fmt => _fmt($norm, $c->{unit}),
        app_only => $in{app_cycle}, app_only_fmt => _fmt($in{app_cycle}, $c->{unit}),
        latest => $latest, latest_used => $lu, latest_fmt => ($latest ? _fmt($latest->{value}, $latest->{unit}) . " $latest->{kind}" : ''),
        latest_in_cycle => $latest_in_cycle,
        drift => $drift, drift_fmt => (defined $drift ? ($drift >= 0 ? '+' : '-') . _fmt(abs $drift, $c->{unit}) : ''),
        reset_at => $reset, reset_pt => pt($reset),
        hours_to_reset => (defined $hours_left ? sprintf('%.1f', $hours_left) : undef),
        burn_per_hour => $burn_h, burn_fmt => (defined $burn_h ? _fmt($burn_h, $c->{unit}) . '/h' : ''),
        projection => $proj, projection_fmt => _fmt($proj, $c->{unit}),
        limit => $limit,
        over_at_reset => (defined $proj && defined $limit && $proj >= $limit) ? 1 : 0,
        conflicts => conflicts(\@rd, cap => $in{cap}, reset_at => $reset, cycle_days => $c->{cycle_days}),
        readings_count => scalar(@rd),
        notes => $in{notes} || [],
    };
    $out->{notes} = [ @{ $out->{notes} }, 'Latest reading is from before this cycle; using the app-only estimate' ]
        if $latest && !$latest_in_cycle;
    return $out;
}


# Unlogged-spend reconciliation (Oct 3): OpenRouter billed (API) vs what the
# Ledger (app) + Hermes state.db account for. Flags a gap over $threshold a
# day ("unlogged spend"). hermes_full = Hermes tokens priced with cache reads
# at full input price (upstreams like Relace bill them that way).
sub reconcile {
    my (%in) = @_;
    my $th  = $in{threshold} // 0.50;
    my $out = { threshold => $th, flag => 0 };
    for my $w (qw(day week)) {
        my $x = $in{$w} or next;
        next unless defined $x->{billed};
        my $app    = (($x->{app_audit} // 0) > ($x->{app_feature} // 0)) ? $x->{app_audit} : ($x->{app_feature} // 0);
        my $hermes = $x->{hermes_est} // 0;
        my $logged = $app + $hermes;
        my $gap    = $x->{billed} - $logged;
        my $days   = $w eq 'day' ? 1 : ($x->{days} || 7);
        my $limit  = $th * $days;
        my $r = { billed => $x->{billed}, app => $app, hermes_est => $hermes, logged => $logged, gap => $gap,
                  limit => $limit, hermes_full => $x->{hermes_full}, unlogged => ($gap > $limit ? 1 : 0) };
        if ($r->{unlogged}) {
            my $hidden = defined $x->{hermes_full} ? $x->{hermes_full} - $hermes : 0;
            $r->{likely} = ($hidden > 0 && $hidden >= 0.8 * $gap)
                ? sprintf('Hermes cache-read tokens billed at full input price: +$%.2f over Hermes\'s own estimate', $hidden)
                : 'Not explained by the Ledger or Hermes; check other apps or keys using this OpenRouter key';
            $r->{message} = sprintf('Unlogged spend: OpenRouter billed $%.2f this %s; Ledger + Hermes account for $%.2f (gap $%.2f > $%.2f)',
                $x->{billed}, $w, $logged, $gap, $limit);
            $out->{flag} = 1;
        }
        $out->{$w} = $r;
    }
    return $out;
}

# Price Hermes token sums: {model => {in, out, cache_read}} x prices {model => [prompt, completion, cache_read]} ($/token).
sub price_tokens {
    my ($rows, $prices, %o) = @_;
    my $t = 0;
    for my $m (keys %{ $rows || {} }) {
        (my $k = $m) =~ s{^openrouter/}{};
        my $p = $prices->{$k} or next;
        my $r = $rows->{$m};
        my $cr = $o{cache_full} ? $p->[0] : ($p->[2] // $p->[0]);
        $t += ($r->{in} // 0) * $p->[0] + ($r->{out} // 0) * $p->[1] + ($r->{cache_read} // 0) * $cr;
    }
    return $t;
}

1;
