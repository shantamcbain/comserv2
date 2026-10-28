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
use Comserv::Util::AI::PaidBlock ();
use Comserv::Util::AI::ModelChains ();
use Comserv::Util::AI::ModelTrial ();
use Comserv::Util::Logging ();
use File::Copy ();
use Time::Local qw(timegm timelocal);

our %CAPS = (day => 1.65, week => 11.50, month => 50);
our $NEAR_CAP_FRAC = 0.6;
our $THRASH_N      = 20;
our $THRASH_WINDOW = 900;

our %THRASH_LIMITS = (
    xai_direct      => 30,    # x.ai API key (cash) - Oct 26: tracked apart from Super Grok
    supergrok       => 240,   # runaway brake only; quota is policed by supergrok_daily_guard (Oct 8 replay: normal loops 20-37/15min, 2 parallel agents 113)
    openrouter_paid => 30,
    openrouter_free => 60,
    ollama          => 120,
    other           => 20,
);

# Cheapest first. 'health' = key in data/ai_model_health.json (circuit must not be open).
# 'default' is what Hermes sends to the provider: NEVER provider-prefixed (Oct 5 2026:
# model.default 'openrouter/cohere/...' with provider openrouter -> HTTP 400 'not a valid
# model ID' -> every new session fell through fallback_providers to paid v4-pro).
our @CANDIDATES = (
    { name => 'openrouter/cohere/north-mini-code:free', provider => 'openrouter',
      default => 'cohere/north-mini-code:free', base_url => 'https://openrouter.ai/api/v1',
      api_mode => 'chat_completions', health => 'openrouter|cohere/north-mini-code:free', free => 1 },
    # Oct 13 2026 (Shanta): north-mini free, then 64K Ollama, then the rest.
    { name => 'ollama-launch/gemma4-64k:latest', provider => 'ollama-launch',
      default => 'gemma4-64k:latest', base_url => 'http://127.0.0.1:11434/v1',
      api_mode => 'chat_completions', ollama => 'gemma4-64k:latest', free => 1 },
    { name => 'openrouter/nvidia/nemotron-3.5-lightning:free', provider => 'openrouter',
      default => 'nvidia/nemotron-3.5-lightning:free', base_url => 'https://openrouter.ai/api/v1',
      api_mode => 'chat_completions', health => 'openrouter|nvidia/nemotron-3.5-lightning:free', free => 1 },
    { name => 'ollama-launch/qwen2.5-coder:14b', provider => 'ollama-launch',
      default => 'qwen2.5-coder:14b', base_url => 'http://127.0.0.1:11434/v1',
      api_mode => 'chat_completions', ollama => 'qwen2.5-coder:14b', free => 1 },
);
# Super Grok (flat-rate subscription, weekly quota). Preferred on thrash trips and first
# in the permanent fallback chain while supergrok_guard_state.json says it has allotment.
our %SUPERGROK = ( name => 'xai-oauth/grok-build-0.1', provider => 'xai-oauth',
    default => 'grok-build-0.1', base_url => 'https://api.x.ai/v1', api_mode => 'codex_responses',
    supergrok => 1 );
# Proposal #34a (eval report 35, Oct 13 2026, Shanta: 'Yes, do all three'): when the OpenRouter $ cap trips and
# Super Grok still has daily budget (supergrok_daily_guard daily_budget), go to grok-4.7.
our %SUPERGROK_CAPS = ( %SUPERGROK, name => 'xai-oauth/grok-4.7', default => 'grok-4.7', sg_budget => 1 );
our $BANNED_RE      = qr/deepseek-v4-pro/i;   # never written anywhere by the guard
# Paid models whose recent use (last 10 min) trips the guard early once the day is
# at $NEAR_CAP_FRAC of the cap (proposal #34b adds tencent/hy4-preview).
our @PAID_WATCH     = ('deepseek-v4-pro', 'tencent/hy4-preview', 'x-ai/grok', 'qwen/qwen3-coder');   # Oct 21: 98 % stop paid coder
# Oct 15 2026 (Shanta): grok only through xai-oauth (Super Grok). Any OpenRouter grok id is
# BLOCKED, not just watched: set_model/set_aliases/write_fallback_providers rewrite it, and
# every run sweeps config default, aliases, fallback, auxiliary and delegation (or_grok_block_plan).
our $OR_GROK_RE     = qr{(?:^openrouter/.*grok|^x-ai/|/x-ai/|^~?x-ai/)}i;
our $FREE_SAFE      = { provider => 'openrouter', default => 'cohere/north-mini-code:free' };
our $PAID_WATCH_RE  = do { my $a = join '|', map { quotemeta } @PAID_WATCH; qr/$a/i };
our $OR_MODELS_URL  = 'https://openrouter.ai/api/v1/models';
our $OR_CACHE_TTL   = 6 * 3600;
our $OR_CACHE_STALE = 7 * 86400;
our ($UNPRICED_IN, $UNPRICED_OUT) = (2e-6, 4e-6);   # $/token when endpoint prices are unknown
our @PROVIDER_PREFIXES = qw(openrouter ollama-launch ollama xai-oauth xai);
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
        agent_log    => $a{agent_log} // "$hh/logs/agent.log",
        lock_file    => "$hh/overrun_guard.lock",
        state_db     => "$hh/state.db",
        or_cache     => "$hh/cache/overrun_guard_openrouter_models.json",
        supergrok_state_file => "$hh/supergrok_guard_state.json",
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
# in: thrash (int|undef), openrouter {ok,day_usd,...}, state {tripped}, caps, thrash_n,
#     thrash_by_class {ok, counts}, limits (hash). 
# When thrash_by_class ok: use per-class counts vs limits for thrash reasons (legacy thrash ignored for reasons).
# Else: legacy thrash behaviour exactly.
sub decide {
    my (%in) = @_;
    my $caps = $in{caps} || \%CAPS;
    my $tn   = $in{thrash_n} // $THRASH_N;
    my $st   = $in{state} || {};
    my $or   = $in{openrouter} || {};
    my $tbc  = $in{thrash_by_class};
    my $lims = $in{limits} || \%THRASH_LIMITS;
    my @r;
    my $known = 1;
    my $use_tbc = ref $tbc eq 'HASH' && $tbc->{ok};
    if ($use_tbc) {
        my $counts = $tbc->{counts} || {};
        for my $cl (sort keys %$counts) {
            my $n = $counts->{$cl} // 0;
            my $lim = exists($lims->{$cl}) ? $lims->{$cl} : ($lims->{other} // 20);
            if ($n >= $lim) {
                push @r, sprintf('thrash: %d %s calls in 15 min (limit %d)', $n, $cl, $lim);
            }
        }
        # legacy thrash/thrash_n ignored for reasons; thrash part treated as known
    } elsif (defined $in{thrash}) {
        push @r, "thrash: $in{thrash} Hermes calls in 15 min (limit $tn)" if $in{thrash} >= $tn;
    } else { $known = 0 }
    if ($or->{ok}) {
        for my $w (qw(day week month)) {
            my $v = $or->{"${w}_usd"};
            next unless defined $v && defined $caps->{$w};
            push @r, sprintf('OpenRouter %s $%.2f over $%.2f cap', $w, $v, $caps->{$w}) if $v >= $caps->{$w};
        }
    } else { $known = 0 }
    # x.ai direct API (cash, own cap): enforced apart from OpenRouter and from the Super Grok quota
    if (ref $in{xai_direct} eq 'HASH' && defined $in{xai_direct}{cap_day} && $in{xai_direct}{cap_day} > 0
        && ($in{xai_direct}{usd} // 0) >= $in{xai_direct}{cap_day}) {
        push @r, sprintf('x.ai direct day $%.2f over $%.2f cap', $in{xai_direct}{usd}, $in{xai_direct}{cap_day});
    }
    my $v4pro_recent = $in{v4pro_recent} // 0;
    if ($v4pro_recent && $or->{ok}) {
        my $dv = $or->{day_usd} // 0;
        my $dc = $caps->{day};
        if (defined $dc && $dv >= $NEAR_CAP_FRAC * $dc && $dv < $dc) {
            my $wm = $in{watch_model} // 'v4-pro';
            $wm = 'v4-pro' if $wm =~ /deepseek-v4-pro/i;
            push @r, sprintf('OpenRouter %s active near cap: day $%.2f >= $%.2f', $wm, $dv, $NEAR_CAP_FRAC * $dc);
        }
    }
    my $over = @r ? 1 : 0;
    my $action = $over ? ($st->{tripped} ? 'hold' : 'trip')
               : $st->{tripped} ? ($known ? 'restore' : 'hold')
               : 'none';
    return { action => $action, reasons => \@r, over => $over, known => $known };
}

# pure: strip a repeated provider prefix ('openrouter/openrouter/x' or 'openrouter/x'
# with provider openrouter -> 'x').
sub normalize_model_id {
    my ($provider, $id) = @_;
    return $id unless defined $id;
    $id =~ s/^\s+|\s+$//g;
    $id =~ s/^['"]|['"]$//g;
    if (defined $provider && length $provider) { 1 while $id =~ s{^\Q$provider\E/}{} }
    return $id;
}

# pure: strip any known provider prefix (for comparing ids written in different forms).
sub bare_model_id {
    my ($id) = @_;
    return '' unless defined $id;
    my $re = join '|', map { quotemeta } @PROVIDER_PREFIXES;
    1 while $id =~ s{^(?:$re)/}{};
    return $id;
}

# pure: provider-qualified alias form ('openrouter/cohere/north-mini-code:free').
sub alias_value {
    my ($c) = @_;
    return $c->{provider} . '/' . normalize_model_id($c->{provider}, $c->{default});
}

# pure: normalize an alias value ('openrouter/openrouter/x' -> 'openrouter/x').
sub normalize_alias {
    my ($v) = @_;
    return $v unless defined $v && $v =~ m{^([^/]+)/(.+)$};
    my ($p, $rest) = ($1, $2);
    return "$p/" . normalize_model_id($p, $rest);
}

# pure: classify an API call record from parse_api_calls into a thrash class for per-provider limits.
sub classify_call {
    my ($call) = @_;
    return 'other' unless ref $call eq 'HASH';
    my $p = lc( $call->{provider} // '' );
    my $m = $call->{model} // '';
    if ($p =~ /^(xai-oauth|supergrok)$/) {
        return 'supergrok';
    }
    return 'xai_direct' if $p eq 'xai';   # Oct 26: x.ai API key = cash, not the Super Grok quota
    if ($p eq 'openrouter') {
        return 'openrouter_free' if $m =~ /:free\z/;
        return 'openrouter_paid';
    }
    if ($p =~ /^(ollama|ollama-launch|custom)$/ || ($p =~ /ollama/ && $m !~ m{/})) {
        return 'ollama';
    }
    return 'other';
}

# pure: how a call is billed (Oct 26, Shanta: track and enforce Super Grok, x.ai direct and OpenRouter
# separately, each by the cash spent in that system). Returns
#   supergrok  - xai-oauth: flat-rate quota, no cash
#   xai_direct - provider xai (API key): cash billed by x.ai
#   openrouter - any OpenRouter call (free ids cost 0; an OpenRouter grok id is still billed by OpenRouter)
#   ollama / other
sub billing_channel {
    my ($provider, $model) = @_;
    my $p = lc($provider // '');
    return 'supergrok'  if $p =~ /^(?:xai-oauth|supergrok)$/;
    return 'xai_direct' if $p eq 'xai';
    return 'openrouter' if $p eq 'openrouter';
    return 'ollama'     if $p =~ /ollama|^custom$/;
    return 'other';
}

# pure: "provider/model (channel)" label that is shown in every alert, so the message names what is billing.
sub billing_label {
    my ($provider, $model) = @_;
    my $ch = billing_channel($provider, $model);
    my $what = ($ch eq 'openrouter' && $model =~ /grok/i) ? 'OpenRouter grok (paid)'
             : $ch eq 'openrouter' ? ($model =~ /:free\z/ ? 'OpenRouter free' : 'OpenRouter paid')
             : $ch eq 'xai_direct' ? 'x.ai direct API (paid)'
             : $ch eq 'supergrok'  ? 'Super Grok quota' : $ch;
    return sprintf('%s/%s [%s]', $provider // '?', $model // '?', $what);
}

# pure: is there room for the paid step of the Hermes chain? No OpenRouter money-cap reason and the
# day/week/month use is still well inside the caps (day < 60 %, week and month < 90 %).
sub paid_room {
    my ($or, $caps, $reasons) = @_;
    return @{ [ paid_room_why($or, $caps, $reasons) ] } ? 0 : 1;
}

# pure: the reasons the paid step has no room right now (empty list = room). Plain words for notices, e.g.
# 'OpenRouter month $45.82 of $50 over the 90% rule'.
sub paid_room_why {
    my ($or, $caps, $reasons) = @_;
    my @w;
    push @w, 'an OpenRouter money cap is already hit' if grep { /^OpenRouter/ } @{ $reasons || [] };
    return (@w, 'OpenRouter usage unknown') unless ref $or eq 'HASH' && $or->{ok};
    $caps ||= \%CAPS;
    my %frac = (day => $NEAR_CAP_FRAC, week => 0.9, month => 0.9);
    for my $w (qw(day week month)) {
        my ($v, $cap) = ($or->{"${w}_usd"}, $caps->{$w});
        next unless defined $v && defined $cap;
        push @w, sprintf('OpenRouter %s $%.2f of $%s over the %d%% rule', $w, $v, 0 + $cap, int($frac{$w} * 100 + 0.5)) if $v >= $frac{$w} * $cap;
    }
    return @w;
}

# pure: why a live call is not allowed right now (undef = allowed). %pol: tripped, allowed_paid {model=>1},
# xai_direct_cap_day, or_over (OpenRouter cap reached).
sub offender_reason {
    my ($provider, $model, %pol) = @_;
    $provider //= ''; $model //= '';
    return "approved trial stopped: $pol{trial_stopped}{$model}" if ref $pol{trial_stopped} eq 'HASH' && $pol{trial_stopped}{$model};
    my $ch = billing_channel($provider, $model);
    if ($ch eq 'openrouter') {
        return 'OpenRouter grok is blocked (grok only through Super Grok)' if is_or_grok($provider, $model);
        return 'banned model (v4-pro / glm)' if $model =~ $BANNED_RE || $model =~ /glm/i;
        return undef if $model =~ /:free\z/;
        my $ok_paid = ref $pol{allowed_paid} eq 'HASH' && $pol{allowed_paid}{$model};
        return 'OpenRouter cap reached - no paid model is allowed' if $pol{or_over};
        return 'paid model not in the Hermes chain while the guard is tripped' if $pol{tripped} && !$ok_paid;
        return 'paid model not in the Hermes chain (only the chain paid step is allowed when Super Grok is unavailable)'
            if $pol{sg_unavailable} && !$ok_paid;
        return undef;
    }
    if ($ch eq 'xai_direct') {
        my $cap = $pol{xai_direct_cap_day} // 0;
        return 'x.ai direct API is off (cash cap $0)' if $cap <= 0;
        return 'x.ai direct API cap reached' if $pol{xai_over};
    }
    return undef;
}

# pure: sessions (from live_spend {recent}) running on a disallowed model/provider.
sub session_offenders {
    my ($recent, %pol) = @_;
    my @out;
    for my $r (sort { ($b->{last_t} // 0) <=> ($a->{last_t} // 0) } values %{ $recent || {} }) {
        my $why = offender_reason($r->{provider}, $r->{model}, %pol) or next;
        push @out, { %$r, reason => $why, label => billing_label($r->{provider}, $r->{model}) };
    }
    return \@out;
}

# pure: the highest-spending models of the last window as readable text, for trip alerts.
sub billing_summary {
    my ($recent, $n) = @_;
    my %by;
    for my $r (values %{ $recent || {} }) {
        my $k = "$r->{provider}\0$r->{model}";
        $by{$k} ||= { provider => $r->{provider}, model => $r->{model}, usd => 0, calls => 0 };
        $by{$k}{usd} += $r->{usd} // 0; $by{$k}{calls} += $r->{calls} // 0;
    }
    my @top = sort { $b->{usd} <=> $a->{usd} || $b->{calls} <=> $a->{calls} } values %by;
    @top = @top[0 .. ($n // 3) - 1] if @top > ($n // 3);
    return [ map { { %$_, label => billing_label($_->{provider}, $_->{model}) } } @top ];
}

our $COOLDOWN_S = 1800;
# pure: an OpenRouter money-cap trip while Hermes is on Super Grok (xai-oauth) only blocks paid models.
sub paid_only_trip {
    my ($kind, $cm) = @_;
    return 0 unless ($kind // '') eq 'caps' && ref $cm eq 'HASH';
    return (($cm->{provider} // '') =~ /^(?:xai-oauth|xai|supergrok)$/ && length($cm->{default} // '')) ? 1 : 0;
}

sub trip_kind {
    my ($reasons) = @_;
    my $rs = $reasons || [];
    return 'caps' if grep { /^(?:OpenRouter|x\.ai direct)/ } @$rs;
    return 'caps' if grep { /^thrash: \d+ supergrok / } @$rs;
    return 'thrash';
}

# pure: Super Grok usable? (supergrok_daily_guard state: mode grok, not locked/off, quota left)
sub supergrok_available {
    my ($sg) = @_;
    return 0 unless ref $sg eq 'HASH' && %$sg;
    return 0 if $sg->{locked} || $sg->{off_today};
    return 0 if ($sg->{mode} // 'grok') ne 'grok';
    return 0 if defined $sg->{remaining} && $sg->{remaining} =~ /^[\d.]+$/ && $sg->{remaining} <= 5;
    return 1;
}

# pure: Super Grok has daily budget left per supergrok_daily_guard (daily_budget block of
# supergrok_guard_state.json). Unlike supergrok_available this ignores 'mode', which is
# 'openrouter' whenever Hermes was moved off Super Grok (e.g. by this guard). (proposal #34a, eval report 35)
sub supergrok_budget_left {
    my ($sg) = @_;
    return 0 unless ref $sg eq 'HASH' && %$sg;
    return 0 if $sg->{locked} || $sg->{off_today};
    # 2026-10-17: never hand Hermes to Super Grok at/above the weekly hard stop (~98 %).
    my $hard = $sg->{hard_week_cap} // 98;
    for my $u ($sg->{build}, (ref $sg->{daily_budget} eq 'HASH' ? $sg->{daily_budget}{used_now_pct} : undef)) {
        return 0 if defined $u && $u =~ /^[\d.]+$/ && $hard =~ /^[\d.]+$/ && $u >= $hard;
    }
    my $b = $sg->{daily_budget};
    unless (ref $b eq 'HASH' && %$b) {
        # app pacing unreachable: trust the daily guard's own call. deferred_mode 'grok' means it
        # wanted Super Grok but held off because this guard had tripped.
        my $want = ($sg->{mode} // '') eq 'grok' || ($sg->{deferred_mode} // '') eq 'grok';
        return ($want && ($sg->{remaining} // 0) > 5) ? 1 : 0;
    }
    return 0 if $b->{over} || $b->{switch_off} || $b->{week_off};
    my $rem = $b->{remaining_today_pct};
    $rem = ($b->{effective_budget_pct} // 0) - ($b->{used_today_pct} // 0) unless defined $rem && $rem =~ /^-?[\d.]+$/;
    return ($rem =~ /^-?[\d.]+$/ && $rem > 0) ? 1 : 0;
}

# pure: is candidate $c writable right now? Validated id, never banned, never double-prefixed.
# Oct 10 2026: Hermes needs ~64K context. An Ollama model qualifies only if its
# effective context (Modelfile PARAMETER num_ctx, else OLLAMA_CONTEXT_LENGTH, else
# Ollama's 4096 default) is >= $HERMES_MIN_CTX. ollama_ctx => { model => ctx } comes
# from ollama_ctx_map(); unknown (Ollama down) keeps only models in %KNOWN_CTX_OK.
our $HERMES_MIN_CTX = 65536;
our %KNOWN_CTX_OK = ('gemma4-64k:latest' => 65536);

# pure
sub ollama_ctx_ok {
    my ($model, $map) = @_;
    return 1 unless defined $model;
    my $ctx = ref $map eq 'HASH' ? $map->{$model} : undef;
    $ctx //= $KNOWN_CTX_OK{$model};
    return (defined $ctx && $ctx >= $HERMES_MIN_CTX) ? 1 : 0;
}

# pure: drop Ollama fallback entries below the Hermes context floor. Returns (\@kept, \@dropped).
sub filter_ollama_ctx {
    my ($list, $map) = @_;
    my (@k, @d);
    for my $e (@{ $list || [] }) {
        if (($e->{provider} // '') =~ /^(?:ollama|ollama-launch|custom:ollama)/ && !ollama_ctx_ok($e->{model}, $map)) {
            push @d, $e;
        } else { push @k, $e }
    }
    return (\@k, \@d);
}

sub candidate_ok {
    my ($c, %in) = @_;
    my $d = $c->{default} // '';
    return 0 if !length $d || $d =~ $BANNED_RE;
    return 0 if normalize_model_id($c->{provider}, $d) ne $d;
    return 0 if $c->{paid} && (!$in{paid_ok} || $d =~ /glm/i || is_or_grok($c->{provider}, $d));   # paid chain step only inside the caps
    return supergrok_budget_left($in{supergrok}) if $c->{sg_budget};
    return supergrok_available($in{supergrok}) if $c->{supergrok};
    if ($c->{ollama}) {
        my $t = $in{ollama_models};
        return 0 if exists $in{ollama_ctx} && !ollama_ctx_ok($c->{ollama}, $in{ollama_ctx});
        return (ref $t eq 'ARRAY' && grep { $_ eq $c->{ollama} } @$t) ? 1 : 0;
    }
    if (($c->{provider} // '') eq 'openrouter') {
        my $ids = $in{or_ids};
        return 0 unless ref $ids eq 'HASH' && $ids->{$d};   # must be in the OpenRouter models list
        my $h = ($in{health} || {})->{ $c->{health} // '' };
        return 0 if $h && ($h->{state} // '') eq 'open';
    }
    return 1;
}

# pure: candidate order. thrash: Super Grok first; $ caps: free first, then Super Grok, then Ollama.
# $ caps + Super Grok daily budget left: grok-4.7 first (proposal #34a, eval report 35).
# pure: candidate hashes for the configured Hermes chain (data/ai_model_chains.json hermes_fallback_chain,
# then hermes_emergency_chain). Free/local steps reuse the vetted @CANDIDATES entries; the paid step is
# built here and flagged paid => 1 (candidate_ok then needs paid_ok = room under the OpenRouter caps).
sub chain_candidates {
    my (%in) = @_;
    my $all = $in{candidates} || \@CANDIDATES;
    my $find = sub {
        my ($prov, $model) = @_;
        for my $c (@$all) { return {%$c} if ($c->{provider} // '') eq $prov && ($c->{default} // '') eq $model }
        return undef;
    };
    my (@main, %seen);
    for my $st (@{ $in{chain} || [] }, @{ $in{emergency} || [] }) {
        my ($t, $prov, $m) = ($st->{tier}, $st->{provider}, $st->{model});
        my $cand;
        if ($t eq 'supergrok') { $cand = { %SUPERGROK_CAPS, default => $m, name => "xai-oauth/$m" } }
        elsif ($t eq 'paid')   {
            next if is_or_grok($prov, $m) || $m =~ /glm/i || $m =~ $BANNED_RE;
            $cand = { name => "openrouter/$m", provider => 'openrouter', default => $m, base_url => 'https://openrouter.ai/api/v1',
                      api_mode => 'chat_completions', health => "openrouter|$m", paid => 1 };
        }
        elsif ($t eq 'local')  { $cand = $find->('ollama-launch', $m) || { name => "ollama-launch/$m", provider => 'ollama-launch', default => $m,
                      base_url => 'http://127.0.0.1:11434/v1', api_mode => 'chat_completions', ollama => $m, free => 1 } }
        else                   { $cand = $find->($prov, $m) || { name => "$prov/$m", provider => $prov, default => $m,
                      base_url => 'https://openrouter.ai/api/v1', api_mode => 'chat_completions', health => "$prov|$m", free => 1 } }
        next if $seen{ $cand->{name} }++;
        push @main, $cand;
    }
    # anything in @CANDIDATES the chain did not name stays as a last-resort tail
    for my $c (@$all) { push @main, {%$c} unless $seen{ $c->{name} }++ }
    return @main;
}

sub candidate_order {
    my ($kind, $cands, $sg, %opt) = @_;
    if (ref $opt{chain} eq 'ARRAY' && @{ $opt{chain} } && ($kind // 'thrash') eq 'caps') {
        return chain_candidates(candidates => $cands, chain => $opt{chain}, emergency => $opt{emergency});
    }
    my @c  = @{ $cands || \@CANDIDATES };
    my @or = grep { !$_->{ollama} } @c;
    my @ol = grep {  $_->{ollama} } @c;
    if (($kind // 'thrash') eq 'caps') {
        return ({%SUPERGROK_CAPS}, @or, {%SUPERGROK}, @ol) if supergrok_budget_left($sg);
        # 2026-10-17: no Super Grok budget -> free models only (north-mini first);
        # never fall onto Super Grok the daily guard has ruled out.
        return (@or, @ol);
    }
    return ({%SUPERGROK}, @or, @ol);
}

# pure: first usable candidate for this trip kind, or undef (pause).
sub pick_target {
    my (%in) = @_;
    for my $c (candidate_order($in{kind}, $in{candidates}, $in{supergrok}, chain => $in{chain}, emergency => $in{emergency})) {
        return { %$c } if candidate_ok($c, %in);
    }
    return undef;
}

# pure: permanent fallback chain: Super Grok, validated :free OpenRouter, then Ollama.
sub fallback_chain {
    my (%in) = @_;
    my @out;
    # Oct 26: with a configured Hermes chain the fallback list is Super Grok build, then the chain's
    # non-Super-Grok steps in order (paid qwen only inside the caps, north-mini last), then the emergency tail.
    my @order = (ref $in{chain} eq 'ARRAY' && @{ $in{chain} })
        ? ({%SUPERGROK}, grep { !$_->{sg_budget} } chain_candidates(chain => [ grep { $_->{tier} ne 'supergrok' } @{ $in{chain} } ], emergency => $in{emergency}))
        : ({%SUPERGROK}, @CANDIDATES);
    for my $c (@order) {
        my $ok = $c->{ollama}
            ? (ollama_ctx_ok($c->{ollama}, $in{ollama_ctx})
               && (!defined $in{ollama_models} || candidate_ok($c, %in)))   # ollama down now != gone
            : candidate_ok($c, %in);
        push @out, { provider => $c->{provider}, model => $c->{default} } if $ok;
    }
    @out = ({ provider => 'ollama-launch', model => 'gemma4-64k:latest' }) unless @out;
    return \@out;
}

# pure: does the current fallback_providers list contain a banned / invalid / double-prefixed id?
sub fallback_bad {
    my (%in) = @_;
    my $ids = $in{or_ids};
    my @bad;
    for my $e (@{ $in{current} || [] }) {
        my ($p, $m) = ($e->{provider} // '', $e->{model} // '');
        if ($m =~ $BANNED_RE)                          { push @bad, "$p/$m banned"; next }
        if (normalize_model_id($p, $m) ne $m)          { push @bad, "$p/$m double-prefixed"; next }
        if ($p eq 'openrouter' && ref $ids eq 'HASH' && !$ids->{$m}) { push @bad, "$p/$m not an OpenRouter model id"; next }
        if ($p =~ /^(?:ollama|ollama-launch)/ && exists $in{ollama_ctx} && !ollama_ctx_ok($m, $in{ollama_ctx})) {
            push @bad, "$p/$m context below $HERMES_MIN_CTX"; next;
        }
    }
    return \@bad;
}

# pure: auxiliary.<task> entries on OpenRouter must use a valid :free id (else provider auto,
# which follows main + the safe fallback chain). Returns { task => { provider, model } } to set.
sub aux_plan {
    my (%in) = @_;
    my $ids = $in{or_ids};
    my ($free) = map { $_->{default} } grep { !$_->{ollama} && candidate_ok($_, %in) } @CANDIDATES;
    my %set;
    for my $t (sort keys %{ $in{auxiliary} || {} }) {
        my $e = $in{auxiliary}{$t};
        next unless ($e->{provider} // '') eq 'openrouter';
        my $m = $e->{model} // '';
        next unless length $m;
        my $nm = normalize_model_id('openrouter', $m);
        my $good = $nm eq $m && $m =~ /:free\z/ && $m !~ $BANNED_RE && (ref $ids ne 'HASH' || $ids->{$m});
        next if $good;
        $set{$t} = $free ? { provider => 'openrouter', model => $free } : { provider => 'auto', model => '' };
    }
    return \%set;
}

# pure: everything a trip would write.
sub build_trip_plan {
    my (%in) = @_;
    my $kind   = trip_kind($in{reasons});
    my $target = pick_target(%in, kind => $kind);
    my $paused = $target ? 0 : 1;
    $target ||= { %{ (grep { $_->{ollama} } @CANDIDATES)[0] }, placeholder => 1 };
    return {
        kind => $kind, target => $target, paused => $paused,
        model     => { map { ($_ => $target->{$_}) } @MODEL_KEYS },
        aliases   => alias_rewrite_plan(aliases => $in{aliases}, safe => alias_value($target)),
        fallback  => fallback_chain(%in),
        auxiliary => aux_plan(%in),
    };
}

# pure: saved model, cleaned for restore (normalized; banned -> Super Grok, else first usable).
sub clean_saved_model {
    my (%in) = @_;
    my $m = { %{ $in{saved_model} || {} } };
    return $m unless defined $m->{default} && length $m->{default};
    $m->{default} = normalize_model_id($m->{provider}, $m->{default});
    if ($m->{default} =~ $BANNED_RE) {
        my $t = pick_target(%in, kind => 'thrash') || { %SUPERGROK };
        $m = { map { ($_ => $t->{$_}) } @MODEL_KEYS };
        $m->{replaced_banned} = 1;
    }
    return $m;
}

# pure: saved aliases, cleaned for restore (normalized; banned -> Super Grok coding SKU).
sub clean_saved_aliases {
    my ($saved) = @_;
    my %out;
    for my $a (keys %{ $saved || {} }) {
        my $v = normalize_alias($saved->{$a});
        $v = alias_value(\%SUPERGROK) if defined $v && $v =~ $BANNED_RE;
        $out{$a} = $v;
    }
    return \%out;
}

# pure: is today's PT day locked off Super Grok by supergrok_daily_guard.py
# (the single owner of the daily Super Grok switch, Oct 9 2026)?
sub supergrok_daily_off {
    my ($sg, $now) = @_;
    return 0 unless ref $sg eq 'HASH' && $sg->{off_today} && ($sg->{mode} // 'grok') ne 'grok';
    # Oct 11 2026: the lock lasts for the WORK day (starts day_start_hour PT, default 5).
    my $h = (defined $sg->{day_start_hour} && $sg->{day_start_hour} =~ /^\d+$/) ? $sg->{day_start_hour} : 5;
    my $today = do { local $ENV{TZ} = 'America/Vancouver'; POSIX::tzset(); my $d = POSIX::strftime('%Y-%m-%d', localtime(($now // time) - $h * 3600)); $d };
    POSIX::tzset();
    return (($sg->{lock_date} // '') eq $today) ? 1 : 0;
}

# pure: the daily guard's cheap model (from its state file), never banned.
sub supergrok_daily_target {
    my ($sg) = @_;
    my $m = { provider => $sg->{switch_provider} || 'openrouter', default => $sg->{switch_model} || 'cohere/north-mini-code:free',
              base_url => $sg->{switch_base_url} || 'https://openrouter.ai/api/v1', api_mode => $sg->{switch_api_mode} || 'chat_completions' };
    $m->{default} = 'cohere/north-mini-code:free' if $m->{default} =~ $BANNED_RE || $m->{default} =~ /glm/i;   # Oct 13: glm removed
    return $m;
}

# pure: everything a restore would write.
sub build_restore_plan {
    my (%in) = @_;
    my $st   = $in{state} || {};
    my $want = clean_saved_model(%in, saved_model => $st->{saved_model});
    # Daily Super Grok lock today: a restore must not bring grok back before the
    # next PT day (or a manual override, which clears the daily guard's lock).
    my $daily_off = (($want->{provider} // '') =~ /^(?:xai-oauth|xai|supergrok)$/ && supergrok_daily_off($in{supergrok}, $in{now})) ? 1 : 0;
    $want = { %{ supergrok_daily_target($in{supergrok}) }, daily_lock => 1 } if $daily_off;
    my $dec  = restore_model_decision(current_default => ($in{current_model} || {})->{default},
                                      target => $st->{target_default} // $st->{target},
                                      saved_model => $want);
    return {
        decision  => $dec,
        model     => $dec->{restore_default} ? { map { ($_ => $want->{$_}) } grep { defined $want->{$_} } @MODEL_KEYS } : undef,
        aliases   => do {
            my $al = clean_saved_aliases($st->{saved_aliases});
            if ($daily_off) {
                my $cheap = "$want->{provider}/$want->{default}";
                $al->{$_} = $cheap for grep { exists $al->{$_} } qw(code coder);
            }
            $al;
        },
        daily_lock => $daily_off,
        fallback  => fallback_chain(%in),
        auxiliary => aux_plan(%in),
    };
}

# die before writing anything invalid (belt and braces).
sub assert_safe_model {
    my ($m) = @_;
    my $d = $m->{default} // '';
    die "refusing to write banned model $d\n" if $d =~ $BANNED_RE;
    die "refusing to write double-prefixed model $m->{provider}/$d\n"
        if defined $m->{provider} && normalize_model_id($m->{provider}, $d) ne $d;
    return 1;
}

# pure: is (provider, model) an OpenRouter grok?
sub is_or_grok {
    my ($provider, $model) = @_;
    $provider //= ''; $model //= '';
    return 0 unless length $model;
    return 1 if $model =~ $OR_GROK_RE;
    return 1 if $provider eq 'openrouter' && $model =~ /grok/i;
    return 0;
}

# pure: Super Grok usable right now (supergrok_daily_guard state: mode grok, no hard cap).
sub supergrok_open {
    my ($sg) = @_;
    return 0 unless ref $sg eq 'HASH' && %$sg;
    return 0 if $sg->{hard_cap} || ($sg->{mode} // '') ne 'grok';
    return 1;
}

# pure: replacement {provider, default} for an OpenRouter grok id.
sub or_grok_replacement {
    my ($model, $sg) = @_;
    (my $bare = bare_model_id($model // '')) =~ s{^~?x-ai/}{};
    $bare =~ s/:.*\z//;
    return { %$FREE_SAFE } unless supergrok_open($sg) && $bare =~ /^grok[\w.-]*\z/;
    return { %SUPERGROK, default => $bare };
}

# pure: alias value with any OpenRouter grok rewritten.
sub fix_alias_value {
    my ($v, $sg) = @_;
    return $v unless defined $v && $v =~ m{^([^/]+)/(.+)$};
    return $v unless is_or_grok($1, $2) || is_or_grok('', $v);
    return alias_value(or_grok_replacement($2, $sg));
}

# pure: what the per-run block would rewrite. in: current_model, aliases, current_fallback,
# auxiliary, delegation, supergrok. out: { model, aliases, fallback, auxiliary, delegation, why }.
sub or_grok_block_plan {
    my (%c) = @_;
    my $sg = $c{supergrok};
    my (%out, @why);
    my $cm = $c{current_model} || {};
    if (is_or_grok($cm->{provider}, $cm->{default})) {
        my $r = or_grok_replacement($cm->{default}, $sg);
        $out{model} = { map { ($_ => $r->{$_}) } @MODEL_KEYS };
        push @why, "model $cm->{provider}/$cm->{default} -> $r->{provider}/$r->{default}";
    }
    my %al;
    for my $a (sort keys %{ $c{aliases} || {} }) {
        my $v = $c{aliases}{$a}; my $n = fix_alias_value($v, $sg);
        next if !defined $v || $n eq $v;
        $al{$a} = $n; push @why, "alias $a $v -> $n";
    }
    $out{aliases} = \%al if %al;
    my $fb = $c{current_fallback} || [];
    if (grep { is_or_grok($_->{provider}, $_->{model}) } @$fb) {
        my (@n, %seen);
        for my $e (@$fb) {
            my $x = is_or_grok($e->{provider}, $e->{model})
                ? do { my $r = or_grok_replacement($e->{model}, $sg); { provider => $r->{provider}, model => $r->{default} } } : $e;
            push @n, $x unless $seen{"$x->{provider}/$x->{model}"}++;
        }
        $out{fallback} = \@n; push @why, 'fallback had OpenRouter grok';
    }
    my %ax;
    for my $t (sort keys %{ $c{auxiliary} || {} }) {
        my $e = $c{auxiliary}{$t};
        next unless is_or_grok($e->{provider}, $e->{model});
        $ax{$t} = { provider => $FREE_SAFE->{provider}, model => $FREE_SAFE->{default} };
        push @why, "auxiliary $t $e->{provider}/$e->{model} -> north-mini";
    }
    $out{auxiliary} = \%ax if %ax;
    my $dl = $c{delegation} || {};
    if (is_or_grok($dl->{provider}, $dl->{model})) {
        $out{delegation} = { provider => $FREE_SAFE->{provider}, model => $FREE_SAFE->{default} };
        push @why, "delegation $dl->{model} -> north-mini";
    }
    $out{why} = \@why;
    return \%out;
}

# Aliases that must not point at paid coding models while tripped.
our @DANGEROUS_ALIASES = qw(code coder code-paid flash delegate hy3);   # Oct 13: glm alias removed
# Already-safe aliases we never rewrite.
our @SAFE_ALIAS_KEEP = qw(cheap director local xai git reasoner editor deepseek);

# pure: which aliases to rewrite to $safe (full openrouter/...:free or ollama slug).
# Returns { set => {alias=>new}, saved => {alias=>old_value} }.
sub alias_rewrite_plan {
    my (%in) = @_;
    my $cur  = $in{aliases} || {};
    my $safe = $in{safe} || alias_value({%SUPERGROK});
    my (%set, %saved);
    my %seen;
    my @check = grep { !$seen{$_}++ } @{ $in{dangerous} || \@DANGEROUS_ALIASES },
        grep { ($cur->{$_} // '') =~ $BANNED_RE } sort keys %$cur;
    for my $a (@check) {
        my $v = $cur->{$a};
        next unless defined $v && length $v;
        next if $v eq $safe;
        next if ($v =~ /:free\z/ || $v =~ /^ollama/ || $v =~ m{^xai-oauth/}) && $v !~ $BANNED_RE;
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
    if (defined $cur && defined $target && length $cur && length $target
        && bare_model_id($cur) ne bare_model_id($target)) {
        return { restore_default => 0, reason => 'manual_default_preserved', current => $cur, target => $target, saved => $saved_d };
    }
    return { restore_default => 1, reason => 'restore_saved', saved => $saved_d };
}

# ---- live OpenRouter estimate (agent.log parse for ~1min day cap response) ----
# pure
sub parse_api_calls {
    my ($text, $since_epoch, %opt) = @_;
    return [] unless defined $text;
    my $want_all = $opt{all};
    my @lines = split /\n/, $text;
    # Hermes processes write agent.log in DIFFERENT zones (TUI/agent lines in UTC, CLI /
    # dashboard lines in local time, interleaved - seen Oct 7 2026). With an anchor (the
    # file mtime) walk backwards and give each timestamped line the reading (UTC or
    # local) closest to the line after it; lines are appended in real time.
    my %epoch_of;
    if (defined $opt{anchor}) {
        # Local readings are in the workstation's zone, not the process zone:
        # Comserv.pm sets TZ=UTC inside the app, which made both readings equal.
        local $ENV{TZ} = $opt{tz} // $ENV{HERMES_LOG_TZ} // 'America/Vancouver';
        POSIX::tzset();
        my $ref = $opt{anchor};
        for my $i (reverse 0 .. $#lines) {
            next unless $lines[$i] =~ /^(\d{4})-(\d{2})-(\d{2})\s+(\d{2}):(\d{2}):(\d{2})/;
            my @tm = ($6, $5, $4, $3, $2 - 1, $1);
            my $u = eval { timegm(@tm) };
            my $l = eval { timelocal(@tm) };
            next unless defined $u;
            my $pick = $u;
            if (defined $l && $l != $u) {
                my ($du, $dl) = (abs($ref - $u), abs($ref - $l));
                if ($du > 7200 && $dl > 7200) {          # long gap: time must not run forwards
                    my @ok = grep { $_ <= $ref + 120 } ($u, $l);
                    $pick = @ok ? (sort { $b <=> $a } @ok)[0] : ($u < $l ? $u : $l);
                } else {
                    $pick = $dl < $du ? $l : $u;
                }
            }
            $epoch_of{$i} = $pick;
            $ref = $pick;
        }
    }
    POSIX::tzset();   # back to the caller's zone (local TZ restored on block exit)
    my @out;
    for my $li (0 .. $#lines) {
        my $line = $lines[$li];
        next unless $line =~ /provider=\S+/;
        # 2026-10-06 16:12:40,123 INFO [sess] ... model=... provider=XXX in=.. out=.. [cache=..] [upstream=..]
        if ($line =~ m{^(\d{4})-(\d{2})-(\d{2})\s+(\d{2}):(\d{2}):(\d{2}),\d+\s+\w+\s+\[([^\]]+)\].*?model=(\S+)\s+provider=(\S+)\s+in=(\d+)\s+out=(\d+)}) {
            my ($y, $mo, $d, $H, $M, $S, $sess, $model, $prov, $in, $out) = ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11);
            my ($cache) = $line =~ m{\bcache=(\d+)/\d+};
            my ($up)    = $line =~ m{\bupstream=(\S+)};
            my $t = $epoch_of{$li} // timegm($S, $M, $H, $d, $mo-1, $y);
            next if defined $since_epoch && $t < $since_epoch;
            if (!$want_all && $prov ne 'openrouter') { next; }
            push @out, {
                t => $t,
                session => $sess,
                model => $model,
                provider => $prov,
                in => 0 + $in,
                out => 0 + $out,
                cache => defined $cache ? 0 + $cache : 0,
                upstream => $up,
            };
        }
    }
    return \@out;
}

# pure
sub price_call {
    my ($call, $endpoints) = @_;
    return undef unless ref $call eq 'HASH' && ($call->{provider} // '') eq 'openrouter';
    my $model = $call->{model};
    return 0 if defined $model && $model =~ /:free$/;
    return undef unless ref $endpoints eq 'HASH' && ref $endpoints->{$model} eq 'HASH';
    my $eps = $endpoints->{$model};
    return undef unless %$eps;
    my $up = lc( $call->{upstream} // '' );
    my $p;
    # agent.log 'upstream=' is the first word of the provider name ('Sail' for 'Sail Research')
    my ($pk) = $up ? (exists $eps->{$up} ? ($up) : grep { index($_, "$up ") == 0 } sort keys %$eps) : ();
    if (defined $pk) {
        $p = $eps->{$pk};
    } else {
        # most expensive by prompt (conservative)
        my $maxp = -1;
        for my $k (keys %$eps) {
            my $pp = $eps->{$k}[0] // 0;
            if ($pp > $maxp) { $maxp = $pp; $p = $eps->{$k}; }
        }
    }
    return undef unless ref $p eq 'ARRAY';
    my ($prompt, $completion, $cache_read) = @$p;
    my $in = $call->{in} // 0;
    my $out = $call->{out} // 0;
    my $cache = $call->{cache} // 0;
    my $cst;
    if (defined $call->{upstream} && $call->{upstream} =~ /Relace/i) {
        $cst = ($in - $cache) * $prompt + $cache * $prompt + $out * $completion;
    } else {
        $cst = ($in - $cache) * $prompt + $cache * ($cache_read // $prompt) + $out * $completion;
    }
    return $cst;
}

# IO: fetch per-model endpoints pricing, cache all in shared json w/ per-model fetched_at
sub openrouter_endpoints {
    my ($s, $model) = @_;
    return undef unless defined $model && length $model;
    if (ref $s->{or_endpoints} eq 'HASH' && exists $s->{or_endpoints}{$model}) {
        return $s->{or_endpoints}{$model};
    }
    my $f = "$s->{hermes_home}/cache/overrun_guard_or_endpoints.json";
    my $c = eval { open my $fh, '<', $f or die; local $/; $J->decode(<$fh>) } || {};
    my $now = $s->_now;
    my $mrec = $c->{models}{$model} || {};
    my $age = $mrec->{fetched_at} ? $now - $mrec->{fetched_at} : 9e9;
    if ($age < $OR_CACHE_TTL && ref $mrec->{endpoints} eq 'HASH') {
        return $mrec->{endpoints};
    }
    my $menc = $model;
    $menc =~ s{([^A-Za-z0-9_.\-/:~])}{sprintf '%%%02X', ord($1)}ge;   # keep '/' (vendor/model path)
    my $url = "https://openrouter.ai/api/v1/models/$menc/endpoints";
    my $r = HTTP::Tiny->new(timeout => 15)->get($url);
    my $eps;
    if ($r->{success}) {
        my $d = eval { $J->decode($r->{content}) } || {};
        if (ref $d->{data} eq 'HASH' && ref $d->{data}{endpoints} eq 'ARRAY') {
            $eps = {};
            for my $e (@{ $d->{data}{endpoints} || [] }) {
                next unless ref $e eq 'HASH';
                my $pn = lc($e->{provider_name} // '');
                next unless length $pn;
                my $pr = $e->{pricing} || {};
                my $prompt = 0 + ($pr->{prompt} // 0);
                my $comp   = 0 + ($pr->{completion} // 0);
                my $cr     = defined($pr->{input_cache_read}) ? 0 + $pr->{input_cache_read} : undef;
                $eps->{$pn} = [ $prompt, $comp, $cr ];
            }
        }
    }
    if (ref $eps eq 'HASH' && %$eps) {
        if (!$s->{dry_run}) {
            (my $dir = $f) =~ s{/[^/]+$}{};
            mkdir $dir unless -d $dir;
            my $cd = $c || {}; $cd->{models} ||= {};
            $cd->{models}{$model} = { fetched_at => $now, fetched_at_pt => pt($now), endpoints => $eps, url => $url };
            eval { _atomic_write($f, $J->encode($cd)) };
        }
        return $eps;
    }
    # stale on failure
    if ($age < $OR_CACHE_STALE && ref $mrec->{endpoints} eq 'HASH') {
        return $mrec->{endpoints};
    }
    return {};
}

# IO
sub live_spend {
    my ($self, %a) = @_;
    my $after = $a{after};
    my $after_usd = 0;
    my $logf = $self->{agent_log};
    return { ok => 0 } unless $logf && -f $logf;
    open my $fh, '<', $logf or return { ok => 0 };
    local $/; my $text = <$fh>; close $fh;
    my $now = $self->_now;
    my ($sec,$min,$hr,$md,$mo,$yr) = gmtime($now);
    my $since = timegm(0,0,0, $md, $mo, $yr);
    my $calls = [ grep { $_->{t} <= $now } @{ parse_api_calls($text, $since, all => 1, anchor => ((stat $logf)[9] // $now)) } ];
    my %by;
    my (%chan, %recent);   # Oct 26: cash per billing system; sessions active in the last 10 min
    my $usd = 0;
    my $unp = 0;
    my ($last_v4, $last_watch);
    my %epc; # model -> eps
    for my $c (@$calls) {
        my $m = $c->{model} // '';
        next unless $m;
        next if $self->{trial_models} && $self->{trial_models}{$m};   # approved trial model: not part of the caps (see run)
        my $ch = billing_channel($c->{provider}, $m);
        if ($ch ne 'openrouter') {
            # not billed by OpenRouter: counted per channel (x.ai direct = flat unpriced estimate), never in the OpenRouter dollars
            my $est = $ch eq 'xai_direct' ? ($c->{in} // 0) * $UNPRICED_IN + ($c->{out} // 0) * $UNPRICED_OUT : 0;
            $chan{$ch} ||= { calls => 0, usd => 0 }; $chan{$ch}{calls}++; $chan{$ch}{usd} += $est;
            if ($now - $c->{t} < 600) {
                my $k = join "\0", $c->{session} // '?', $c->{provider}, $m;
                my $r = $recent{$k} ||= { session => $c->{session}, provider => $c->{provider}, model => $m, calls => 0, usd => 0, last_t => 0 };
                $r->{calls}++; $r->{usd} += $est; $r->{last_t} = $c->{t} if $c->{t} > $r->{last_t};
            }
            next;
        }
        if (!exists $epc{$m}) {
            $epc{$m} = $self->openrouter_endpoints($m) || {};
        }
        my $cost = price_call($c, { $m => $epc{$m} });
        $by{$m} ||= { calls => 0, usd => 0 };
        $by{$m}{calls}++;
        if (!defined $cost) {
            # no endpoint pricing (network down, new model): conservative flat rate, never $0
            $unp++;
            $cost = ($c->{in} // 0) * $UNPRICED_IN + ($c->{out} // 0) * $UNPRICED_OUT;
        }
        $usd += $cost; $by{$m}{usd} += $cost;
        $chan{openrouter} ||= { calls => 0, usd => 0 }; $chan{openrouter}{calls}++; $chan{openrouter}{usd} += $cost;
        if ($now - $c->{t} < 600) {
            my $k = join "\0", $c->{session} // '?', $c->{provider}, $m;
            my $r = $recent{$k} ||= { session => $c->{session}, provider => $c->{provider}, model => $m, calls => 0, usd => 0, last_t => 0 };
            $r->{calls}++; $r->{usd} += $cost; $r->{last_t} = $c->{t} if $c->{t} > $r->{last_t};
        }
        $after_usd += $cost if defined $after && defined $c->{t} && $c->{t} > $after;
        if ($m =~ $PAID_WATCH_RE) {
            if (!defined $last_v4 || $c->{t} > $last_v4) { $last_v4 = $c->{t}; $last_watch = $m }
        }
    }
    return {
        ok => 1,
        day_usd => $usd,
        (defined $after ? (after_usd => $after_usd, after => $after) : ()),
        calls => ($chan{openrouter} ? $chan{openrouter}{calls} : 0),
        unpriced => $unp,
        by_model => \%by,
        last_v4pro_at => $last_v4,          # last call to any @PAID_WATCH model (name kept for compat)
        last_watch_model => $last_watch,
        by_channel => \%chan,            # { openrouter|xai_direct|supergrok|ollama => { calls, usd } } today (UTC day)
        recent     => \%recent,          # sessions with a call in the last 10 min: provider, model, calls, usd
    };
}

# pure: an OpenRouter reading older than $max (default 1h) is not trusted: its day/week
# are dropped so the guard runs on the live estimate only (no stale week + live double count).
our $SNAPSHOT_MAX_AGE = 3600;
sub stale_guard {
    my ($or, $now, $max) = @_;
    return $or unless ref $or eq 'HASH' && $or->{ok};
    $max //= $SNAPSHOT_MAX_AGE;
    my $age = $or->{fetched_at} ? $now - $or->{fetched_at} : undef;
    return $or if !defined $age || $age <= $max;   # no fetched_at: caller-supplied/unknown age, trust as before
    return { ok => 0, stale => 1, error => sprintf('openrouter reading stale (%dm old)', $age/60),
             (defined $or->{balance_usd} ? (balance_usd => $or->{balance_usd}) : ()) };
}

# pure
sub merge_live {
    my ($or, $live) = @_;
    $or ||= {};
    my %out = %$or;
    if (ref $live eq 'HASH' && $live->{ok} && $or->{ok} && !$or->{stale}
        && defined $live->{after_usd} && defined $or->{fetched_at}
        && defined $live->{after} && $live->{after} == $or->{fetched_at}) {
        # Oct 22: fresh /auth/key reading already includes everything up to fetched_at;
        # add only the estimate for calls made after it (no double count).
        # Oct 23 (Shanta 6:57 AM PT): a fresh (<1 h) /auth/key reading is used as-is; the
        # agent.log estimate is only a fallback when the live reading is missing or stale.
        my $add = 0;
        $out{reported_day_usd} = $or->{day_usd};
        $out{day_usd} = ($or->{day_usd} // 0) + $add;
        $out{week_usd} += $add if defined $out{week_usd};
        $out{month_usd} += $add if defined $out{month_usd};
        $out{live_day_usd} = $live->{day_usd};
        $out{live_after_usd} = $live->{after_usd};
        $out{live_applied} = 1 if $add > 0;
        return \%out;
    }
    if (ref $live eq 'HASH' && $live->{ok}) {
        my $l_day = $live->{day_usd} // 0;
        my $r_day = $or->{day_usd};
        if (!defined $r_day || $l_day > $r_day) {
            my $delta = $l_day - ($r_day // 0);
            $out{day_usd} = $l_day;
            $out{week_usd} += $delta if defined $out{week_usd} && $delta > 0;
            $out{month_usd} += $delta if defined $out{month_usd} && $delta > 0;
            $out{live_day_usd} = $l_day;
            $out{live_applied} = 1;
        }
        if (!$or->{ok}) {
            return { ok => 1, day_usd => $l_day, live_only => 1, live_day_usd => $l_day };
        }
    }
    if (defined $or->{day_usd}) {
        $out{reported_day_usd} = $or->{day_usd};
    }
    return \%out;
}

# ---- inputs ----------------------------------------------------------------
# Super Grok (flat-rate) calls never count toward thrash (eval proposal 3, Oct 7 2026).
sub thrash_count {
    my ($self) = @_;
    return undef unless -f $self->{state_db};
    my $n = eval {
        require DBI;
        my $dbh = DBI->connect("dbi:SQLite:dbname=$self->{state_db}", '', '',
            { RaiseError => 1, PrintError => 0, sqlite_open_flags => 1 }); # SQLITE_OPEN_READONLY
        my $since = $self->_now - $THRASH_WINDOW;
        my @tm = sort keys %{ $self->{trial_models} || {} };   # Oct 26: active approved trial models are not thrash
        my $not_trial = @tm ? ' AND COALESCE(s.model, \'\') NOT IN (' . join(',', ('?') x @tm) . ')' : '';
        my ($c) = $dbh->selectrow_array(
            q{SELECT COUNT(*) FROM messages m LEFT JOIN sessions s ON s.id = m.session_id
              WHERE m.role = 'assistant' AND m.timestamp > ?
                AND COALESCE(s.billing_provider, '') NOT IN ('xai-oauth', 'xai', 'supergrok')
                AND COALESCE(s.model, '') NOT LIKE 'grok-%'} . $not_trial, undef, $since, @tm);
        $dbh->disconnect;
        $c;
    };
    return $n;
}

# IO: per-provider thrash counts from agent.log (actual API calls, not session.current model)
sub thrash_by_class {
    my ($self) = @_;
    my $logf = $self->{agent_log};
    return { ok => 0 } unless $logf && -f $logf;
    open my $fh, '<', $logf or return { ok => 0 };
    local $/; my $text = <$fh>; close $fh;
    my $now = $self->_now;
    my $since = $now - $THRASH_WINDOW;
    my $calls = parse_api_calls($text, $since, all => 1, anchor => ((stat $logf)[9] // $now));
    my %counts;
    my $total = 0;
    for my $c (@$calls) {
        next unless defined $c->{t} && $c->{t} > $since && $c->{t} <= $now;
        # Oct 26 2026: an ACTIVE approved trial model (see trial_exclusions; stopped trials count again) is not thrash
        next if $self->{trial_models} && $self->{trial_models}{ $c->{model} // '' };
        my $cl = classify_call($c);
        $counts{$cl}++;
        $total++;
    }
    return { ok => 1, counts => \%counts, total => $total };
}

# optional override: $hermes_home/overrun_guard_limits.json { "thrash_per_15min": { "supergrok":150, ... } }
# merges over defaults; bad json -> defaults + log_line
sub thrash_limits {
    my ($self) = @_;
    my %lims = %THRASH_LIMITS;
    my $f = "$self->{hermes_home}/overrun_guard_limits.json";
    if (-f $f) {
        my $ok = eval {
            open my $fh, '<', $f or die "open: $!";
            local $/; my $txt = <$fh>; close $fh;
            my $j = $J->decode($txt);
            if (ref $j eq 'HASH' && ref $j->{thrash_per_15min} eq 'HASH') {
                my $o = $j->{thrash_per_15min};
                $lims{$_} = $o->{$_} for keys %$o;
            }
            1;
        };
        if (!$ok || $@) {
            $self->log_line("overrun_guard_limits.json unreadable or bad JSON, using defaults: " . ($@ || ''));
        }
    }
    return \%lims;
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

# { model => effective num_ctx } for installed Ollama models (via /api/show). undef if Ollama is down.
sub ollama_ctx_map {
    my ($self) = @_;
    return $self->{_ctx_map} if exists $self->{_ctx_map};
    my $models = $self->ollama_models;
    return $self->{_ctx_map} = undef unless ref $models eq 'ARRAY';
    my $http = HTTP::Tiny->new(timeout => 6);
    my %m;
    for my $name (@$models) {
        my $r = $http->post("$self->{ollama_url}/api/show",
            { headers => { 'Content-Type' => 'application/json' }, content => $J->encode({ model => $name }) });
        next unless $r->{success};
        my $d = eval { $J->decode($r->{content}) } or next;
        my ($n) = ($d->{parameters} // '') =~ /^\s*num_ctx\s+(\d+)/m;
        $m{$name} = $n // ($ENV{OLLAMA_CONTEXT_LENGTH} || 4096);
    }
    return $self->{_ctx_map} = \%m;
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
    # Oct 22: per-process tmp name so servers never clobber each other's half-written file; rename is atomic.
    my $tmp = "$s->{state_file}.tmp.$$";
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
        my $v = fix_alias_value($map->{$a}, $s->supergrok_state);   # never write an OpenRouter grok
        die "refusing banned alias $a=$v\n" if $v =~ $BANNED_RE;
        $s->config_set("model.aliases.$a", $v);
        push @done, "$a=$v";
    }
    return \@done;
}


# Generic `hermes config set` (or the test callback).
sub config_set {
    my ($s, $k, $v) = @_;
    if ($s->{set_cb}) { $s->{set_cb}->($k, $v); return 1 }
    system($s->{hermes_bin}, 'config', 'set', $k, $v) == 0 or die "hermes config set $k failed\n";
    return 1;
}

sub _atomic_write {
    my ($f, $content) = @_;
    my $mode = (stat $f)[2];
    my $tmp = "$f.overrun-tmp.$$";
    open my $fh, '>', $tmp or die "write $tmp: $!\n";
    print $fh $content; close $fh or die "close $tmp: $!\n";
    chmod($mode & 07777, $tmp) if defined $mode;
    rename $tmp, $f or die "rename $tmp: $!\n";
}

# OpenRouter model ids (hashref) from https://openrouter.ai/api/v1/models, cached
# $OR_CACHE_TTL in ~/.hermes/cache; stale cache (< 7 days) if the fetch fails; undef if none.
sub openrouter_model_ids {
    my ($s) = @_;
    return $s->{or_ids} if exists $s->{or_ids};   # tests / callers inject
    my $f = $s->{or_cache};
    my $c = eval { open my $fh, '<', $f or die; local $/; $J->decode(<$fh>) };
    my $age = $c && $c->{at} ? $s->_now - $c->{at} : 9e9;
    my $ids = sub { +{ map { ($_ => 1) } @{ $_[0] } } };
    return $ids->($c->{ids}) if $c && ref $c->{ids} eq 'ARRAY' && @{ $c->{ids} } && $age < $OR_CACHE_TTL;
    my $r = HTTP::Tiny->new(timeout => 20)->get($OR_MODELS_URL);
    if ($r->{success}) {
        my $d = eval { $J->decode($r->{content}) } || {};
        my @list = map { $_->{id} } grep { ref $_ eq 'HASH' && $_->{id} } @{ $d->{data} || [] };
        if (@list) {
            if (!$s->{dry_run}) {
                (my $dir = $f) =~ s{/[^/]+$}{};
                mkdir $dir unless -d $dir;
                eval { _atomic_write($f, $J->encode({ at => $s->_now, at_pt => pt($s->_now), url => $OR_MODELS_URL, ids => \@list })) };
            }
            return $ids->(\@list);
        }
    }
    return $ids->($c->{ids}) if $c && ref $c->{ids} eq 'ARRAY' && @{ $c->{ids} } && $age < $OR_CACHE_STALE;
    return undef;
}

sub supergrok_state {
    my ($s) = @_;
    return $s->{supergrok} if exists $s->{supergrok};
    open my $fh, '<', $s->{supergrok_state_file} or return {};
    local $/; return eval { $J->decode(<$fh>) } || {};
}

# Everything pick/plan functions need, gathered once per run.
sub context {
    my ($s) = @_;
    my $ctx = $s->ollama_ctx_map;
    return (health => $s->model_health, ollama_models => $s->ollama_models,
            (defined $ctx ? (ollama_ctx => $ctx) : ()),
            or_ids => $s->openrouter_model_ids, supergrok => $s->supergrok_state,
            $s->chain_context,
            aliases => $s->read_aliases, auxiliary => $s->read_auxiliary,
            current_model => $s->current_model, current_fallback => $s->read_fallback_providers,
            delegation => $s->read_delegation);
}

# Hermes chain + channel caps from data/ai_model_chains.json (one place); Perl defaults if missing/invalid.
sub chain_context {
    my ($s) = @_;
    my $path = $s->{chains_file} // "$s->{app_root}/data/ai_model_chains.json";
    my $ld = eval { Comserv::Util::AI::ModelChains->load(undef, path => $path, logger => sub { $s->log_line("ai_model_chains: $_[1]") }) };
    return () unless $ld;
    my @chain = Comserv::Util::AI::ModelChains->hermes_chain($ld);
    my %allowed = map { ($_->{model} => 1) } grep { $_->{tier} eq 'paid' } @chain;
    return (chain => \@chain, emergency => [ Comserv::Util::AI::ModelChains->hermes_chain($ld, emergency => 1) ],
            allowed_paid => \%allowed,
            channel_caps => { map { ($_ => Comserv::Util::AI::ModelChains->channel_caps($ld, $_)) } qw(openrouter xai_direct) },
            chain_source => $ld->{source});
}

sub read_delegation {
    my ($s) = @_;
    open my $fh, '<', $s->{config} or return {};
    my (%d, $in);
    while (my $l = <$fh>) {
        if ($l =~ /^delegation:\s*$/) { $in = 1; next }
        next unless $in;
        last if $l =~ /^\S/;
        $d{$1} = $2 if $l =~ /^  (provider|model):\s*['"]?(.*?)['"]?\s*$/;
    }
    return \%d;
}

sub read_fallback_providers {
    my ($s) = @_;
    open my $fh, '<', $s->{config} or return [];
    my (@l, $in, $cur);
    while (my $l = <$fh>) {
        if ($l =~ /^fallback_providers:\s*(?:\[\])?\s*$/) { $in = 1; next }
        next unless $in;
        last if $l =~ /^[^\s-]/;
        if ($l =~ /^\s*-\s+([A-Za-z_]+):\s*['"]?(.*?)['"]?\s*$/) { $cur = { $1 => $2 }; push @l, $cur; next }
        $cur->{$1} = $2 if $cur && $l =~ /^\s+([A-Za-z_]+):\s*['"]?(.*?)['"]?\s*$/;
    }
    return \@l;
}

# Replace the top-level fallback_providers block (text edit; rest of the file untouched).
sub write_fallback_providers {
    my ($s, $list) = @_;
    return [] unless ref $list eq 'ARRAY' && @$list;
    for (@$list) { die "refusing banned fallback $_->{model}\n" if ($_->{model} // '') =~ $BANNED_RE }
    $list = [ map { is_or_grok($_->{provider}, $_->{model})
        ? do { my $r = or_grok_replacement($_->{model}, $s->supergrok_state); +{ provider => $r->{provider}, model => $r->{default} } }
        : $_ } @$list ];
    # Hermes ~64K context floor for Ollama entries (Oct 10 2026); applies to every write,
    # including restores of saved_fallback.
    my ($kept, $dropped) = filter_ollama_ctx($list, $s->{ollama_ctx} // $s->ollama_ctx_map);
    warn 'fallback: dropped ' . join(', ', map { "$_->{provider}/$_->{model}" } @$dropped) . " (context < $HERMES_MIN_CTX)\n" if @$dropped;
    $list = $kept;
    return [] unless @$list;
    my $block = "fallback_providers:\n" . join '', map {
        "  - provider: $_->{provider}\n    model: $_->{model}\n" . ($_->{base_url} ? "    base_url: $_->{base_url}\n" : '')
    } @$list;
    open my $fh, '<', $s->{config} or die "read config: $!\n";
    my @l = <$fh>; close $fh;
    my (@out, $in, $done);
    for my $l (@l) {
        if (!$done && $l =~ /^fallback_providers:/) { push @out, $block; ($in, $done) = (1, 1); next }
        if ($in) { if ($l =~ /^[^\s-]/) { $in = 0 } else { next } }
        push @out, $l;
    }
    push @out, $block unless $done;
    _atomic_write($s->{config}, join '', @out);
    return [ map { "$_->{provider}/$_->{model}" } @$list ];
}

sub read_auxiliary {
    my ($s) = @_;
    open my $fh, '<', $s->{config} or return {};
    my (%a, $in, $task);
    while (my $l = <$fh>) {
        if ($l =~ /^auxiliary:\s*$/) { $in = 1; next }
        next unless $in;
        last if $l =~ /^\S/;
        if ($l =~ /^  ([A-Za-z0-9_-]+):\s*$/) { $task = $1; next }
        $a{$task}{$1} = $2 if $task && $l =~ /^    (provider|model):\s*['"]?(.*?)['"]?\s*$/;
    }
    return \%a;
}

sub set_auxiliary {
    my ($s, $plan) = @_;
    my @done;
    for my $t (sort keys %{ $plan || {} }) {
        for my $k (qw(provider model)) {
            $s->config_set("auxiliary.$t.$k", $plan->{$t}{$k});
        }
        push @done, "$t=$plan->{$t}{provider}/$plan->{$t}{model}";
    }
    return \@done;
}

# Self-heal on every run: bad fallback_providers / paid aux / double-prefixed default.
sub sanitize_plan {
    my (%in) = @_;
    my %p;
    my $bad = fallback_bad(current => $in{current_fallback}, or_ids => $in{or_ids},
                           (exists $in{ollama_ctx} ? (ollama_ctx => $in{ollama_ctx}) : ()));
    if (@$bad) { $p{fallback} = fallback_chain(%in); $p{fallback_why} = $bad }
    my $aux = aux_plan(%in);
    $p{auxiliary} = $aux if %$aux;
    my $m = $in{current_model} || {};
    if (defined $m->{default} && defined $m->{provider}) {
        my $n = normalize_model_id($m->{provider}, $m->{default});
        $p{model_default} = $n if $n ne $m->{default};
    }
    return \%p;
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

# Oct 22 2026 (Shanta 7:33 AM PT) "shield": old-code servers (other branches) count all of today's
# agent.log spend and re-trip to north-mini every minute. They honor tripped=1 (hold; hold leaves a
# non-grok / xai-oauth model alone), so while the money caps are really clear but those servers would
# still trip, keep tripped=1 + hold_reason=shield and let THIS code own the model:
#   Super Grok has budget -> xai-oauth grok-4.7; otherwise the daily guard's paid coder (qwen3-coder).
# saved_model = that model, so an old-code restore (after UTC midnight) writes the same thing.
# Cleared once Super Grok has budget AND the old-style all-day estimate is under the caps.
our $SHIELD = 'shield_old_servers';
sub shield_want {
    my ($sg, $now) = @_;
    return { map { ($_ => $SUPERGROK_CAPS{$_}) } @MODEL_KEYS } if supergrok_budget_left($sg);
    my $m = supergrok_daily_target($sg);
    return { map { ($_ => $m->{$_}) } @MODEL_KEYS };
}
sub old_code_would_trip {
    my ($s, $or, $live_all) = @_;
    my $m = merge_live({ %{ $or || {} } }, $live_all);
    return 0 unless $m->{ok};
    for my $w (qw(day week month)) {
        my $v = $m->{"${w}_usd"};
        return 1 if defined $v && defined $CAPS{$w} && $v >= $CAPS{$w};
    }
    return 0;
}
sub shield_step {
    my ($s, $st, $t, $or, %o) = @_;
    my $sg = $s->supergrok_state;
    # Oct 22 9:24 AM PT: hold_reason set but tripped=0 => an old-code server ran its restore, i.e. old
    # servers no longer see a cap breach. Re-raising tripped=1 only feeds their restore path, whose
    # notify-send ('cleared') is unconditional. Release the shield and stay down; re-enter only right
    # after restoring a real old-code trip.
    if (($st->{hold_reason} // '') eq $SHIELD && !$st->{tripped}) {
        delete @$st{qw(hold_reason hold_since hold_pt)};
        $st->{shield_released_at} = $t; $st->{shield_released_pt} = pt($t);
        $s->log_line('shield released ' . pt($t) . ': old servers restored (not over); not re-raising');
        $s->{shield_released} = 1;
    }
    my $grok_ok = supergrok_budget_left($sg);
    my $on = $st->{tripped} && ($st->{hold_reason} // '') eq $SHIELD;
    my $rep = exists $s->{reported_or} ? $s->{reported_or} : ($st->{last_openrouter} || {});
    my $live_all = exists $s->{live_all} ? $s->{live_all} : $s->live_spend;
    my $old_trip = $s->old_code_would_trip($rep, $live_all);
    if ($on && $grok_ok && !$old_trip) {
        delete @$st{qw(hold_reason hold_since hold_pt)};
        $st->{tripped} = 0;
        $st->{hand_off_supergrok} = 1;    # daily guard (no longer deferred) syncs aliases/fallback
        $s->log_line('shield cleared ' . pt($t) . ': Super Grok has budget and old servers would not trip');
        return { cleared => 1 };
    }
    # enter only when the daily guard has Hermes locked off grok (no daily-guard state = no shield)
    return undef unless $on || ($o{after_restore} && !$s->{shield_released} && !$grok_ok && ref $sg eq 'HASH' && %$sg);
    my $want = shield_want($sg, $t);
    my $cur  = $s->current_model || {};
    my @did;
    if (($cur->{default} // '') ne $want->{default} || ($cur->{provider} // '') ne $want->{provider}) {
        assert_safe_model($want);
        my $bak = $s->backup_config;
        $s->set_model($want);
        my %al = map { ($_ => alias_value($want)) } grep { exists(($s->read_aliases || {})->{$_}) } qw(code coder);
        $s->set_aliases(\%al) if %al;
        push @did, "model -> $want->{provider}/$want->{default} (backup " . ($bak // 'FAILED') . ')';
        _append($s->{events_file}, $J->encode({ at => $t, at_pt => pt($t), action => 'shield', to => $want->{default}, backup => $bak }));
    }
    unless ($on) { $st->{hold_since} = $t; $st->{hold_pt} = pt($t) }
    %$st = (%$st, tripped => 1, paused => 0, hold_reason => $SHIELD,
            saved_model => { %$want }, target => alias_value($want), target_default => $want->{default});
    $s->log_line('shield ' . pt($t) . ': ' . (@did ? join('; ', @did) : "holding $want->{default}")) if @did || !$on;
    $s->notify_change($st, 'normal', $want->{default}, 'Hermes on ' . $want->{default},
        "Hermes default is $want->{default} (money caps clear; Super Grok " . ($grok_ok ? 'open' : 'locked') . ').') ;
    return { on => 1, model => $want->{default}, did => \@did };
}

# Oct 22 2026 (Shanta 7:14 AM PT): one alert per state. last_notified {mode, model} lives in the shared
# state file (written under the run() flock, atomic rename); alert only when that pair changes.
sub notify_change {
    my ($s, $st, $mode, $model, $title, $body, $extra) = @_;
    my $key = join '|', $mode // '', $model // '', (defined $extra && length $extra ? $extra : ());
    my $ln  = ref $st->{last_notified} eq 'HASH' ? $st->{last_notified} : {};
    if (defined $ln->{key} && $ln->{key} eq $key) {
        $s->log_line("alert suppressed (unchanged $key since " . ($ln->{at_pt} // '?') . "): $title");
        return 0;
    }
    my $t = $s->_now;
    $st->{last_notified} = { mode => $mode, model => $model, key => $key, at => $t, at_pt => pt($t), title => $title };
    push @{ $s->{notified} }, { mode => $mode, model => $model, title => $title };
    $s->desktop_notify($title, $body);
    return 1;
}

sub set_model {
    my ($s, $m) = @_;
    if (ref $m eq 'HASH' && is_or_grok($m->{provider}, $m->{default})) {
        my $r = or_grok_replacement($m->{default}, $s->supergrok_state);
        $m = { map { ($_ => $r->{$_}) } @MODEL_KEYS };
    }
    assert_safe_model($m);
    my $cur = $s->current_model;
    my @done;
    for my $k (@MODEL_KEYS) {
        next unless defined $m->{$k};
        next if defined $cur->{$k} && $cur->{$k} eq $m->{$k};
        $s->config_set("model.$k", $m->{$k});
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
            source => 'hermes', request_type => 'overrun_guard',
            # Oct 26: record what is actually billing (provider/model of the top spender) when known
            provider => ($meta->{billing} && $meta->{billing}[0] ? $meta->{billing}[0]{provider} : 'hermes'),
            model => ($meta->{billing} && $meta->{billing}[0] ? $meta->{billing}[0]{model} : ($meta->{to} // '')),
            status => $meta->{action},
            metadata => $J->encode($meta),
        });
        return 1 if $r->{success};
    }
    return 0;
}

# ---- main ------------------------------------------------------------------
# Oct 22 2026: Hermes cron jobs that pin model 'grok-4.7' with no provider inherit the main
# provider (openrouter) and get billed as x-ai/grok-4.7 ($1.45 on Oct 22, 5:00-6:32 AM PT).
# pure: list of job ids whose model is a grok id and whose provider is not xai-oauth.
sub cron_grok_fix_plan {
    my ($jobs) = @_;
    return [] unless ref $jobs eq 'ARRAY';
    my @ids;
    for my $j (@$jobs) {
        next unless ref $j eq 'HASH';
        next unless Comserv::Util::AI::PaidBlock::is_grok_id($j->{model} // '');
        next if ($j->{provider} // '') eq 'xai-oauth';
        push @ids, $j->{id};
    }
    return \@ids;
}

# Pin every grok cron job to xai-oauth (Super Grok), never openrouter. Backs up jobs.json first.
sub fix_cron_grok_jobs {
    my $s = shift;
    my $f = $s->{cron_jobs} // "$s->{hermes_home}/cron/jobs.json";
    open my $fh, '<', $f or return [];
    my $raw = do { local $/; eval { $J->decode(<$fh>) } }; close $fh;
    return [] unless $raw;
    my $jobs = ref $raw eq 'HASH' ? $raw->{jobs} : $raw;
    my $ids = cron_grok_fix_plan($jobs);
    return $ids if !@$ids || $s->{dry_run};
    my %fix = map { ($_ // '') => 1 } @$ids;
    $_->{provider} = 'xai-oauth' for grep { ref $_ eq 'HASH' && $fix{$_->{id} // ''} } @$jobs;
    require File::Copy;
    File::Copy::copy($f, "$f.bak-overrun-" . strftime('%Y%m%d-%H%M%S', localtime $s->_now));
    eval { _atomic_write($f, $J->encode($raw)); 1 } or return [];
    $s->log_line("cron grok jobs pinned to xai-oauth (never openrouter): @$ids");
    return $ids;
}

# { models => {id=>1}, usd => N }: approved trials whose baseline is in the current month (PT). usd = spend recorded at their last check.
sub trial_exclusions {
    my ($s) = @_;
    my %out = (models => {}, usd => 0);
    my $dir = "$s->{app_root}/data/ai_trials";
    return \%out unless -d $dir;
    my $ym = strftime('%Y%m', localtime $s->_now);
    for my $f (glob "$dir/*.state.json") {
        open my $fh, '<', $f or next;
        my $d = eval { local $/; $J->decode(<$fh>) }; close $fh;
        next unless ref $d eq 'HASH' && ref $d->{baseline} eq 'HASH' && $d->{model} && $d->{baseline_at};
        next unless strftime('%Y%m', localtime $d->{baseline_at}) eq $ym;
        $out{models}{ $d->{model} } = 1 unless $d->{stopped};   # a stopped trial is a normal paid model again (its sessions become offenders)
        $out{usd} += $d->{exclude_usd} // 0;
    }
    return \%out;
}

# Trial spend counter (Oct 26 2026, Shanta: the trial model is run by hand from Hermes, e.g. /model kimi). Every guard run, for each
# approved trial in data/ai_trials/*.state.json: spend = OpenRouter live figures vs the baseline taken at begin; tasks = Hermes
# sessions on the trial model since then. One-time alert at alert_at_usd; at the hard cap / task limit the trial is marked stopped,
# alerted once, and its sessions become offenders (gate file) until Shanta moves them with /model code.
sub trial_tick {
    my ($s, $or) = @_;
    return unless ref $or eq 'HASH' && $or->{ok};
    my $dir = "$s->{app_root}/data/ai_trials";
    return unless -d $dir;
    my $ld = eval { Comserv::Util::AI::ModelChains->load(undef, path => "$s->{app_root}/data/ai_model_chains.json", logger => sub { }) };
    for my $f (glob "$dir/*.state.json") {
        eval {
            open my $fh, '<', $f or die "open: $!";
            my $d = do { local $/; $J->decode(<$fh>) }; close $fh;
            return 1 unless ref $d eq 'HASH' && ref $d->{baseline} eq 'HASH' && $d->{name} && $d->{baseline_at};
            my $trial = Comserv::Util::AI::ModelChains->trial($ld, $d->{name}) or return 1;
            my $spent = Comserv::Util::AI::ModelTrial::spent($d->{baseline}, $or);
            my $tasks = $s->trial_sessions($trial->{model}, $d->{baseline_at});
            my $e = Comserv::Util::AI::ModelTrial::evaluate(trial => $trial, spent => $spent, tasks_done => (defined $tasks ? $tasks : $d->{tasks_done}),
                                                            alerted => $d->{alerted}, live_ok => 1);
            $d->{last_spent} = $spent; $d->{last_checked_at} = $s->_now;
            $d->{tasks_done} = $tasks if defined $tasks;
            $d->{exclude_usd} = $spent if $spent > ($d->{exclude_usd} // 0);
            if ($e->{alert}) {
                $d->{alerted} = 1;
                $s->notify_change($d, 'trial', $d->{name}, "Model trial $d->{name}: spend check",
                    sprintf('%s: $%.2f spent of $%s after %d tasks (OpenRouter live figures). Hard stop at $%s.', $trial->{model}, $spent, $trial->{hard_cap_usd}, $d->{tasks_done} // 0, $trial->{hard_cap_usd}), 'alert_at');
            }
            if ($e->{action} eq 'stop' && !$d->{stopped}) {
                $d->{stopped} = $e->{reason};
                $s->notify_change($d, 'trial_stop', $d->{name}, "Model trial $d->{name} STOPPED",
                    "$e->{reason}. Spent \$" . sprintf('%.2f', $spent) . " after " . ($d->{tasks_done} // 0) . ' tasks. Move open sessions with /model code.', 'stop');
                $s->log_line("trial $d->{name} stopped: $e->{reason}");
            }
            $s->{trial_stopped}{ $trial->{model} } = $d->{stopped} if $d->{stopped};
            _atomic_write($f, $J->encode($d));
            1;
        } or do {
            my $err = $@ || 'unknown';
            eval { Comserv::Util::Logging->instance->log_with_details(undef, 'error', __FILE__, __LINE__, 'trial_tick', "trial state $f: $err") };
        };
    }
}

# Hermes sessions on a model since $since (state.db, read-only; same access as thrash_count). undef when unreadable.
sub trial_sessions {
    my ($s, $model, $since) = @_;
    return undef unless -f $s->{state_db};
    return eval {
        require DBI;
        my $dbh = DBI->connect("dbi:SQLite:dbname=$s->{state_db}", '', '', { RaiseError => 1, PrintError => 0, sqlite_open_flags => 1 });
        my ($c) = $dbh->selectrow_array(q{SELECT COUNT(*) FROM sessions WHERE model = ? AND started_at >= ? AND COALESCE(api_call_count, 0) > 0}, undef, $model, $since);
        $dbh->disconnect;
        $c;
    };
}

sub run {
    my ($s, %o) = @_;
    open my $lk, '>', $s->{lock_file} or return { action => 'error', error => "lock: $!" };
    flock($lk, LOCK_EX | LOCK_NB) or return { action => 'skip', reason => 'locked' };
    eval { $s->fix_cron_grok_jobs };
    my $st = $s->read_state;
    my $t  = $s->_now;
    my $lite = 0;
    my $or;
    # Oct 22: reuse the saved OpenRouter reading only while it is itself fresh (fetched_at within
    # min_interval). Cron runs every minute, so keying this on last_check reused an Oct 16 snapshot forever.
    my $snap = ref $st->{last_openrouter} eq 'HASH' ? $st->{last_openrouter} : {};
    my $snap_age = $snap->{fetched_at} ? $t - $snap->{fetched_at} : 9e9;
    if (!$o{force} && $st->{last_check} && $t - $st->{last_check} < $s->{min_interval}
        && $snap->{ok} && $snap_age < $s->{min_interval}) {
        if (1) {
            $or = { %{$st->{last_openrouter}} };
            $lite = 1;
        }
    } else {
        $or = exists $o{openrouter} ? $o{openrouter} : $s->openrouter_status;
    }
    $or = stale_guard($or, $t, $SNAPSHOT_MAX_AGE);
    # Oct 26 2026: an approved model trial (data/ai_trials/*.state.json) is paid from reserve: its spend is taken out of the
    # OpenRouter caps and its model out of the live estimate, so it neither trips the guard nor counts as an offender.
    $s->trial_tick($or) unless $s->{dry_run};
    my $tx = $s->trial_exclusions;
    $s->{trial_models} = $tx->{models};
    $or = Comserv::Util::AI::ModelTrial::exclude_from_or($or, $tx->{usd}) if $tx->{usd};
    my $thrash = exists $o{thrash} ? $o{thrash} : $s->thrash_count;
    my $tbc = exists $o{thrash_by_class} ? $o{thrash_by_class} : $s->thrash_by_class;
    my $lims = $s->thrash_limits;
    my $reported_or = { %$or };
    $s->{reported_or} = $reported_or unless exists $s->{reported_or};
    my $live = exists $o{live} ? $o{live} : $s->live_spend(after => $or->{fetched_at});
    $or = merge_live($or, $live);
    my $v4pro_recent = (ref $live eq 'HASH' && $live->{ok} && $live->{last_v4pro_at} && $t - $live->{last_v4pro_at} < 600) ? 1 : 0;
    # Oct 22 (Shanta 7:33 AM PT): tripped=1 with hold_reason=shield is NOT a money-cap trip; decide as untripped.
    my $shielded = ($st->{tripped} && ($st->{hold_reason} // '') eq $SHIELD) ? 1 : 0;
    my $dst = $shielded ? { %$st, tripped => 0 } : $st;
    my %cc0 = $s->chain_context;
    my $xai_live = (ref $live eq 'HASH' && $live->{ok} && ref $live->{by_channel} eq 'HASH') ? ($live->{by_channel}{xai_direct} || {}) : {};
    my $d = decide(thrash_by_class => $tbc, limits => $lims, thrash => $thrash, openrouter => $or, state => $dst, v4pro_recent => $v4pro_recent,
                   xai_direct => { usd => ($xai_live->{usd} // 0), cap_day => ((($cc0{channel_caps} || {})->{xai_direct} || {})->{day}) },
                   watch_model => (ref $live eq 'HASH' ? $live->{last_watch_model} : undef));
    $d->{thrash} = $thrash;
    if (ref $tbc eq 'HASH' && $tbc->{ok}) {
        $d->{thrash_by_class} = $tbc->{counts};
    }
    $d->{openrouter} = { map { ($_ => $or->{$_}) } grep { exists $or->{$_} } qw(ok day_usd week_usd month_usd balance_usd error live_day_usd live_applied) };
    if ($lite) { $d->{lite} = 1; }
    $st->{last_check}    = $t;
    $st->{last_check_pt} = pt($t);
    $st->{last_reasons}  = $d->{reasons};
    $st->{last_thrash}   = $thrash;
    $st->{last_thrash_by_class} = (ref $tbc eq 'HASH' && $tbc->{ok}) ? $tbc->{counts} : undef;
    $st->{last_openrouter} = $reported_or;
    if (ref $live eq 'HASH' && $live->{ok}) {
        $st->{last_live} = { day_usd => $live->{day_usd}, calls => $live->{calls}, at => $t };
    }
    $st->{caps} = { %CAPS };
    $st->{caps}{thrash_per_15min} = $lims;

    my %ctx = $s->context;
    $ctx{paid_ok} = paid_room($or, ($ctx{channel_caps} && $ctx{channel_caps}{openrouter}) || \%CAPS, $d->{reasons}) ? 1 : 0;
    # Oct 26: sessions already running on a model that is not allowed right now. A guard trip only rewrites
    # config.yaml; a session pinned with /model keeps its model, so list them and gate them (see write_gate).
    my $recent = (ref $live eq 'HASH' && $live->{ok}) ? $live->{recent} : {};
    my $offs = session_offenders($recent,
        tripped => (($st->{tripped} && !$shielded) || $d->{action} eq 'trip') ? 1 : 0,
        allowed_paid => $ctx{allowed_paid}, xai_direct_cap_day => (($ctx{channel_caps} || {})->{xai_direct} || {})->{day},
        or_over => (grep { /^OpenRouter .* over / } @{ $d->{reasons} }) ? 1 : 0,
        sg_unavailable => supergrok_budget_left($ctx{supergrok}) ? 0 : 1,
        trial_stopped => $s->{trial_stopped} || {});
    $d->{offenders} = $offs if @$offs;
    $d->{by_channel} = $live->{by_channel} if ref $live eq 'HASH' && $live->{ok};
    if ($s->{dry_run}) {
        # Show exactly what a trip / restore / self-heal would write right now; write nothing.
        $d->{dry_run} = 1;
        my $tp = build_trip_plan(%ctx, reasons => (@{ $d->{reasons} } ? $d->{reasons} : ['thrash: simulated']));
        my $rp = build_restore_plan(%ctx, state => ($st->{tripped} ? $st
                  : { %$st, target => $tp->{target}{name}, target_default => $tp->{target}{default},
                      saved_model => $ctx{current_model}, saved_aliases => $tp->{aliases}{saved} }));
        $d->{would} = {
            or_models_known => (ref $ctx{or_ids} eq 'HASH' ? scalar(keys %{ $ctx{or_ids} }) : 0),
            supergrok_available => supergrok_available($ctx{supergrok}),
            trip => { kind => $tp->{kind}, paused => $tp->{paused}, model => $tp->{model},
                      aliases => $tp->{aliases}{set}, fallback_providers => $tp->{fallback}, auxiliary => $tp->{auxiliary} },
            restore => { decision => $rp->{decision}{reason}, model => $rp->{model}, aliases => $rp->{aliases},
                         fallback_providers => $rp->{fallback}, auxiliary => $rp->{auxiliary} },
            sanitize => sanitize_plan(%ctx),
            or_grok_block => or_grok_block_plan(%ctx),
        };
        $d->{state} = $st;
        return $d;
    }

    # Oct 23: 30-minute cool-down between a trip and a restore.
    if ($d->{action} eq 'restore' && $st->{since} && $t - $st->{since} < $COOLDOWN_S) {
        $d->{action} = 'hold';
        $d->{cooldown_left_s} = $COOLDOWN_S - ($t - $st->{since});
    }
    if ($d->{action} eq 'trip') {
        my $plan   = build_trip_plan(%ctx, reasons => $d->{reasons});
        # Oct 23 (Shanta 6:57 AM PT): on Super Grok, an OpenRouter cap trip only blocks the paid
        # OpenRouter models (aliases/fallback/auxiliary); Hermes stays on xai-oauth.
        my $cm0 = $ctx{current_model} || {};
        if (paid_only_trip($plan->{kind}, $cm0)) {
            my $keep = { %$cm0, name => alias_value($cm0) };
            $plan = { %$plan, kind => 'caps_paid_only', target => $keep, paused => 0,
                      model => { map { ($_ => $cm0->{$_}) } grep { defined $cm0->{$_} } @MODEL_KEYS },
                      aliases => alias_rewrite_plan(aliases => $ctx{aliases}, safe => alias_value($cm0)) };
        }
        my $target = $plan->{target};
        my $paused = $plan->{paused};
        my $cur    = $ctx{current_model};
        my $bak    = $s->backup_config;
        my $aplan  = $plan->{aliases};
        my @errs;
        my $done  = eval { $s->set_model($plan->{model}) } || []; push @errs, $@ if $@;
        my $adone = eval { $s->set_aliases($aplan->{set}) } || []; push @errs, $@ if $@;
        my $fdone = eval { $s->write_fallback_providers($plan->{fallback}) } || []; push @errs, $@ if $@;
        my $xdone = eval { $s->set_auxiliary($plan->{auxiliary}) } || []; push @errs, $@ if $@;
        my $err = join ' ', @errs;
        my $billing = billing_summary($recent, 3);
        delete @$st{qw(hold_reason hold_since hold_pt)};
        if ($plan->{kind} eq 'caps_paid_only') { $st->{paid_block_only} = 1 } else { delete $st->{paid_block_only} }
        %$st = (%$st, tripped => 1, paused => $paused, since => $t, since_pt => pt($t),
                reasons => $d->{reasons}, kind => $plan->{kind}, saved_model => $cur, saved_aliases => $aplan->{saved},
                saved_fallback => $ctx{current_fallback}, saved_auxiliary => $ctx{auxiliary},
                target => $target->{name}, target_default => $target->{default}, backup => $bak,
                set => $done, aliases_set => $adone, fallback_set => $fdone, auxiliary_set => $xdone,
                ($err ? (set_error => $err) : ()));
        delete $st->{set_error} unless $err;
        my $msg = sprintf("Hermes overrun guard TRIPPED %s (%s): %s. %s Backup: %s. Aliases blocked: %s. Fallback: %s. Open TUI/dashboard sessions adopt this at their next turn unless pinned with /model (then /model %s).",
            pt($t), $plan->{kind}, join('; ', @{ $d->{reasons} }),
            $paused ? "No working cheap model - Hermes PAUSED (local placeholder $target->{name})."
                    : "Hermes default switched to $target->{name}.", $bak // 'FAILED',
            (@$adone ? join(', ', @$adone) : 'none'), join(' > ', @$fdone) || 'unchanged', alias_value($target));
        # Oct 26: name what is actually billing (a session pinned with /model ignores the config default shown above)
        $msg .= ' Billing in the last 10 min: ' . join('; ', map { sprintf('%s $%.2f over %d calls', $_->{label}, $_->{usd}, $_->{calls}) } @$billing) . '.'
            if @$billing;
        _write_notice($s, $msg . "\nAuto-restores when per-provider thrash limits are clear and OpenRouter day/week/month are under \$$CAPS{day}/\$$CAPS{week}/\$$CAPS{month}.");
        $s->write_session_notice({ at => $t, at_pt => pt($t), action => 'trip', reasons => $d->{reasons},
            target => $target->{name}, text => $msg });
        $s->notify_change($st, ($paused ? 'paused' : 'tripped'), $target->{name}, 'Hermes overrun guard TRIPPED',
            (@$billing ? "Billing: $billing->[0]{label}. " : '')
            . ($paused ? 'Hermes PAUSED. ' : "New sessions use $target->{name}. ")
            . 'Open sessions pinned with /model keep their model: run /model code. Details: ~/.hermes/overrun_notice.txt',
            (@$billing ? "$billing->[0]{provider}/$billing->[0]{model}" : undef));
        $s->log_line($msg . ($err ? " set_error=$err" : ''));
        my $ev = { at => $t, at_pt => pt($t), action => 'trip', kind => $plan->{kind}, reasons => $d->{reasons},
                   from => $cur->{default}, to => $target->{name}, to_default => $target->{default},
                   paused => $paused, backup => $bak, billing => $billing,
                   aliases_blocked => [ sort keys %{ $aplan->{set} } ], fallback => $fdone, auxiliary => $xdone,
                   ($err ? (error => $err) : ()) };
        _append($s->{events_file}, $J->encode($ev));
        $ev->{ledger} = $s->ledger($ev);
        $d->{target} = $target->{name}; $d->{target_default} = $target->{default};
        $d->{paused} = $paused; $d->{backup} = $bak; $d->{kind} = $plan->{kind};
        $d->{aliases_blocked} = [ sort keys %{ $aplan->{set} } ];
        $d->{fallback} = $fdone;
    }
    elsif ($d->{action} eq 'restore') {
        my $cur  = $ctx{current_model};
        my $plan = build_restore_plan(%ctx, state => $st);
        my $dec  = $plan->{decision};
        my $want = $plan->{model} || {};
        my $bak  = $s->backup_config;
        my @errs;
        my $done = [];
        if ($dec->{restore_default}) { $done = eval { $s->set_model($want) } || []; push @errs, $@ if $@ }
        # Super Grok has allotment and the pre-trip default was the free placeholder: hand off
        # (supergrok_daily_guard switches within 5 min); coding aliases go to grok-build, never v4-pro.
        my $sg = $ctx{supergrok} || {};
        my $aliases = $plan->{aliases};
        if ($dec->{restore_default} && supergrok_available($sg) && ($want->{default} // '') =~ /:free\z|north-mini/) {
            $st->{hand_off_supergrok} = 1;
            $aliases->{$_} = alias_value(\%SUPERGROK) for grep { exists $aliases->{$_} } qw(code coder);
        }
        my $aliases_restored = eval { $s->set_aliases($aliases) } || []; push @errs, $@ if $@;
        my $fdone = eval { $s->write_fallback_providers($plan->{fallback}) } || []; push @errs, $@ if $@;
        my $xdone = eval { $s->set_auxiliary($plan->{auxiliary}) } || []; push @errs, $@ if $@;
        my $err = join ' ', @errs;
        my $msg  = sprintf('Hermes overrun guard RESTORED %s: windows clear; %s (tripped since %s). Backup: %s. Aliases restored: %s. Fallback: %s',
            pt($t),
            ($dec->{restore_default}
                ? "model back to " . ($want->{default} // '?')
                : "kept hand-set default " . ($cur->{default} // '?') . " (guard had set " . ($st->{target} // '?') . ")"),
            $st->{since_pt} // '?', $bak // 'FAILED',
            (@$aliases_restored ? join(', ', @$aliases_restored) : 'none'), join(' > ', @$fdone) || 'unchanged');
        $s->log_line($msg . ($err ? " set_error=$err" : ''));
        _write_notice($s, $msg);
        $s->write_session_notice({ at => $t, at_pt => pt($t), action => 'clear', text => $msg });
        $s->notify_change($st, 'normal', ($dec->{restore_default} ? $want->{default} : $cur->{default}),
            'Hermes overrun guard cleared', $msg);
        my $ev = { at => $t, at_pt => pt($t), action => 'restore',
                   to => ($dec->{restore_default} ? $want->{default} : $cur->{default}),
                   preserved_manual => $dec->{restore_default} ? 0 : 1,
                   backup => $bak, tripped_since => $st->{since}, fallback => $fdone, auxiliary => $xdone,
                   ($err ? (error => $err) : ()) };
        _append($s->{events_file}, $J->encode($ev));
        $ev->{ledger} = $s->ledger($ev);
        delete $st->{paid_block_only};
        %$st = (%$st, tripped => 0, paused => 0, restored_at => $t, restored_pt => pt($t),
                restore_backup => $bak, restore_decision => $dec->{reason});
        delete @$st{qw(reasons target target_default set set_error aliases_set fallback_set auxiliary_set kind)};
        $d->{restored_to} = $ev->{to};
        $d->{preserved_manual} = $ev->{preserved_manual};
        $d->{fallback} = $fdone;
    }
    else {
        # none / hold: self-heal invalid ids, banned or paid entries that would bill v4-pro.
        my $sp = sanitize_plan(%ctx);
        if (%$sp) {
            my $bak = $s->backup_config;
            my @errs; my @did;
            if ($sp->{fallback}) {
                my $f = eval { $s->write_fallback_providers($sp->{fallback}) }; push @errs, $@ if $@;
                push @did, 'fallback=' . join(' > ', @{ $f || [] });
            }
            if ($sp->{auxiliary}) {
                my $x = eval { $s->set_auxiliary($sp->{auxiliary}) }; push @errs, $@ if $@;
                push @did, 'auxiliary=' . join(',', @{ $x || [] });
            }
            if (defined $sp->{model_default}) {
                eval { $s->config_set('model.default', $sp->{model_default}) }; push @errs, $@ if $@;
                push @did, "model.default=$sp->{model_default}";
            }
            my $err = join ' ', @errs;
            my $msg = sprintf('Hermes overrun guard SANITIZED %s: %s%s. Backup: %s',
                pt($t), join('; ', @did), ($sp->{fallback_why} ? ' (' . join(', ', @{ $sp->{fallback_why} }) . ')' : ''), $bak // 'FAILED');
            $s->log_line($msg . ($err ? " set_error=$err" : ''));
            _append($s->{events_file}, $J->encode({ at => $t, at_pt => pt($t), action => 'sanitize', did => \@did,
                why => $sp->{fallback_why} || [], backup => $bak, ($err ? (error => $err) : ()) }));
            $d->{sanitized} = \@did;
        }
    }
    if ($d->{action} eq 'hold') {
        $st->{reasons} = $d->{reasons} if @{ $d->{reasons} };
    }
    if ($d->{action} eq 'none' || $d->{action} eq 'restore') {
        my $sh = eval { $s->shield_step($st, $t, $or, after_restore => ($d->{action} eq 'restore' ? 1 : 0)) };
        $d->{shield} = $sh if $sh;
        $d->{shield_error} = $@ if $@;
    }
    # Oct 15 2026: block OpenRouter grok every run (re-read config: trip/restore may have written).
    {
        my %c2 = (current_model => $s->current_model, aliases => $s->read_aliases,
                  current_fallback => $s->read_fallback_providers, auxiliary => $s->read_auxiliary,
                  delegation => $s->read_delegation, supergrok => $s->supergrok_state);
        my $bp = or_grok_block_plan(%c2);
        if (@{ $bp->{why} }) {
            my $bak = $s->backup_config; my @errs;
            eval { $s->set_model($bp->{model}) } if $bp->{model}; push @errs, $@ if $@;
            eval { $s->set_aliases($bp->{aliases}) } if $bp->{aliases}; push @errs, $@ if $@;
            eval { $s->write_fallback_providers($bp->{fallback}) } if $bp->{fallback}; push @errs, $@ if $@;
            eval { $s->set_auxiliary($bp->{auxiliary}) } if $bp->{auxiliary}; push @errs, $@ if $@;
            if ($bp->{delegation}) { for my $k (qw(provider model)) { eval { $s->config_set("delegation.$k", $bp->{delegation}{$k}) }; push @errs, $@ if $@ } }
            my $msg = sprintf('Hermes overrun guard BLOCKED OpenRouter grok %s: %s. Backup: %s', pt($t), join('; ', @{ $bp->{why} }), $bak // 'FAILED');
            $s->log_line($msg . (@errs ? ' set_error=' . join(' ', @errs) : ''));
            _append($s->{events_file}, $J->encode({ at => $t, at_pt => pt($t), action => 'or_grok_block', why => $bp->{why}, backup => $bak }));
            $d->{or_grok_blocked} = $bp->{why};
        }
        # saved_* (restored later) must not carry OpenRouter grok either
        for my $a (keys %{ $st->{saved_aliases} || {} }) { $st->{saved_aliases}{$a} = fix_alias_value($st->{saved_aliases}{$a}, $c2{supergrok}) }
        if (ref $st->{saved_model} eq 'HASH' && is_or_grok($st->{saved_model}{provider}, $st->{saved_model}{default})) {
            my $r = or_grok_replacement($st->{saved_model}{default}, $c2{supergrok});
            $st->{saved_model} = { map { ($_ => $r->{$_}) } @MODEL_KEYS };
        }
    }
    # Oct 26: sessions running on a model that is not allowed (see session_offenders) -> gate + one alert per change
    {
        my $chain_txt = join(' > ', map { $_->{slug} } @{ $ctx{chain} || [] });
        my $gate = $s->write_gate($offs, $t, $chain_txt);
        $d->{gate} = $gate;
        my $key = join ',', map { "$_->{session}:$_->{provider}/$_->{model}" } @$offs;
        if (@$offs) {
            my $top = $offs->[0];
            my $title = 'Hermes session on a model that is not allowed';
            my $body = sprintf('%s: %s. Session %s. Its tool calls are blocked by the overrun gate; run /model code (Super Grok / chain: %s).',
                $top->{label}, $top->{reason}, substr($top->{session} // '?', 0, 22), $chain_txt || 'default');
            if ($s->notify_change($st, 'enforce', $key, $title, $body)) {
                my $ev = { at => $t, at_pt => pt($t), action => 'enforce', sessions => [ map { { %$_ } } @$offs ],
                           billing => billing_summary($recent, 3), chain => $chain_txt };
                _append($s->{events_file}, $J->encode($ev));
                $ev->{ledger} = $s->ledger($ev);
                $s->log_line("ENFORCE $body");
            }
        } elsif (ref $st->{last_notified} eq 'HASH' && ($st->{last_notified}{mode} // '') eq 'enforce') {
            # offenders gone: re-arm so a new offender alerts again (no desktop popup for the all-clear)
            $st->{last_notified} = { mode => 'enforce_clear', model => '', key => 'enforce_clear', at => $t, at_pt => pt($t), title => 'enforce cleared' };
        }
    }
    # published for ~/.hermes/scripts/supergrok_daily_guard.py: may the chain's paid step be used right now?
    @$st{qw(paid_ok paid_ok_at)} = ($ctx{paid_ok} ? 1 : 0, $t);
    # cash snapshot for the Super Grok daily guard (numbers only): why the paid step has / has no room, and the
    # x.ai direct and OpenRouter spend against their channel caps
    {
        my $ccaps = $ctx{channel_caps} || {};
        my @why = paid_room_why($or, $ccaps->{openrouter} || \%CAPS, $d->{reasons});
        $st->{cash} = {
            at => $t,
            openrouter => { ok => ($or->{ok} ? 1 : 0), day_usd => $or->{day_usd}, week_usd => $or->{week_usd}, month_usd => $or->{month_usd},
                            caps => $ccaps->{openrouter} || \%CAPS },
            xai_direct => { usd => $xai_live->{usd} // 0, caps => $ccaps->{xai_direct} || { day => 0, week => 0, month => 0 } },
            paid_why   => \@why,
        };
    }
    $s->write_state($st);
    $d->{state} = $st;
    return $d;
}

# Gate file read by ~/.hermes/scripts/overrun_gate_hook.py (a Hermes pre_tool_call hook): tool calls from a
# listed session are blocked with a message until the session is moved with /model. Written only when it changes.
sub write_gate {
    my ($s, $offs, $t, $chain_txt) = @_;
    my $f = "$s->{hermes_home}/overrun_gate.json";
    my $want = { active => (@$offs ? 1 : 0),
                 sessions => [ map { { session => $_->{session}, provider => $_->{provider}, model => $_->{model}, reason => $_->{reason}, label => $_->{label} } } @$offs ],
                 message => 'Overrun guard: this session is on ' . (@$offs ? $offs->[0]{label} . ' (' . $offs->[0]{reason} . ')' : 'a model that is not allowed')
                          . '. Run /model code to move it (chain: ' . ($chain_txt || 'default') . ').' };
    my $new = $J->encode($want);
    my $old = '';
    if (-f $f && open(my $oh, '<', $f)) { local $/; $old = <$oh> // ''; close $oh }
    my $old_at = eval { $J->decode($old)->{at} } // 0;
    my $old_cmp = eval { $J->encode(do { my $o = $J->decode($old); delete $o->{at}; delete $o->{at_pt}; $o }) } // '';
    # an active gate is re-stamped hourly so the hook (which ignores gates older than 6 h) keeps enforcing
    return 'unchanged' if $old_cmp eq $new && !(@$offs && $t - $old_at > 3600);
    return 'none' if !@$offs && (!-f $f);
    my $out = { %$want, at => $t, at_pt => pt($t) };
    my $tmp = "$f.tmp";
    open my $fh, '>', $tmp or return 'error';
    print $fh $J->encode($out); close $fh;
    rename $tmp, $f or return 'error';
    return @$offs ? 'written' : 'cleared';
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
