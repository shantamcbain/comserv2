package Comserv::Util::ModelCatalog;

use strict;
use warnings;
use JSON ();
use Try::Tiny;

=head1 NAME

Comserv::Util::ModelCatalog - single source of truth for the AI model catalog

=head1 DESCRIPTION

Every AI surface (floating "Chat with AI" widget, the detached /ai/widget popup,
the /ai and /ai2 pages, the AI2 editor, the git dashboard) needs the SAME list of
selectable models. Previously each surface built its own list — via a JS fetch of
/ai2/providers, via a session cache, or via bespoke per-page TT — which is how the
dropdown ended up empty on some pages and populated on others.

This module owns that list. It builds the flat catalog once per process from the
v2 Router (Model::AI2->get_available_models — the same source /ai2/providers uses)
and caches it. Callers use:

    my $arr  = Comserv::Util::ModelCatalog->catalog($c);       # arrayref
    my $json = Comserv::Util::ModelCatalog->catalog_json($c);  # JSON string

Each entry is:  { value => "provider|model", label => "...", provider => "..." }

The "provider|model" value is the wire format the Router expects; callers that
talk to OpenRouter must strip the "provider|" prefix first.

=cut

# Process-level cache: built once, reused by every request/surface.
our $CACHE_JSON;
our $CACHE_ARR;
our $CACHE_AT = 0;
our $TTL      = 600;   # seconds; providers change rarely

sub _expired {
    my ($class) = @_;
    return 1 unless defined $CACHE_JSON;
    return (time() - $CACHE_AT) > $TTL ? 1 : 0;
}

=head2 catalog($c)

Returns an arrayref of model hashrefs, ROLE-FILTERED. Guests/anonymous users
see only the free tier (free OpenRouter + Ollama local); logged-in non-privileged
members see free + cheap + mid; privileged users (admin/developer/editor) see
everything. Never dies; returns [] on total failure. The unfiltered list is the
process cache; filtering is cheap and done per request so each role sees its own
shortlist (AIMPS Phase 3 — role-scoped shortlists).

=cut

sub catalog {
    my ($class, $c) = @_;
    $class->_build($c) if $class->_expired;
    my $all = $CACHE_ARR || [];
    return $class->_filter_for_role($all, $class->_role_tier($c));
}

=head2 catalog_json($c)

Returns the role-filtered catalog as a JSON string (for window.ComservConfig.models).

=cut

sub catalog_json {
    my ($class, $c) = @_;
    $class->_build($c) if $class->_expired;
    my $flat = $class->_filter_for_role($CACHE_ARR || [], $class->_role_tier($c));
    return try { JSON->new->utf8->canonical->encode($flat) } catch { '[]' };
}

# Resolve the caller's role tier from the session. Cached per call (cheap).
sub _role_tier {
    my ($class, $c) = @_;
    my $roles = eval { $c->session->{roles} } || [];
    $roles = [ split(/\s*,\s*/, $roles) ] unless ref $roles;
    my $is_guest = 1;
    my $is_priv  = 0;
    for my $r (@$roles) {
        next unless defined $r && length $r;
        $is_guest = 0 if $r =~ /^(admin|developer|editor|member|user)$/i;
        $is_priv  = 1 if $r =~ /^(admin|developer|editor)$/i;
    }
    return 'priv'  if $is_priv;
    return 'guest' if $is_guest;
    return 'member';
}

# Keep only the models a given tier may see.
#   guest  : free OpenRouter + Ollama local (no paid, no Grok)
#   member : free + cheap + mid (omit premium > $5 / 1M)
#   priv   : everything
sub _filter_for_role {
    my ($class, $all, $tier) = @_;
    return [ @$all ] if $tier eq 'priv';
    my @out;
    for my $m (@$all) {
        my $svc  = $m->{provider} || '';
        my $free = $m->{free} || ( ($m->{value} // '') =~ /:free$/ ? 1 : 0 );
        my $local = $m->{local} || ( $svc eq 'ollama' ? 1 : 0 );
        if ($tier eq 'guest') {
            # Free tier only: free OpenRouter, or local Ollama. No paid/Grok.
            push @out, $m if $free || $local;
        } else { # member
            # Free + cheap + mid. Skip premium (dearer side > $5 / 1M) and Grok.
            next if $svc eq 'grok';
            my $pp = ($m->{price_prompt}     // 0) + 0;
            my $pc = ($m->{price_completion} // 0) + 0;
            my $max = ( $pp > $pc ) ? $pp : $pc;
            next if $max > 5;   # premium excluded for members
            push @out, $m;
        }
    }
    return \@out;
}

=head2 default_for($c, %opts)

Pick the model that should be pre-selected, given the user's role and the page.

Guests and unprivileged members default to a FREE OpenRouter model: it costs
nothing and, unlike Ollama, does not consume workstation GPU/VRAM (the
workstation is routinely saturated, so making guests hit it is the worst of both
worlds). Privileged users on a coding surface get the pinned coding model.

    my $val = Comserv::Util::ModelCatalog->default_for($c, page => 'editor');

Returns a "provider|model" string, or '' when the catalog is empty.

=cut

# Preference order for the free guest default: small, fast, general-purpose.
our @FREE_PREFERENCE = (
    'openrouter|nvidia/nemotron-3-nano-30b-a3b:free',
    'openrouter|google/gemma-4-31b-it:free',
    'openrouter|google/gemma-4-26b-a4b-it:free',
    'openrouter|nvidia/nemotron-nano-9b-v2:free',
    'openrouter|openai/gpt-oss-20b:free',
);

our $CODING_DEFAULT = 'openrouter|tencent/hy3';

sub default_for {
    my ($class, $c, %opts) = @_;
    my $page = $opts{page} || '';
    my $cat  = $class->catalog($c);
    return '' unless $cat && @$cat;

    my %have = map { $_->{value} => 1 } @$cat;

    # Coding surfaces get the designated coding model when the user may use it.
    if ($page eq 'editor' && $have{$CODING_DEFAULT} && $class->_is_priv($c)) {
        return $CODING_DEFAULT;
    }

    # Everyone else: first available free model, in preference order.
    for my $v (@FREE_PREFERENCE) {
        return $v if $have{$v};
    }
    # Any other free model.
    for my $m (@$cat) {
        return $m->{value} if $m->{free};
    }
    # No free model at all — privileged users may fall through to the coding
    # default; otherwise take the first local model rather than billing anyone.
    return $CODING_DEFAULT if $have{$CODING_DEFAULT} && $class->_is_priv($c);
    for my $m (@$cat) {
        return $m->{value} if $m->{local};
    }
    return $cat->[0]{value};
}

sub _is_priv {
    my ($class, $c) = @_;
    my $roles = eval { $c->session->{roles} } || [];
    $roles = [ split(/\s*,\s*/, $roles) ] unless ref $roles;
    return ( grep { $_ =~ /^(admin|developer|editor)$/i } @$roles ) ? 1 : 0;
}

=head2 invalidate

Drop the cache so the next call rebuilds (use after a provider/key change).

=cut

sub invalidate {
    $CACHE_JSON = undef;
    $CACHE_ARR  = undef;
    $CACHE_AT   = 0;
    return 1;
}

=head2 prime($c, $catalog)

Populate the cache from an already-built Router catalog (avoids a second
expensive provider round-trip). Called by Controller::AI2::providers.

=cut

sub prime {
    my ($class, $c, $catalog) = @_;
    return 0 unless $catalog && ref($catalog) eq 'ARRAY';
    my $flat = $class->_flatten($catalog);
    return 0 unless $flat && @$flat;
    $CACHE_ARR  = $flat;
    $CACHE_JSON = try { JSON->new->utf8->canonical->encode($flat) } catch { undef };
    $CACHE_AT   = time();
    return scalar @$flat;
}

# Normalize the Router's catalog into the flat shape every surface consumes.
sub _flatten {
    my ($class, $catalog) = @_;
    my @flat;
    for my $m (@$catalog) {
        next unless $m && $m->{name} && $m->{provider};
        next if $m->{disabled} || $m->{needs_key} || $m->{unreachable};
        my $svc  = $m->{provider};
        my $name = $m->{name};
        # Skip Router sentinels — they are status markers, not selectable models.
        next if $name =~ /^(ollama_empty|ollama_unreachable)$/;
        next if $name =~ /_unconfigured$/;
        push @flat, {
            value    => "$svc|$name",
            label    => ( defined $m->{label} ? $m->{label} : $name ),
            provider => $svc,
            # Cost tier used by the UI to sort/filter and to pick a safe default.
            #   free  : no per-token charge (OpenRouter ":free" slugs)
            #   local : runs on our own hardware — no cash cost, but it does
            #           consume workstation GPU/VRAM, so it is NOT the guest default
            #   paid  : bills real money per token
            free     => ( $name =~ /:free$/ ? 1 : 0 ),
            local    => ( $svc eq 'ollama' ? 1 : 0 ),
            paid     => ( $svc ne 'ollama' && $name !~ /:free$/ ? 1 : 0 ),
            # AIMPS-P1 (#253): real per-token cost from the provider feed.
            # price_prompt / price_completion are USD per 1M tokens; price_tier
            # is threshold-derived (never a hardcoded model list, see plan §3).
            price_prompt     => ( $m->{price_prompt}     // 0 ) + 0,
            price_completion => ( $m->{price_completion} // 0 ) + 0,
            price_tier       => $class->_price_tier($m),
        };
    }
    return \@flat;
}

# Threshold-derived cost tier from the per-1M prices. Never a hardcoded list of
# model names (the OpenRouter catalog changes weekly and any name list rots).
#   free     : zero per-token cost
#   cheap    : <= $1 / 1M (e.g. most small + mid models)
#   mid      : <= $5 / 1M
#   premium  : > $5 / 1M
sub _price_tier {
    my ($class, $m) = @_;
    my $pp = ( $m->{price_prompt}     // 0 ) + 0;
    my $pc = ( $m->{price_completion} // 0 ) + 0;
    my $max = ( $pp > $pc ) ? $pp : $pc;   # rank by the dearer side
    return 'free'   if $max <= 0;
    return 'cheap'  if $max <= 1;
    return 'mid'    if $max <= 5;
    return 'premium';
}

sub _build {
    my ($class, $c) = @_;

    my $catalog = try {
        $c->model('AI2')->get_available_models($c);
    } catch {
        my $err = $_;
        eval { $c->log->warn("ModelCatalog: build failed: $err") };
        undef;
    };

    my $flat = ( $catalog && ref($catalog) eq 'ARRAY' ) ? $class->_flatten($catalog) : [];

    if (@$flat) {
        $CACHE_ARR  = $flat;
        $CACHE_JSON = try { JSON->new->utf8->canonical->encode($flat) } catch { '[]' };
        $CACHE_AT   = time();
    }
    else {
        # Keep any previous good cache rather than blanking the dropdown.
        $CACHE_ARR  ||= [];
        $CACHE_JSON ||= '[]';
        $CACHE_AT = time() - $TTL + 30;   # retry sooner than a full TTL
    }
    return $CACHE_ARR;
}

1;
