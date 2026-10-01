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
    supergrok_locked_coding_model  => 'openrouter|deepseek/deepseek-v4-pro',
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
    for my $k (keys %KNOB_DEFAULTS) {
        next unless exists $d->{$k};
        my $n = $d->{$k};
        push @e, "$k must be a number" unless defined $n && !ref $n && $n =~ /^\d+(?:\.\d+)?$/;
    }
    return (@e ? 0 : 1, \@e);
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
