package Comserv::Util::AI::GuardAutoMove;

# GuardAutoMove (2026-11-18, todo #2759).
#
# WHAT: the "move the session, don't just alert" half of the Hermes overrun
# guard. HermesOverrunGuard (cron, every minute) already finds sessions whose
# live model is not allowed (session_offenders -> offender_reason) and blocks
# their tool calls, but it only alerted: on Nov 18 session beab3515 fell back
# to openrouter particle-ai/particle-1, the OpenRouter cap was hit, the gate
# blocked it at 09:27 and the session stayed stuck for the rest of the day.
# Also, when the cap is hit, the trip/switch target can itself be the paid
# particle-1 that the gate blocks.
#
# WHY a separate module: the guard file is 2600+ lines of plain Perl and is
# loaded by cron. This module holds the new decision + write logic so the big
# file only needs a few call lines:
#   * enforce_move  - pick the first allowed chain model and write a new
#                     guard_model_switch record (generation bump) so Hermes
#                     adopts it at the next prompt.
#   * safe_trip_target - when the trip reason is an OpenRouter cap, replace a
#                     target the gate would block with an allowed alternative.
#
# HermesOverrunGuard loads THIS module (never the other way round), so the
# guard's subs are called by full package name at run time.

use strict;
use warnings;

our $FORBIDDEN_RE = qr/grok-build|glm|relace/i;
our $COOLDOWN_S   = 1800;

# Owner package. Called by full name at run time (no `use` - it loads us).
my $H = 'Comserv::Util::AI::HermesOverrunGuard';

# ---------------------------------------------------------------------------
# forbidden_target($candidate) -> reason string, or undef when the candidate is
# a legal switch target at all (before any cap/trial policy is applied).
# ---------------------------------------------------------------------------
sub forbidden_target {
    my ($class, $c) = @_;
    return 'no model' unless ref $c eq 'HASH' && length($c->{default} // '');
    my $p = $c->{provider} // '';
    my $m = $c->{default};
    my $n = $c->{name} // '';
    return 'grok-build, glm and Relace are never used' if "$p $m $n" =~ $FORBIDDEN_RE;
    return 'OpenRouter grok is blocked' if $p eq 'openrouter' && $m =~ m{grok|^~?x-ai/}i;
    require Comserv::Model::AI2::ModelPick;
    return 'vision-only or under 7B' if Comserv::Model::AI2::ModelPick->is_weak_for_coding($m);
    return undef;
}

# is_supergrok($candidate) -> 1 when the candidate spends the Super Grok quota.
sub is_supergrok {
    my ($class, $c) = @_;
    return 0 unless ref $c eq 'HASH';
    return ($c->{supergrok} || $c->{sg_budget}
        || ($c->{provider} // '') =~ /^(?:xai-oauth|supergrok)\z/) ? 1 : 0;
}

# ---------------------------------------------------------------------------
# first_allowed(candidates => [...], reason_cb => sub { ($provider, $model) ->
#   reason|undef }, sg_ok => 0|1, skip => { model => 1 })
# Positional form is also accepted: first_allowed($cands, $cb, $sg_ok, skip => {...}).
# Returns a shallow copy of the first candidate that is a hash with a default,
# not in skip, not forbidden, not Super Grok without budget, and allowed by
# reason_cb. Else undef.
# ---------------------------------------------------------------------------
sub first_allowed {
    my ($class, @a) = @_;
    my ($cands, $cb, $sg_ok, %opt);
    if (@a && !ref $a[0] && $a[0] =~ /^(?:candidates|reason_cb|sg_ok|skip)\z/) {
        %opt   = @a;
        $cands = $opt{candidates};
        $cb    = $opt{reason_cb};
        $sg_ok = $opt{sg_ok};
    }
    else {
        ($cands, $cb, $sg_ok, %opt) = @a;
    }
    my $skip = ref $opt{skip} eq 'HASH' ? $opt{skip} : {};
    for my $c (@{ $cands || [] }) {
        next unless ref $c eq 'HASH';
        my $m = $c->{default};
        next unless defined $m && length $m;
        next if $skip->{$m};
        next if defined $class->forbidden_target($c);
        next if $class->is_supergrok($c) && !$sg_ok;
        next if $cb && defined $cb->($c->{provider}, $m);
        return { %$c };
    }
    return undef;
}

# ---------------------------------------------------------------------------
# move_plan(offenders => [ {session, provider, model, reason} ], candidates,
#           reason_cb, sg_ok, last => {key, at}, now, cooldown) -> plan|undef
# One plan per distinct offender set per cooldown window, so a stuck session is
# moved once and not rewritten on every cron tick.
# ---------------------------------------------------------------------------
sub move_plan {
    my ($class, %a) = @_;
    my $offs = $a{offenders};
    return undef unless ref $offs eq 'ARRAY' && @$offs;

    my $now = defined $a{now} ? $a{now} : time;
    my $key = join(',', sort map {
        ($_->{session} // '?') . ':' . ($_->{provider} // '') . '/' . ($_->{model} // '')
    } @$offs);

    my $last = $a{last};
    my $cool = defined $a{cooldown} ? $a{cooldown} : $COOLDOWN_S;
    if (ref $last eq 'HASH' && ($last->{key} // '') eq $key
        && defined $last->{at} && ($now - $last->{at}) < $cool) {
        return undef;
    }

    my $top = $offs->[0];
    my %skip = map { ($_->{model} // '') => 1 } @$offs;
    my $target = $class->first_allowed($a{candidates}, $a{reason_cb}, $a{sg_ok}, skip => \%skip);

    return {
        key     => $key,
        target  => $target,
        none    => ($target ? 0 : 1),
        from    => ($top->{provider} // '') . '/' . ($top->{model} // ''),
        session => $top->{session},
        reason  => $top->{reason},
    };
}

# ---------------------------------------------------------------------------
# safe_switch_target(target => {...}, or_over => 0|1, candidates, reason_cb, sg_ok)
# When the OpenRouter cap is hit, a switch target the gate would block is
# replaced by the first allowed alternative (the Nov 18 particle-1 case).
# ---------------------------------------------------------------------------
sub safe_switch_target {
    my ($class, %a) = @_;
    my $t = $a{target};
    return $t unless $t;
    return $t unless $a{or_over};
    my $cb = $a{reason_cb};
    return $t unless $cb && defined $cb->($t->{provider}, $t->{default});
    my $alt = $class->first_allowed($a{candidates}, $cb, $a{sg_ok});
    return $alt ? { %$alt, replaced => $t->{default} } : $t;
}

# ---------------------------------------------------------------------------
# Glue to HermesOverrunGuard (by full name; it loads this module).
# ---------------------------------------------------------------------------
sub _cands {
    my ($class, %in) = @_;
    return [ Comserv::Util::AI::HermesOverrunGuard::chain_candidates(
        chain     => $in{chain} || [],
        emergency => $in{emergency} || [],
        ($in{candidates} ? (candidates => $in{candidates}) : ()),
    ) ];
}

# ---------------------------------------------------------------------------
# enforce_move($s, state => $st, offenders => $offs, ctx => \%ctx, pol => \%pol,
#              now => $t) -> plan hash or undef
# Moves the offending sessions by writing a new guard_model_switch record; the
# generation bump makes Hermes adopt it at the next prompt.
# ---------------------------------------------------------------------------
sub enforce_move {
    my ($class, $s, %a) = @_;
    my $ctx = $a{ctx} || {};
    my %pol = %{ $a{pol} || {} };
    my $st  = $a{state} || {};
    my $now = defined $a{now} ? $a{now} : time;

    my $plan = $class->move_plan(
        offenders  => $a{offenders},
        candidates => $class->_cands(%$ctx),
        reason_cb  => sub {
            Comserv::Util::AI::HermesOverrunGuard::offender_reason($_[0], $_[1], %pol)
        },
        sg_ok      => (Comserv::Util::AI::HermesOverrunGuard::supergrok_budget_left($ctx->{supergrok}) ? 1 : 0),
        last       => $st->{enforce_move},
        now        => $now,
    ) or return undef;

    if (!$plan->{target}) {
        $st->{enforce_move} = { key => $plan->{key}, at => $now, none => 1 };
        $s->log_line("ENFORCE_MOVE none: no allowed chain model for $plan->{from} ($plan->{reason})");
        return $plan;
    }

    my $t = $plan->{target};
    (my $short = $t->{default}) =~ s{.*/}{};
    my $rec = $s->write_guard_model_switch(
        reason => 'enforce_move',
        at     => $now,
        from   => $plan->{from},
        model  => { map { ($_ => $t->{$_}) } grep { defined $t->{$_} } qw(default provider base_url api_mode) },
        notice => "Overrun guard moved this session to $short: $plan->{reason}",
    );
    my $gen = ref $rec eq 'HASH' ? $rec->{generation} : undef;
    $st->{enforce_move} = {
        key        => $plan->{key},
        at         => $now,
        generation => $gen,
        to         => "$t->{provider}/$t->{default}",
    };
    $s->log_line(sprintf('ENFORCE_MOVE %s -> %s/%s (generation %s): %s',
        $plan->{from}, $t->{provider}, $t->{default}, $gen // '?', $plan->{reason}));
    return { %$plan, generation => $gen };
}

# ---------------------------------------------------------------------------
# safe_trip_target($target, %in) for build_trip_plan. %in carries reasons,
# allowed_paid, trial_active, trial_stopped, chain, emergency, candidates,
# supergrok. Only acts when the trip reason is an OpenRouter cap.
# ---------------------------------------------------------------------------
sub safe_trip_target {
    my ($class, $target, %in) = @_;
    my $or_over = (grep { /^OpenRouter .* over / } @{ $in{reasons} || [] }) ? 1 : 0;
    return $target unless $target && $or_over;

    my %pol = (
        or_over       => 1,
        allowed_paid  => $in{allowed_paid}  || {},
        trial_active  => $in{trial_active}  || {},
        trial_stopped => $in{trial_stopped} || {},
    );
    return $class->safe_switch_target(
        target     => $target,
        or_over    => 1,
        candidates => $class->_cands(%in),
        reason_cb  => sub {
            Comserv::Util::AI::HermesOverrunGuard::offender_reason($_[0], $_[1], %pol)
        },
        sg_ok      => (Comserv::Util::AI::HermesOverrunGuard::supergrok_budget_left($in{supergrok}) ? 1 : 0),
    );
}

1;

__END__

=head1 NAME

Comserv::Util::AI::GuardAutoMove - move disallowed Hermes sessions onto an
allowed chain model, and keep trip/switch targets inside the gate

=head1 SYNOPSIS

  require Comserv::Util::AI::GuardAutoMove;

  # every minute, after session_offenders() has found blocked sessions
  my $plan = Comserv::Util::AI::GuardAutoMove->enforce_move(
      $guard,
      state     => $state,          # overrun guard state hash (persisted)
      offenders => $offenders,      # from HermesOverrunGuard::session_offenders
      ctx       => \%ctx,           # chain, emergency, candidates, supergrok
      pol       => \%policy,        # tripped, or_over, allowed_paid, trials...
      now       => time,
  );

  # inside build_trip_plan, so a cap trip never targets a blocked model
  my $target = Comserv::Util::AI::GuardAutoMove->safe_trip_target($target,
      reasons => $reasons, chain => $chain, emergency => $emergency,
      supergrok => $sg, allowed_paid => \%allowed_paid);

=head1 DESCRIPTION

Pure decision subs plus two glue subs. All decisions are class methods called
as C<< Comserv::Util::AI::GuardAutoMove->name(...) >>; HermesOverrunGuard's subs
are called by full package name at run time because that module loads this one.

=cut
