package Comserv::Util::AI::HealthChecks;

# AI health for the usage page (AISYSTEM items 3, 4, 6, 8): meter staleness
# (alert > 6 h), our own SuperGrok estimate from Hermes xai-oauth calls (no
# grok.com meter needed), the SuperGrok guard switch banner, an Ollama health
# check for Today's Focus (llama-server binary, decision models present,
# recent "binary not found" in the journal) and the decision organizer state.
# Read-only: no writes except throttled log lines through the caller's logger.

use strict;
use utf8;
use warnings;
use JSON ();
use Time::Local qw(timegm);
use POSIX qw(strftime);

our $ALERT_AFTER_S  = 6 * 3600;
our $PCT_PER_CALL   = 0.05;     # same rough calibration as supergrok_daily_guard.py
our $OLLAMA_URL     = $ENV{OLLAMA_URL} || 'http://127.0.0.1:11434';
our $LLAMA_SERVER   = $ENV{OLLAMA_LLAMA_SERVER} || '/usr/local/lib/ollama/llama-server';
our @FOCUS_MODELS   = qw(tev1:0.8b nimble:latest);   # Today's Focus decision models (DecisionRank / Ollama::Decision)
our %LAST_ALERT;                                    # throttle: one log line per meter per hour

sub _home { $ENV{HOME} && $ENV{HOME} ne '/' ? $ENV{HOME} : '/home/shanta' }

sub _read_json {
    my ($path) = @_;
    return undef unless defined $path && -f $path;
    my $d = eval {
        open my $fh, '<:raw', $path or die "$!\n";
        local $/; my $raw = <$fh>; close $fh;
        JSON->new->decode($raw);
    };
    return ref $d eq 'HASH' ? $d : undef;
}

# ISO 8601 with Z / ±hh:mm offset, or epoch -> epoch
sub iso_epoch {
    my ($s) = @_;
    return undef unless defined $s && length $s;
    return 0 + $s if $s =~ /^\d+(?:\.\d+)?$/;
    return undef unless $s =~ /^(\d{4})-(\d\d)-(\d\d)[T ](\d\d):(\d\d)(?::(\d\d))?(?:\.\d+)?\s*(Z|[+-]\d\d:?\d\d)?/;
    my $e = eval { timegm($6 // 0, $5, $4, $3, $2 - 1, $1) };
    return undef unless defined $e;
    my $z = $7 // '';
    if ($z =~ /^([+-])(\d\d):?(\d\d)$/) { $e -= ($1 eq '-' ? -1 : 1) * ($2 * 3600 + $3 * 60) }
    elsif ($z eq '') { $e = eval { Time::Local::timelocal($6 // 0, $5, $4, $3, $2 - 1, $1) } // $e }
    return $e;
}

sub pt {
    my ($e) = @_;
    return '' unless defined $e && $e > 0;
    local $ENV{TZ} = 'America/Vancouver';
    POSIX::tzset();
    my $s = strftime('%Y-%m-%d %H:%M PT', localtime($e));
    POSIX::tzset();
    return $s;
}

# meters(app_root => ..., openrouter => {fetched_at,...}, now => epoch)
sub meters {
    my (%o) = @_;
    my $now  = $o{now} // time;
    my $root = $o{app_root} // '.';
    my $home = $o{home} // _home();
    my @m;
    my $add = sub {
        my ($name, $epoch, $note) = @_;
        my $row = { name => $name, note => $note // '' };
        if (defined $epoch && $epoch > 0) {
            $row->{at}    = $epoch;
            $row->{at_pt} = pt($epoch);
            $row->{age_h} = sprintf('%.1f', ($now - $epoch) / 3600);
            $row->{stale} = ($now - $epoch) > $ALERT_AFTER_S ? 1 : 0;
        } else {
            $row->{missing} = 1;
            $row->{stale}   = 1;
        }
        push @m, $row;
    };
    my $g = _read_json("$root/root/static/ai/grokcom_usage.json");
    $add->('grok.com usage meter (Build %)', $g ? iso_epoch($g->{at}) : undef,
           $g ? "build $g->{build}%" : 'root/static/ai/grokcom_usage.json missing');
    my $sg = _read_json("$root/root/static/ai/supergrok_guard.json");
    $add->('SuperGrok guard (cron, 15 min)', $sg ? iso_epoch($sg->{checked}) : undef,
           $sg ? "mode $sg->{mode}" : 'root/static/ai/supergrok_guard.json missing');
    if (my $or = $o{openrouter}) {
        $add->('OpenRouter key/credits API', $or->{fetched_at},
               $or->{ok} ? sprintf('balance %s', defined $or->{balance_usd} ? '$' . $or->{balance_usd} : '?') : ($or->{error} // 'not ok'));
    }
    my @stale = grep { $_->{stale} } @m;
    return { rows => \@m, any_stale => (@stale ? 1 : 0), stale => [ map { $_->{name} } @stale ],
             alert_after_h => $ALERT_AFTER_S / 3600 };
}

# Log each stale meter at most once an hour (caller passes a log coderef).
sub log_stale_meters {
    my ($meters, $log, %o) = @_;
    my $now = $o{now} // time;
    for my $r (@{ $meters->{rows} || [] }) {
        next unless $r->{stale};
        next if $LAST_ALERT{ $r->{name} } && $now - $LAST_ALERT{ $r->{name} } < 3600;
        $LAST_ALERT{ $r->{name} } = $now;
        $log->('warn', sprintf('AI meter stale: %s last reading %s (%s h old, alert after %d h)',
            $r->{name}, ($r->{at_pt} || 'never'), ($r->{age_h} // '?'), $ALERT_AFTER_S / 3600));
    }
}

sub hermes_xai_calls_since {
    my ($since, %o) = @_;
    my $db = $o{db} || $ENV{HERMES_STATE_DB} || _home() . '/.hermes/state.db';
    return (undef, 'state.db not readable') unless -r $db;
    my $n = eval {
        require DBI;
        my $dbh = DBI->connect("dbi:SQLite:dbname=$db", '', '', { RaiseError => 1, PrintError => 0, ReadOnly => 1 });
        my ($v) = $dbh->selectrow_array(
            q{SELECT COALESCE(SUM(COALESCE(api_call_count,0)),0) FROM sessions
              WHERE started_at >= ? AND (COALESCE(billing_provider,'') IN ('xai-oauth','supergrok','xai')
                                         OR COALESCE(model,'') LIKE '%grok%')}, undef, $since);
        $dbh->disconnect;
        0 + ($v || 0);
    };
    return defined $n ? ($n, undef) : (undef, "$@");
}

# Our own SuperGrok weekly estimate: meter build (0 if read before the cycle
# started) + Hermes xai-oauth API calls since then x PCT_PER_CALL.
sub supergrok_estimate {
    my (%o) = @_;
    my $now  = $o{now} // time;
    my $root = $o{app_root} // '.';
    my $g  = _read_json("$root/root/static/ai/grokcom_usage.json") || {};
    my $sg = _read_json("$root/root/static/ai/supergrok_guard.json") || {};
    my $reset = iso_epoch($sg->{reset_at});
    $reset += 7 * 86400 while defined $reset && $reset <= $now;
    my $cycle_start = defined $reset ? $reset - 7 * 86400 : $now - 7 * 86400;
    my $meter_at = iso_epoch($g->{at});
    my $build = (defined $g->{build} && $g->{build} =~ /^\d+(?:\.\d+)?$/) ? 0 + $g->{build} : undef;
    my $before_cycle = (defined $meter_at && $meter_at < $cycle_start) ? 1 : 0;
    my $base  = $before_cycle ? 0 : ($build // 0);
    my $since = $before_cycle || !defined $meter_at ? $cycle_start : $meter_at;
    my ($calls, $err) = $o{calls_cb} ? ($o{calls_cb}->($since), undef) : hermes_xai_calls_since($since, db => $o{db});
    my $est = defined $calls ? $base + $calls * $PCT_PER_CALL : undef;
    $est = 100 if defined $est && $est > 100;
    return {
        meter_build   => $build, meter_at_pt => pt($meter_at), meter_before_cycle => $before_cycle,
        cycle_start_pt => pt($cycle_start), reset_pt => pt($reset),
        calls_since   => $calls, since_pt => pt($since), pct_per_call => $PCT_PER_CALL,
        build_est     => (defined $est ? sprintf('%.0f', $est) : undef),
        remaining_est => (defined $est ? sprintf('%.0f', 100 - $est) : undef),
        source        => 'hermes state.db xai-oauth api_call_count (+ last grok.com reading)',
        ($err ? (error => $err) : ()),
    };
}

# Banner text when the guard has switched coding off SuperGrok.
sub guard_banner {
    my ($guard) = @_;
    return undef unless ref $guard eq 'HASH' && $guard->{locked};
    my $model = $guard->{switch_model} || 'deepseek/deepseek-v4-pro';
    my $prov  = $guard->{switch_provider} || 'openrouter';
    my $reset = iso_epoch($guard->{reset_at});
    return sprintf('Super Grok daily cap reached — coding switched to %s (%s) for the app and Hermes until reset %s. Reason: %s',
        $model, ($prov eq 'openrouter' ? 'OpenRouter' : $prov), ($reset ? pt($reset) : 'next PT day'), ($guard->{reason} || 'guard locked'));
}

sub _http_json {
    my ($url, $timeout) = @_;
    require HTTP::Tiny;
    my $r = HTTP::Tiny->new(timeout => $timeout || 2)->get($url);
    return (undef, "$r->{status} $r->{reason}") unless $r->{success};
    my $d = eval { JSON->new->decode($r->{content}) };
    return $d ? ($d, undef) : (undef, 'bad JSON');
}

# ollama_health(journal => 1, models => [...]) - Today's Focus models.
sub ollama_health {
    my (%o) = @_;
    my $out = { url => $OLLAMA_URL, problems => [], focus_models => [ @{ $o{models} || \@FOCUS_MODELS } ] };
    my ($v, $e) = _http_json("$OLLAMA_URL/api/version", 2);
    if ($v) { $out->{version} = $v->{version}; $out->{up} = 1 }
    else    { $out->{up} = 0; push @{ $out->{problems} }, "Ollama API not answering ($e)" }
    if ($out->{up}) {
        my ($t) = _http_json("$OLLAMA_URL/api/tags", 3);
        my %have = map { ($_->{name} // $_->{model} // '') => 1 } @{ ($t || {})->{models} || [] };
        $out->{installed} = scalar keys %have;
        $out->{missing_models} = [ grep { !$have{$_} } @{ $out->{focus_models} } ];
        push @{ $out->{problems} }, 'Focus model(s) not pulled: ' . join(', ', @{ $out->{missing_models} })
            if @{ $out->{missing_models} };
        my ($ps) = _http_json("$OLLAMA_URL/api/ps", 2);
        $out->{loaded} = [ map { $_->{name} } @{ ($ps || {})->{models} || [] } ];
    }
    # Sep 30: the 0.35.0 upgrade left lib/ollama without llama-server, so
    # every local model failed with "llama-server binary not found".
    $out->{llama_server} = $LLAMA_SERVER;
    $out->{llama_server_ok} = (-f $LLAMA_SERVER && -x _) ? 1 : 0;
    push @{ $out->{problems} }, "llama-server binary missing at $LLAMA_SERVER (re-extract the Ollama release tarball into /usr/local/lib/ollama)"
        unless $out->{llama_server_ok};
    if ($o{journal}) {
        my @lines;
        eval {
            local $SIG{ALRM} = sub { die "timeout\n" };
            alarm 4;
            if (open my $fh, '-|', 'journalctl', '-u', 'ollama', '--since', '-24h', '--no-pager', '-q', '-o', 'short-iso',
                    '-g', 'binary not found|error loading model|llama runner process has terminated') {
                while (my $l = <$fh>) { chomp $l; push @lines, substr($l, 0, 300); shift @lines if @lines > 5 }
                close $fh;
            }
            alarm 0;
            1;
        };
        alarm 0;
        $out->{recent_errors} = \@lines;
        # "binary not found" lines while the binary IS present now = the
        # Sep 30 incident, already fixed (re-extracted lib/ollama): history.
        my @open = grep { !($out->{llama_server_ok} && /binary not found/) } @lines;
        $out->{errors_resolved} = (@lines && !@open) ? 1 : 0;
        push @{ $out->{problems} }, scalar(@open) . ' Ollama load error(s) in the last 24 h (journal)' if @open;
    }
    $out->{ok} = @{ $out->{problems} } ? 0 : 1;
    return $out;
}

# Decision organizer (Today's Focus) state, so work carries over between
# sessions: per-branch last computed order + last decision call.
sub organizer_state {
    my (%o) = @_;
    my $root = $o{app_root} // '.';
    my $ro = _read_json("$root/data/ai_rank_order.json") || {};
    my @b;
    for my $br (sort keys %{ $ro->{branches} || {} }) {
        my $x = $ro->{branches}{$br};
        push @b, { branch => $br, model => $x->{model}, computed_pt => pt($x->{computed_at}),
                   asked => $x->{asked}, answered => $x->{answered}, input_tokens => $x->{input_tokens},
                   ranked => scalar(keys %{ $x->{rows} || {} }) };
    }
    my ($calls, $last) = (0, undef);
    if (open my $fh, '<', "$root/data/ai_decision_calls.jsonl") {
        while (my $l = <$fh>) { $calls++; $last = $l }
        close $fh;
    }
    my $lc = $last ? eval { JSON->new->decode($last) } : undef;
    return { branches => \@b, calls => $calls,
             last_call => ($lc ? { at_pt => pt($lc->{ts}), model => $lc->{model}, gate_passed => $lc->{gate_passed},
                                   changed => $lc->{changed}, candidates => $lc->{candidates} } : undef) };
}

1;
