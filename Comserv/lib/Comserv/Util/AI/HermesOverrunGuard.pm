package Comserv::Util::AI::HermesOverrunGuard;

# Hermes overrun guard (Oct 3 2026).
# Trips within minutes on Hermes thrash (>= 20 assistant calls / 15 min) or the
# OpenRouter day/week/month caps; drops Hermes to the cheapest working model
# (or pauses it), backs up ~/.hermes/config.yaml, writes notice/log/events and
# a Ledger row; auto-restores when every window is clear.
# Runs from script/hermes_overrun_guard.pl (cron */5) and the 5-minute health
# evaluator loop in script/comserv_server.pl. flock + min interval = idempotent.

use strict;
use warnings;
use JSON::PP ();
use HTTP::Tiny;
use Fcntl qw(:flock);
use POSIX qw(strftime);
use File::Copy ();

our %CAPS = (day => 1.65, week => 11.50, month => 50);
our $THRASH_N      = 20;
our $THRASH_WINDOW = 900;

# Cheapest first. 'health' = key in data/ai_model_health.json (circuit must not be open).
our @CANDIDATES = (
    { name => 'openrouter/cohere/north-mini-code:free', provider => 'openrouter',
      default => 'openrouter/cohere/north-mini-code:free', base_url => 'https://openrouter.ai/api/v1',
      api_mode => 'chat_completions', health => 'openrouter|cohere/north-mini-code:free', free => 1 },
    { name => 'openrouter/nvidia/nemotron-3.5-lightning:free', provider => 'openrouter',
      default => 'openrouter/nvidia/nemotron-3.5-lightning:free', base_url => 'https://openrouter.ai/api/v1',
      api_mode => 'chat_completions', health => 'openrouter|nvidia/nemotron-3.5-lightning:free', free => 1 },
    { name => 'ollama-launch/gemma4-64k:latest', provider => 'ollama-launch',
      default => 'gemma4-64k:latest', base_url => 'http://127.0.0.1:11434/v1',
      api_mode => 'chat_completions', ollama => 'gemma4-64k:latest', free => 1 },
);
our @MODEL_KEYS = qw(provider default base_url api_mode);

my $J = JSON::PP->new->canonical->utf8;

sub new {
    my ($class, %a) = @_;
    my $home = $a{home} // $ENV{HOME} // '/home/shanta';
    my $hh   = "$home/.hermes";
    my $self = {
        hermes_home  => $hh,
        config       => "$hh/config.yaml",
        state_file   => "$hh/overrun_guard_state.json",
        notice_file  => "$hh/overrun_notice.txt",
        session_notice => "$hh/overrun_session_notice.json",
        events_file  => "$hh/overrun_guard_events.jsonl",
        log_file     => "$hh/logs/overrun_guard.log",
        lock_file    => "$hh/overrun_guard.lock",
        state_db     => "$hh/state.db",
        hermes_bin   => $a{hermes_bin} // "$home/.local/bin/hermes",
        app_root     => $a{app_root} // '.',
        base_urls    => $a{base_urls} // [ $ENV{COMSERV_GUARD_URL} // (), 'http://127.0.0.1:4006', 'http://127.0.0.1:3001' ],
        min_interval => $a{min_interval} // 240,
        ollama_url   => $a{ollama_url} // 'http://127.0.0.1:11434',
        dry_run      => $a{dry_run} // 0,
        now          => $a{now},
        %a,
    };
    return bless $self, $class;
}

sub _now { my $s = shift; defined $s->{now} ? $s->{now} : time }

sub pt { my $e = shift // time; local $ENV{TZ} = 'America/Los_Angeles'; POSIX::tzset(); strftime('%a %b %d %H:%M PT', localtime $e) }

# ---- pure decision ---------------------------------------------------------
# in: thrash (int|undef), openrouter {ok,day_usd,week_usd,month_usd}, state {tripped},
#     caps, thrash_n. out: {action => trip|hold|restore|none, reasons => [...], over, known}
sub decide {
    my (%in) = @_;
    my $caps = $in{caps} || \%CAPS;
    my $tn   = $in{thrash_n} // $THRASH_N;
    my $st   = $in{state} || {};
    my $or   = $in{openrouter} || {};
    my @r;
    my $known = 1;
    if (defined $in{thrash}) {
        push @r, "thrash: $in{thrash} Hermes calls in 15 min (limit $tn)" if $in{thrash} >= $tn;
    } else { $known = 0 }
    if ($or->{ok}) {
        for my $w (qw(day week month)) {
            my $v = $or->{"${w}_usd"};
            next unless defined $v && defined $caps->{$w};
            push @r, sprintf('OpenRouter %s $%.2f over $%.2f cap', $w, $v, $caps->{$w}) if $v >= $caps->{$w};
        }
    } else { $known = 0 }
    my $over = @r ? 1 : 0;
    my $action = $over ? ($st->{tripped} ? 'hold' : 'trip')
               : $st->{tripped} ? ($known ? 'restore' : 'hold')
               : 'none';
    return { action => $action, reasons => \@r, over => $over, known => $known };
}

# pure: first candidate whose health is not open / ollama model present.
sub pick_target {
    my (%in) = @_;
    my $health = $in{health} || {};
    my $tags   = $in{ollama_models};   # arrayref or undef (down)
    for my $c (@{ $in{candidates} || \@CANDIDATES }) {
        if ($c->{ollama}) {
            next unless ref $tags eq 'ARRAY' && grep { $_ eq $c->{ollama} } @$tags;
            return { %$c };
        }
        my $h = $health->{ $c->{health} // '' };
        next if $h && ($h->{state} // '') eq 'open';
        return { %$c };
    }
    return undef;
}


# Aliases that must not point at paid coding models while tripped.
our @DANGEROUS_ALIASES = qw(code coder code-paid flash delegate glm hy3);
# Already-safe aliases we never rewrite.
our @SAFE_ALIAS_KEEP = qw(cheap director local xai git reasoner editor deepseek);

# pure: which aliases to rewrite to $safe (full openrouter/...:free or ollama slug).
# Returns { set => {alias=>new}, saved => {alias=>old_value} }.
sub alias_rewrite_plan {
    my (%in) = @_;
    my $cur  = $in{aliases} || {};
    my $safe = $in{safe} || 'openrouter/cohere/north-mini-code:free';
    my (%set, %saved);
    for my $a (@{ $in{dangerous} || \@DANGEROUS_ALIASES }) {
        my $v = $cur->{$a};
        next unless defined $v && length $v;
        next if $v eq $safe;
        next if $v =~ /:free\z/ || $v =~ /^ollama/;
        $set{$a} = $safe;
        $saved{$a} = $v;
    }
    return { set => \%set, saved => \%saved };
}

# pure: should restore put back saved_model.default?
# If the user changed model.default during the trip (current != what we set as target),
# leave it alone. Only restore the default when it still matches the guard target.
sub restore_model_decision {
    my (%in) = @_;
    my $cur    = $in{current_default};
    my $target = $in{target};
    my $saved  = $in{saved_model} || {};
    my $saved_d = $saved->{default};
    return { restore_default => 0, reason => 'no_saved' } unless defined $saved_d && length $saved_d;
    if (defined $cur && defined $target && length $cur && length $target && $cur ne $target) {
        return { restore_default => 0, reason => 'manual_default_preserved', current => $cur, target => $target, saved => $saved_d };
    }
    return { restore_default => 1, reason => 'restore_saved', saved => $saved_d };
}

# ---- inputs ----------------------------------------------------------------
sub thrash_count {
    my ($self) = @_;
    return undef unless -f $self->{state_db};
    my $n = eval {
        require DBI;
        my $dbh = DBI->connect("dbi:SQLite:dbname=$self->{state_db}", '', '',
            { RaiseError => 1, PrintError => 0, sqlite_open_flags => 1 }); # SQLITE_OPEN_READONLY
        my $since = $self->_now - $THRASH_WINDOW;
        my ($c) = $dbh->selectrow_array(
            q{SELECT COUNT(*) FROM messages WHERE role = 'assistant' AND timestamp > ?}, undef, $since);
        $dbh->disconnect;
        $c;
    };
    return $n;
}

sub openrouter_status {
    my ($self) = @_;
    my $http = HTTP::Tiny->new(timeout => 25);
    for my $b (@{ $self->{base_urls} }) {
        my $r = $http->get("$b/ai/usage_live");
        next unless $r->{success};
        my $d = eval { $J->decode($r->{content}) } or next;
        my $o = ($d->{org} || {})->{openrouter} || $d->{openrouter};
        return { %$o, via => $b } if ref $o eq 'HASH' && $o->{ok};
    }
    return { ok => 0, error => 'usage_live unreachable' };
}

sub model_health {
    my ($self) = @_;
    my $f = "$self->{app_root}/data/ai_model_health.json";
    open my $fh, '<', $f or return {};
    local $/; my $d = eval { $J->decode(<$fh>) } || {};
    return $d->{models} || {};
}

sub ollama_models {
    my ($self) = @_;
    my $r = HTTP::Tiny->new(timeout => 4)->get("$self->{ollama_url}/api/tags");
    return undef unless $r->{success};
    my $d = eval { $J->decode($r->{content}) } or return undef;
    return [ map { $_->{name} } @{ $d->{models} || [] } ];
}

sub current_model {
    my ($self) = @_;
    open my $fh, '<', $self->{config} or return {};
    my (%m, $in);
    while (my $l = <$fh>) {
        if ($l =~ /^model:\s*$/) { $in = 1; next }
        if ($in) {
            last if $l =~ /^\S/;
            $m{$1} = $2 if $l =~ /^  (provider|default|base_url|api_mode):\s*['"]?(.*?)['"]?\s*$/;
        }
    }
    return \%m;
}

# ---- io helpers ------------------------------------------------------------
sub read_state { my $s = shift; open my $fh, '<', $s->{state_file} or return {}; local $/; eval { $J->decode(<$fh>) } || {} }
sub write_state {
    my ($s, $st) = @_;
    my $tmp = "$s->{state_file}.tmp";
    open my $fh, '>', $tmp or return; print $fh JSON::PP->new->canonical->pretty->encode($st); close $fh;
    rename $tmp, $s->{state_file};
}
sub _append { my ($f, $line) = @_; open my $fh, '>>', $f or return; print $fh $line, "\n"; close $fh }
sub log_line { my ($s, $msg) = @_; _append($s->{log_file}, strftime('%Y-%m-%dT%H:%M:%S', localtime $s->_now) . " $msg") }

sub backup_config {
    my ($s) = @_;
    my $dst = $s->{config} . '.bak-overrun-' . strftime('%Y%m%d-%H%M%S', localtime $s->_now);
    File::Copy::copy($s->{config}, $dst) or return undef;
    return $dst;
}


sub read_aliases {
    my ($self) = @_;
    open my $fh, '<', $self->{config} or return {};
    my (%a, $in_model, $in_al);
    while (my $l = <$fh>) {
        if ($l =~ /^model:\s*$/) { $in_model = 1; $in_al = 0; next }
        if ($in_model) {
            last if $l =~ /^\S/;
            if ($l =~ /^  aliases:\s*$/) { $in_al = 1; next }
            if ($in_al) {
                if ($l =~ /^  \S/) { $in_al = 0; next }
                $a{$1} = $2 if $l =~ /^    ([A-Za-z0-9_-]+):\s*['"]?(.*?)['"]?\s*$/;
            }
        }
    }
    return \%a;
}

sub set_aliases {
    my ($s, $map) = @_;
    return [] unless ref $map eq 'HASH' && %$map;
    my @done;
    for my $a (sort keys %$map) {
        my $v = $map->{$a};
        if ($s->{set_cb}) { $s->{set_cb}->("model.aliases.$a", $v) }
        else {
            system($s->{hermes_bin}, 'config', 'set', "model.aliases.$a", $v) == 0
                or die "hermes config set model.aliases.$a failed\n";
        }
        push @done, "$a=$v";
    }
    return \@done;
}

sub write_session_notice {
    my ($s, $hash) = @_;
    my $tmp = "$s->{session_notice}.tmp";
    open my $fh, '>', $tmp or return;
    print $fh $J->encode($hash); close $fh;
    rename $tmp, $s->{session_notice};
}

sub desktop_notify {
    my ($s, $title, $body) = @_;
    return if $s->{dry_run} || $s->{no_notify};
    eval {
        system('notify-send', $title, $body, '--app-name', 'Hermes Overrun Guard',
               '--urgency', 'critical');
    };
}

sub set_model {
    my ($s, $m) = @_;
    my $cur = $s->current_model;
    my @done;
    for my $k (@MODEL_KEYS) {
        next unless defined $m->{$k};
        next if defined $cur->{$k} && $cur->{$k} eq $m->{$k};
        if ($s->{set_cb}) { $s->{set_cb}->("model.$k", $m->{$k}) }
        else {
            system($s->{hermes_bin}, 'config', 'set', "model.$k", $m->{$k}) == 0
                or die "hermes config set model.$k failed\n";
        }
        push @done, "model.$k=$m->{$k}";
    }
    return \@done;
}

sub ledger {
    my ($s, $meta) = @_;
    return if $s->{no_ledger};
    my $http = HTTP::Tiny->new(timeout => 15);
    for my $b (@{ $s->{base_urls} }) {
        my $r = $http->post_form("$b/ai/usage_ingest", {
            source => 'hermes', request_type => 'overrun_guard', provider => 'hermes',
            model => $meta->{to} // '', status => $meta->{action},
            metadata => $J->encode($meta),
        });
        return 1 if $r->{success};
    }
    return 0;
}

# ---- main ------------------------------------------------------------------
sub run {
    my ($s, %o) = @_;
    open my $lk, '>', $s->{lock_file} or return { action => 'error', error => "lock: $!" };
    flock($lk, LOCK_EX | LOCK_NB) or return { action => 'skip', reason => 'locked' };
    my $st = $s->read_state;
    my $t  = $s->_now;
    if (!$o{force} && $st->{last_check} && $t - $st->{last_check} < $s->{min_interval}) {
        return { action => 'skip', reason => 'interval', state => $st };
    }
    my $thrash = exists $o{thrash} ? $o{thrash} : $s->thrash_count;
    my $or     = $o{openrouter} || $s->openrouter_status;
    my $d = decide(thrash => $thrash, openrouter => $or, state => $st);
    $d->{thrash} = $thrash;
    $d->{openrouter} = { map { ($_ => $or->{$_}) } grep { exists $or->{$_} } qw(ok day_usd week_usd month_usd balance_usd error) };
    $st->{last_check}    = $t;
    $st->{last_check_pt} = pt($t);
    $st->{last_reasons}  = $d->{reasons};
    $st->{last_thrash}   = $thrash;
    $st->{last_openrouter} = $d->{openrouter};
    $st->{caps} = { %CAPS, thrash_per_15min => $THRASH_N };

    if ($s->{dry_run}) { $d->{dry_run} = 1; return $d }

    if ($d->{action} eq 'trip') {
        my $target = pick_target(health => $s->model_health, ollama_models => $s->ollama_models);
        my $cur    = $s->current_model;
        my $aliases = $s->read_aliases;
        my $bak    = $s->backup_config;
        my $paused = $target ? 0 : 1;
        $target ||= { %{ $CANDIDATES[0] }, placeholder => 1 };
        my $safe = $target->{name};
        my $aplan = alias_rewrite_plan(aliases => $aliases, safe => $safe);
        my $done = eval { $s->set_model($target) } || [];
        my $err  = $@;
        my $adone = eval { $s->set_aliases($aplan->{set}) } || [];
        $err ||= $@;
        %$st = (%$st, tripped => 1, paused => $paused, since => $t, since_pt => pt($t),
                reasons => $d->{reasons}, saved_model => $cur, saved_aliases => $aplan->{saved},
                target => $target->{name}, backup => $bak, set => $done, aliases_set => $adone,
                ($err ? (set_error => "$err") : ()));
        my $msg = sprintf("Hermes overrun guard TRIPPED %s: %s. %s Backup: %s. Aliases blocked: %s. End open Hermes sessions (or /model cheap) - live sessions keep their model until restarted.",
            pt($t), join('; ', @{ $d->{reasons} }),
            $paused ? "No working cheap model - Hermes PAUSED (free placeholder $target->{name})."
                    : "Hermes default switched to $target->{name}.", $bak // 'FAILED',
            (@$adone ? join(', ', @$adone) : 'none'));
        _write_notice($s, $msg . "\nAuto-restores when thrash < $THRASH_N/15 min and OpenRouter day/week/month are under \$$CAPS{day}/\$$CAPS{week}/\$$CAPS{month}.");
        $s->write_session_notice({ at => $t, at_pt => pt($t), action => 'trip', reasons => $d->{reasons},
            target => $target->{name}, text => $msg });
        $s->desktop_notify('Hermes overrun guard TRIPPED',
            ($paused ? 'Hermes PAUSED. ' : "Switched to $target->{name}. ")
            . 'End/restart open sessions. Details: ~/.hermes/overrun_notice.txt');
        $s->log_line($msg . ($err ? " set_error=$err" : ''));
        my $ev = { at => $t, at_pt => pt($t), action => 'trip', reasons => $d->{reasons},
                   from => $cur->{default}, to => $target->{name}, paused => $paused, backup => $bak,
                   aliases_blocked => [ sort keys %{ $aplan->{set} } ] };
        _append($s->{events_file}, $J->encode($ev));
        $ev->{ledger} = $s->ledger($ev);
        $d->{target} = $target->{name}; $d->{paused} = $paused; $d->{backup} = $bak;
        $d->{aliases_blocked} = [ sort keys %{ $aplan->{set} } ];
    }
    elsif ($d->{action} eq 'restore') {
        my $want = $st->{saved_model} || {};
        my $cur  = $s->current_model;
        my $dec  = restore_model_decision(current_default => $cur->{default}, target => $st->{target},
                                          saved_model => $want);
        my $bak  = $s->backup_config;
        my ($done, $err) = ([], undef);
        if ($dec->{restore_default}) {
            $done = eval { $s->set_model($want) } || [];
            $err  = $@;
        }
        my $aliases_restored = eval { $s->set_aliases($st->{saved_aliases} || {}) } || [];
        $err ||= $@;
        # If Super Grok guard wants grok and we left a free placeholder in place, prefer grok.
        my $sg = eval {
            open my $fh, '<', "$s->{hermes_home}/supergrok_guard_state.json" or return undef;
            local $/; $J->decode(<$fh>);
        } || {};
        if (!$dec->{restore_default} && ($sg->{mode} // '') eq 'grok' && !($sg->{locked} || $sg->{off_today})) {
            # leave manual default; do not force grok over a hand-set model
        } elsif ($dec->{restore_default} && ($sg->{mode} // '') eq 'grok' && !($sg->{locked} || $sg->{off_today})
                 && ($want->{default} // '') =~ /:free\z|north-mini/) {
            # saved was free (pre-trip idle); Super Grok has allotment - hand off via notice only
            # (supergrok_daily_guard cron will switch within 5 min). Mark for the cron.
            $st->{hand_off_supergrok} = 1;
            # Coding aliases must not snap back to v4-pro on restore — Super Grok
            # guard will apply default; leave code/coder aimed at grok-build.
            $st->{saved_aliases} ||= {};
            $st->{saved_aliases}{$_} = 'xai-oauth/grok-build-0.1' for qw(code coder);
        }
        my $msg  = sprintf('Hermes overrun guard RESTORED %s: windows clear; %s (tripped since %s). Backup: %s. Aliases restored: %s',
            pt($t),
            ($dec->{restore_default}
                ? "model back to " . ($want->{default} // '?')
                : "kept hand-set default " . ($cur->{default} // '?') . " (guard had set " . ($st->{target} // '?') . ")"),
            $st->{since_pt} // '?', $bak // 'FAILED',
            (@$aliases_restored ? join(', ', @$aliases_restored) : 'none'));
        $s->log_line($msg . ($err ? " set_error=$err" : ''));
        _write_notice($s, $msg);
        $s->write_session_notice({ at => $t, at_pt => pt($t), action => 'clear', text => $msg });
        $s->desktop_notify('Hermes overrun guard cleared', $msg);
        my $ev = { at => $t, at_pt => pt($t), action => 'restore',
                   to => ($dec->{restore_default} ? $want->{default} : $cur->{default}),
                   preserved_manual => $dec->{restore_default} ? 0 : 1,
                   backup => $bak, tripped_since => $st->{since} };
        _append($s->{events_file}, $J->encode($ev));
        $ev->{ledger} = $s->ledger($ev);
        %$st = (%$st, tripped => 0, paused => 0, restored_at => $t, restored_pt => pt($t),
                restore_backup => $bak, restore_decision => $dec->{reason});
        delete @$st{qw(reasons target set set_error aliases_set)};
        $d->{restored_to} = $ev->{to};
        $d->{preserved_manual} = $ev->{preserved_manual};
    }
    elsif ($d->{action} eq 'hold') {
        $st->{reasons} = $d->{reasons} if @{ $d->{reasons} };
    }
    $s->write_state($st);
    $d->{state} = $st;
    return $d;
}

sub _write_notice { my ($s, $m) = @_; open my $fh, '>', $s->{notice_file} or return; print $fh "$m\n"; close $fh }

# For banner: read-only status.

sub read_session_notice {
    my ($s) = @_;
    require JSON::PP;
    $s = $s->new unless ref $s;
    my $path = $s->{session_notice};
    return {} unless $path && -f $path;
    open my $fh, '<', $path or return {};
    local $/; my $raw = <$fh>; close $fh;
    my $j = eval { JSON::PP->new->utf8->decode($raw) };
    return ref $j eq 'HASH' ? $j : {};
}

sub status {
    my ($class_or_self, %a) = @_;
    my $s = ref $class_or_self ? $class_or_self : $class_or_self->new(%a);
    my $st = $s->read_state;
    return { tripped => 0, checked => 0 } unless %$st;
    my $stale = $st->{last_check} ? ($s->_now - $st->{last_check} > 1200 ? 1 : 0) : 1;
    my $sn = $s->read_session_notice;
    my $handoff_banner = '';
    if ($sn && ($sn->{action} || '') eq 'supergrok_handoff' && $sn->{at}
        && ($s->_now - $sn->{at}) < 6 * 3600) {
        $handoff_banner = $sn->{text} || sprintf(
            'Super Grok handoff (%s) — Hermes → %s. Open TUI may need /model or a new session.',
            $sn->{reason} // 'handoff', $sn->{to} // 'grok-build-0.1');
    }
    return {
        tripped => $st->{tripped} ? 1 : 0, paused => $st->{paused} ? 1 : 0,
        since_pt => $st->{since_pt}, reasons => $st->{reasons} || [], target => $st->{target},
        backup => $st->{backup}, last_check_pt => $st->{last_check_pt}, stale => $stale,
        last_reasons => $st->{last_reasons} || [], last_thrash => $st->{last_thrash},
        openrouter => $st->{last_openrouter}, caps => $st->{caps}, restored_pt => $st->{restored_pt},
        checked => 1,
        session_notice => $sn,
        handoff_banner => $handoff_banner,
        hand_off_supergrok => $st->{hand_off_supergrok} ? 1 : 0,
    };
}

sub banner {
    my ($st) = @_;
    return '' unless $st && $st->{tripped};
    return sprintf('Hermes overrun guard %s since %s: %s -> %s. Live Hermes sessions keep their model - end them or /model cheap, then start a new session. Auto-restores when clear.',
        $st->{paused} ? 'PAUSED Hermes' : 'tripped', $st->{since_pt} // '?',
        join('; ', @{ $st->{reasons} || [] }), $st->{target} // '?');
}

1;
