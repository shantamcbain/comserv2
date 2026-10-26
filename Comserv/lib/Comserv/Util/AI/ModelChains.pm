package Comserv::Util::AI::ModelChains;

# ===================================================================
# Ordered model chains per purpose for the AI2 Router failover
# (AISYSTEM plan §5e "Model Failover").
#
# Source of truth: data/ai_model_chains.json (NOT under root/ — root/ is
# served publicly by Static::Simple). Admins change it from /ai/eval through
# the allow-listed keys in Comserv::Util::AI::EvalAllowList (approve, apply
# with before-value, revert).
#
# The Perl lists (@FREE_PREFERENCE / $CODING_DEFAULT in Util/ModelCatalog.pm)
# are only the LAST-RESORT default when the file is missing or invalid; that
# fallback is logged every time it is taken (once per file state).
#
# Pure functions + a tiny mtime cache. No Catalyst dependency, so the Router,
# ModelCatalog, EvalReports and the tests share one loader.
# ===================================================================

use strict;
use warnings;
use JSON ();

our @PURPOSES = qw(chat docs coding title);

# Slug grammar: provider|model. Providers the Router can dispatch.
our $SLUG_RE = qr/^(?:openrouter|external|supergrok|grok|ollama)\|[A-Za-z0-9._:\/~+\-]+$/;
# "ollama|auto" = first installed chat-capable Ollama tag at call time.
our $OLLAMA_AUTO = 'ollama|auto';

# Hard defaults for the numeric knobs (also the allow-list bounds' midpoint).
our %KNOB_DEFAULTS = (
    circuit_failure_threshold      => 3,
    circuit_cooldown_minutes       => 15,
    circuit_dead_cooldown_hours    => 24,
    openrouter_soft_cap_day_usd    => 1.65,
    openrouter_soft_cap_week_usd   => 11.50,
    openrouter_soft_cap_month_usd  => 50,
    supergrok_respect_guard        => 1,
    exclude_replace_verdict        => 1,
    demote_watch_verdict           => 1,
    # Super Grok daily cap reached (guard locked): coding turns, and turns that
    # asked for Super Grok, go here first (paid, still behind the soft caps).
    # Flash stays for idle/title work only. Empty string = no switch.
    supergrok_locked_coding_model  => 'openrouter|cohere/north-mini-code:free',  # was deepseek-v4-pro until 2026-10-15
);

# Hermes fallback chain (2026-10-26, Shanta): when Super Grok is unavailable go to a good PAID coder
# (within the OpenRouter caps) and only then to free north-mini, which is always the LAST step
# (it is easily overwhelmed when it suddenly replaces a smarter model). The emergency list is used
# only when every step of the chain is unusable. Both live in data/ai_model_chains.json.
our @HERMES_CHAIN_DEFAULT     = ('supergrok|grok-4.7', 'openrouter|qwen/qwen3-coder', 'openrouter|cohere/north-mini-code:free');
our @HERMES_EMERGENCY_DEFAULT = ('ollama|gemma4-64k:latest', 'openrouter|nvidia/nemotron-3.5-lightning:free');
our $HERMES_NORTH_RE          = qr/north-mini-code/i;
our $HERMES_BANNED_RE         = qr/grok|glm|v4-pro/i;     # never as an openrouter step (grok only via Super Grok)
# Cash caps per billing channel. supergrok is a quota, not cash, so it has no entry.
our %CHANNEL_CAPS_DEFAULT = (
    openrouter => { day => 1.65, week => 11.50, month => 50 },
    xai_direct => { day => 0,    week => 0,     month => 0  },   # x.ai API key: off until Shanta sets a number
);

my %CACHE;   # path => { mtime, size, data, source, errors }
my %LOGGED;  # "path|reason" => 1 — log the Perl-default fallback once per state

sub default_path {
    my ($class, $c) = @_;
    return $ENV{COMSERV_AI_CHAINS_FILE} if $ENV{COMSERV_AI_CHAINS_FILE};
    my $p = eval { $c && $c->can('path_to') ? $c->path_to('data', 'ai_model_chains.json') . '' : undef };
    return $p;   # undef without a Catalyst context: callers get Perl defaults
}

# Last-resort default built from the Perl lists. Used only when the file is
# missing/invalid. Known-dead slugs are still listed here on purpose — this is
# exactly the old behaviour; the file is where removals live.
sub perl_default {
    my ($class) = @_;
    require Comserv::Util::ModelCatalog;
    no warnings 'once';
    my @free = @Comserv::Util::ModelCatalog::FREE_PREFERENCE;
    my $code = $Comserv::Util::ModelCatalog::CODING_DEFAULT;
    return {
        version      => 1,
        chain_chat   => [ @free, $OLLAMA_AUTO ],
        chain_docs   => [ @free, $OLLAMA_AUTO ],
        chain_coding => [ $code, @free, $OLLAMA_AUTO ],
        chain_title  => [ @free, $OLLAMA_AUTO ],
        removed      => [],
        model_caps_usd_per_day => {},
        chain_caps_usd_per_day => {},
        tokens_unreported_providers => ['ollama'],
        hermes_fallback_chain  => [ @HERMES_CHAIN_DEFAULT ],
        hermes_emergency_chain => [ @HERMES_EMERGENCY_DEFAULT ],
        channel_caps_usd       => { map { $_ => { %{ $CHANNEL_CAPS_DEFAULT{$_} } } } keys %CHANNEL_CAPS_DEFAULT },
        %KNOB_DEFAULTS,
    };
}

# validate_structure($data) -> ($ok, \@errors). Grammar only (no catalog) —
# the allow-list adds the known-slug check when an admin applies a change.
sub validate_structure {
    my ($class, $d) = @_;
    my @e;
    return (0, ['file is not a JSON object']) unless ref $d eq 'HASH';
    for my $p (@PURPOSES) {
        my $k = "chain_$p";
        my $v = $d->{$k};
        unless (ref $v eq 'ARRAY' && @$v) { push @e, "$k must be a non-empty list"; next }
        my %seen;
        for my $s (@$v) {
            if (!defined $s || ref $s || $s !~ $SLUG_RE) { push @e, "$k: bad slug " . (defined $s && !ref $s ? $s : '(non-string)'); next }
            push @e, "$k: duplicate slug $s" if $seen{$s}++;
        }
    }
    if (exists $d->{removed}) {
        if (ref $d->{removed} ne 'ARRAY') { push @e, 'removed must be a list' }
        else {
            for my $s (@{ $d->{removed} }) {
                push @e, 'removed: bad slug ' . ($s // '(undef)') if !defined $s || ref $s || $s !~ $SLUG_RE;
            }
        }
    }
    for my $k (qw(model_caps_usd_per_day chain_caps_usd_per_day)) {
        next unless exists $d->{$k};
        if (ref $d->{$k} ne 'HASH') { push @e, "$k must be an object"; next }
        for my $ck (keys %{ $d->{$k} }) {
            my $n = $d->{$k}{$ck};
            push @e, "$k.$ck must be a number >= 0" unless defined $n && !ref $n && $n =~ /^\d+(?:\.\d+)?$/;
        }
    }
    push @e, $class->_validate_hermes($d);
    for my $k (keys %KNOB_DEFAULTS) {
        next unless exists $d->{$k};
        my $n = $d->{$k};
        if ($k eq 'supergrok_locked_coding_model') {   # a slug (or '' = off), not a number; perl_default used to fail validation on it
            push @e, "$k: bad slug $n" unless defined $n && !ref $n && ($n eq '' || $n =~ $SLUG_RE);
            next;
        }
        push @e, "$k must be a number" unless defined $n && !ref $n && $n =~ /^\d+(?:\.\d+)?$/;
    }
    return (@e ? 0 : 1, \@e);
}

# tier of a provider|model slug: supergrok | paid | free | local
sub slug_tier {
    my ($class, $slug) = @_;
    my ($p, $m) = split /\|/, ($slug // ''), 2;
    return 'unknown' unless defined $p && defined $m;
    return 'supergrok' if $p =~ /^(?:supergrok|grok)$/;
    return 'local'     if $p eq 'ollama';
    return ($m =~ /:free\z/ ? 'free' : 'paid') if $p eq 'openrouter';
    return 'paid';
}

sub _validate_hermes {
    my ($class, $d) = @_;
    my @e;
    for my $k (qw(hermes_fallback_chain hermes_emergency_chain)) {
        next unless exists $d->{$k};
        my $v = $d->{$k};
        unless (ref $v eq 'ARRAY' && @$v) { push @e, "$k must be a non-empty list"; next }
        my %seen;
        for my $s (@$v) {
            if (!defined $s || ref $s || $s !~ $SLUG_RE) { push @e, "$k: bad slug " . (defined $s && !ref $s ? $s : '(non-string)'); next }
            push @e, "$k: duplicate slug $s" if $seen{$s}++;
            my ($p, $m) = split /\|/, $s, 2;
            push @e, "$k: $s is banned on openrouter (grok only through Super Grok; no glm / v4-pro)"
                if $p eq 'openrouter' && $m =~ $HERMES_BANNED_RE;
        }
    }
    my $ch = ref $d->{hermes_fallback_chain} eq 'ARRAY' ? $d->{hermes_fallback_chain} : [];
    my ($seen_cheap, $north_at);
    for my $i (0 .. $#$ch) {
        my $s = $ch->[$i] // next;
        my $t = $class->slug_tier($s);
        $north_at = $i if $s =~ $HERMES_NORTH_RE;
        if ($t eq 'free' || $t eq 'local') { $seen_cheap = 1 }
        elsif ($t eq 'paid' && $seen_cheap) { push @e, "hermes_fallback_chain: paid step $s after a free step (paid models must come first)" }
    }
    push @e, 'hermes_fallback_chain: north-mini must be the last step' if defined $north_at && $north_at != $#$ch;
    # Oct 26 2026: OPT-IN (default off) cash steps for the Super Grok daily lock. This is the ONLY place a grok
    # model on x.ai direct / OpenRouter is allowed; the chains above keep rejecting it.
    if (exists $d->{hermes_daily_lock_cash}) {
        my $c = $d->{hermes_daily_lock_cash};
        if (ref $c ne 'HASH') { push @e, 'hermes_daily_lock_cash must be an object' }
        else {
            push @e, 'hermes_daily_lock_cash.enabled must be true/false (or 0/1)'
                if exists $c->{enabled}
                   && ( (ref($c->{enabled}) && ref($c->{enabled}) !~ /Boolean/)
                        || (!ref($c->{enabled}) && (!defined $c->{enabled} || $c->{enabled} !~ /^(?:|0|1|true|false)\z/)) );
            if (exists $c->{steps}) {
                if (ref $c->{steps} ne 'ARRAY' || !@{ $c->{steps} }) { push @e, 'hermes_daily_lock_cash.steps must be a non-empty list' }
                else {
                    my %seen;
                    for my $s (@{ $c->{steps} }) {
                        if (!defined $s || ref $s || $s !~ m{^(?:xai_direct|openrouter)\|[A-Za-z0-9._:/\-]+\z}) { push @e, 'hermes_daily_lock_cash.steps: bad step ' . (defined $s && !ref $s ? $s : '(non-string)'); next }
                        push @e, "hermes_daily_lock_cash.steps: duplicate $s" if $seen{$s}++;
                        my ($p, $m) = split /\|/, $s, 2;
                        push @e, "hermes_daily_lock_cash.steps: $s is not a grok model (other paid models belong in hermes_fallback_chain)" unless $m =~ /grok/i;
                        push @e, "hermes_daily_lock_cash.steps: $s is banned (v4-pro / glm)" if $m =~ /v4-pro|glm/i;
                    }
                }
            }
        }
    }
    if (exists $d->{channel_caps_usd}) {
        if (ref $d->{channel_caps_usd} ne 'HASH') { push @e, 'channel_caps_usd must be an object' }
        else {
            for my $ch2 (keys %{ $d->{channel_caps_usd} }) {
                my $h = $d->{channel_caps_usd}{$ch2};
                if (ref $h ne 'HASH') { push @e, "channel_caps_usd.$ch2 must be an object"; next }
                for my $w (keys %$h) {
                    push @e, "channel_caps_usd.$ch2.$w must be a number >= 0"
                        unless defined $h->{$w} && !ref $h->{$w} && $h->{$w} =~ /^\d+(?:\.\d+)?$/;
                }
            }
        }
    }
    return @e;
}

# hermes_chain($loaded) -> list of { slug, provider, model, tier } with removals applied.
sub hermes_chain {
    my ($class, $loaded, %o) = @_;
    my $d = ref $loaded eq 'HASH' && $loaded->{data} ? $loaded->{data} : $loaded;
    my $key = $o{emergency} ? 'hermes_emergency_chain' : 'hermes_fallback_chain';
    my %rm = map { $_ => 1 } @{ $d->{removed} || [] };
    my @src = @{ $d->{$key} || [ $o{emergency} ? @HERMES_EMERGENCY_DEFAULT : @HERMES_CHAIN_DEFAULT ] };
    return map { my ($p, $m) = split /\|/, $_, 2; { slug => $_, provider => $p, model => $m, tier => $class->slug_tier($_) } }
           grep { !$rm{$_} } @src;
}

# hermes_cash_steps($loaded) -> list of { slug, channel, provider, model }: the opt-in x.ai direct / OpenRouter grok
# steps tried BEFORE the paid qwen step on the daily lock. Empty unless hermes_daily_lock_cash.enabled is true.
sub hermes_cash_steps {
    my ($class, $loaded) = @_;
    my $d = ref $loaded eq 'HASH' && $loaded->{data} ? $loaded->{data} : $loaded;
    my $c = ref $d eq 'HASH' ? $d->{hermes_daily_lock_cash} : undef;
    return () unless ref $c eq 'HASH' && $c->{enabled} && $c->{enabled} !~ /^(?:false|0)\z/;
    my @src = ref $c->{steps} eq 'ARRAY' ? @{ $c->{steps} } : ('xai_direct|grok-4.7', 'openrouter|x-ai/grok-4.7');
    return map { my ($p, $m) = split /\|/, $_, 2; { slug => $_, channel => $p, provider => ($p eq 'xai_direct' ? 'xai' : $p), model => $m } } @src;
}

# channel_caps($loaded, 'openrouter') -> { day, week, month }
sub channel_caps {
    my ($class, $loaded, $channel) = @_;
    my $d = ref $loaded eq 'HASH' && $loaded->{data} ? $loaded->{data} : $loaded;
    my %dflt = %{ $CHANNEL_CAPS_DEFAULT{$channel} || {} };
    my $f = ref $d->{channel_caps_usd} eq 'HASH' && ref $d->{channel_caps_usd}{$channel} eq 'HASH' ? $d->{channel_caps_usd}{$channel} : {};
    return { %dflt, %$f };
}

# load($c, %o) -> { data => {...}, source => 'file'|'perl_default', path, errors => [] }
# o: path (override), logger => coderef($level, $msg)
sub load {
    my ($class, $c, %o) = @_;
    my $path = $o{path} // $class->default_path($c);
    my $log  = $o{logger} || sub {
        my ($lvl, $msg) = @_;
        eval {
            require Comserv::Util::Logging;
            Comserv::Util::Logging->instance->log_with_details($c, $lvl, __FILE__, __LINE__, 'ModelChains', $msg);
        };
    };

    my $fallback = sub {
        my ($reason, @errs) = @_;
        my $key = ($path // '(no path)') . "|$reason";
        unless ($LOGGED{$key}++) {
            $log->('warn', "ai_model_chains: using Perl default chains ($reason) "
                . ($path // '(no Catalyst context)') . (@errs ? ': ' . join('; ', @errs) : ''));
        }
        return { data => $class->perl_default, source => 'perl_default', path => $path,
                 reason => $reason, errors => \@errs };
    };

    return $fallback->('no_path') unless $path;
    return $fallback->('missing') unless -f $path;

    my @st = stat $path;
    my $ck = $CACHE{$path};
    if ($ck && $ck->{mtime} == $st[9] && $ck->{size} == $st[7]) {
        return $ck->{result};
    }
    my $raw = do { local $/; open my $fh, '<:raw', $path or return $fallback->('unreadable', "$!"); <$fh> };
    my $d = eval { JSON->new->utf8->relaxed->decode($raw) };
    return $fallback->('invalid_json', ($@ =~ /^(.{0,200})/s)[0]) unless ref $d eq 'HASH';
    my ($ok, $errs) = $class->validate_structure($d);
    return $fallback->('invalid', @$errs) unless $ok;

    my %full = (%{ $class->perl_default }, %$d);   # knobs missing from file -> defaults
    $full{removed} ||= [];
    my $res = { data => \%full, source => 'file', path => $path, errors => [] };
    %LOGGED = map { $_ => 1 } grep { index($_, "$path|") != 0 } keys %LOGGED;   # re-arm fallback log
    $CACHE{$path} = { mtime => $st[9], size => $st[7], result => $res };
    return $res;
}

sub clear_cache { %CACHE = (); %LOGGED = (); return 1 }

# chain($loaded, $purpose) -> list of slugs with removals applied.
sub chain {
    my ($class, $loaded, $purpose) = @_;
    my $d = ref $loaded eq 'HASH' && $loaded->{data} ? $loaded->{data} : $loaded;
    $purpose = 'chat' unless $purpose && grep { $_ eq $purpose } @PURPOSES;
    my %rm = map { $_ => 1 } @{ $d->{removed} || [] };
    return grep { !$rm{$_} } @{ $d->{"chain_$purpose"} || [] };
}

sub is_removed {
    my ($class, $loaded, $slug) = @_;
    my $d = $loaded->{data} || $loaded;
    return (grep { $_ eq $slug } @{ $d->{removed} || [] }) ? 1 : 0;
}

# Every slug the file (or default) mentions — "existing entries" for the
# allow-list known-slug check.
sub all_slugs {
    my ($class, $loaded) = @_;
    my $d = ref $loaded eq 'HASH' && $loaded->{data} ? $loaded->{data} : $loaded;
    my %s;
    for my $p (@PURPOSES) { $s{$_} = 1 for @{ $d->{"chain_$p"} || [] } }
    $s{$_} = 1 for @{ $d->{removed} || [] };
    $s{$_} = 1 for keys %{ $d->{model_caps_usd_per_day} || {} };
    return sort keys %s;
}

sub knob {
    my ($class, $loaded, $k) = @_;
    my $d = $loaded->{data} || $loaded;
    return defined $d->{$k} ? $d->{$k} : $KNOB_DEFAULTS{$k};
}

1;

__END__

=head1 NAME

Comserv::Util::AI::ModelChains - per-purpose ordered model chains for AI2 failover

=head1 SYNOPSIS

    my $ld = Comserv::Util::AI::ModelChains->load($c);   # data/ai_model_chains.json
    my @steps = Comserv::Util::AI::ModelChains->chain($ld, 'chat');
    my $thr   = Comserv::Util::AI::ModelChains->knob($ld, 'circuit_failure_threshold');

=head1 DESCRIPTION

Keys: C<chain_chat>, C<chain_docs>, C<chain_coding>, C<chain_title> (ordered
C<provider|model> slugs; C<ollama|auto> = first installed Ollama chat tag),
C<removed>, C<model_caps_usd_per_day>, C<chain_caps_usd_per_day>,
C<circuit_failure_threshold>, C<circuit_cooldown_minutes>,
C<circuit_dead_cooldown_hours>, C<openrouter_soft_cap_day_usd|week|month>,
C<supergrok_respect_guard>, C<exclude_replace_verdict>, C<demote_watch_verdict>,
C<tokens_unreported_providers>. Missing/invalid file -> Perl default + a log line.

=cut
