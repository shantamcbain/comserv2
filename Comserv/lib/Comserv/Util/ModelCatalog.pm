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
our $CACHE_RAW;       # raw Router catalog (array of hashes with name/provider) for grouping
our $CACHE_AT = 0;
our $TTL      = 600;   # seconds; providers change rarely
our $CACHE_GEN = 5;    # bump when catalog shape/providers/guest-default change
our $CACHE_GEN_LOADED = 0;

sub _expired {
    my ($class) = @_;
    return 1 if ($CACHE_GEN_LOADED || 0) != $CACHE_GEN;
    return 1 unless defined $CACHE_JSON;
    return (time() - $CACHE_AT) > $TTL ? 1 : 0;
}

=head2 catalog($c)

Returns an arrayref of model hashrefs, ROLE-FILTERED. Guests/anonymous users
see only the free tier (free OpenRouter + Ollama local); logged-in non-privileged
members see free + cheap + mid; privileged users (admin/developer) see
everything. Editors share the member catalog (they do not get the model picker).
Never dies; returns [] on total failure. The unfiltered list is the
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
# Filter a RAW Router catalog (array of {provider,name,...}) down to what a
# given role tier may see. Used by endpoints that hand the raw catalog to the
# client (/ai2/providers, /ai) so guests never receive the full model list.
# Guest  : free OpenRouter + Ollama local (no paid, no Grok/SuperGrok).
# Member : free + cheap + mid (omit premium > $5/1M, omit Grok/SuperGrok).
# Priv   : everything.
sub filter_catalog_for_role {
    my ($class, $raw, $tier) = @_;
    return [] unless $raw && ref($raw) eq 'ARRAY';
    return [ @$raw ] if $tier eq 'priv';
    my @out;
    for my $m (@$raw) {
        next unless $m && ref($m) eq 'HASH';
        my $svc  = $m->{provider} || '';
        my $name = $m->{name} // $m->{id} // '';
        my $free = $m->{free} || ( $name =~ /:free$/ ) ? 1 : 0;
        my $local = $m->{local} || ( $svc eq 'ollama' ) ? 1 : 0;
        if ($tier eq 'guest') {
            push @out, $m if $free || $local;
        } else { # member
            next if $svc eq 'grok' || $svc eq 'supergrok';
            my $pp = ($m->{price_prompt}     // 0) + 0;
            my $pc = ($m->{price_completion} // 0) + 0;
            my $max = ( $pp > $pc ) ? $pp : $pc;
            next if $max > 5;
            push @out, $m;
        }
    }
    return \@out;
}

sub _role_tier {
    my ($class, $c) = @_;
    # Site-admin flag is set in Root->auto from UserSiteRole even when the
    # session roles list is still "user". Treat that as priv so admins keep
    # the full model list.
    my $flag_admin = 0;
    eval {
        $flag_admin = 1 if $c->session && $c->session->{is_admin};
        $flag_admin = 1 if $c->stash && $c->stash->{is_admin};
    };
    return 'priv' if $flag_admin;

    my $roles = eval { $c->session->{roles} } || [];
    $roles = [ split(/\s*,\s*/, $roles) ] unless ref $roles;
    my $is_guest = 1;
    my $is_priv  = 0;
    for my $r (@$roles) {
        next unless defined $r && length $r;
        $is_guest = 0 if $r =~ /^(admin|developer|editor|member|user)$/i;
        # Editor shares the member catalog + picker rules (not full priv).
        $is_priv  = 1 if $r =~ /^(admin|developer)$/i;
    }
    return 'priv'  if $is_priv;
    return 'guest' if $is_guest;
    return 'member';
}

# Display rank used by the agent picker and the model-field visibility:
#   0 guest          — AI Assistant + Support Specialist; no model field
#   1 member/editor  — guest agents + Encyclopedia Expert; no model field
#   2 admin/developer — all agents and all models
sub display_rank {
    my ($class, $c) = @_;
    my $tier = $class->_role_tier($c);
    return 2 if $tier eq 'priv';
    return 1 if $tier eq 'member';
    return 0;
}

sub can_select_model {
    my ($class, $c) = @_;
    return $class->display_rank($c) >= 2 ? 1 : 0;
}

sub is_guest_tier {
    my ($class, $c) = @_;
    return $class->_role_tier($c) eq 'guest' ? 1 : 0;
}

sub _display_rank_for {
    my ($class, $name) = @_;
    my $n = lc($name // '');
    return 2 if $n =~ /^(admin|developer)$/;
    return 1 if $n =~ /^(member|user|editor)$/;
    return 0;
}

# Load root/static/config/agents.json once per process.
{
    my $_AGENTS;
    sub _agents_config {
        my ($class, $c) = @_;
        return $_AGENTS if $_AGENTS;
        my $path = eval { $c->path_to('root', 'static', 'config', 'agents.json') };
        return {} unless $path && -f $path;
        my $raw = do {
            open my $fh, '<:encoding(UTF-8)', $path or return {};
            local $/;
            <$fh>;
        };
        my $data = eval { JSON->new->decode($raw) } || {};
        if ($@) {
            eval {
                require Comserv::Util::Logging;
                Comserv::Util::Logging->instance->log_with_details(
                    $c, 'error', __FILE__, __LINE__,
                    'agents_config', "Failed to parse agents.json: $@");
            };
            return {};
        }
        $_AGENTS = (ref($data) eq 'HASH' && $data->{agents}) ? $data->{agents} : {};
        return $_AGENTS;
    }
}

# True when this session may use $agent_id. Unknown ids are treated as
# developer-only so a crafted agent_id cannot escalate.
sub agent_allowed {
    my ($class, $c, $agent_id) = @_;
    $agent_id = lc($agent_id // '');
    return 1 if $agent_id eq '' || $agent_id eq 'auto' || $agent_id eq 'general';
    my $cfg = $class->_agents_config($c);
    my $agent = ($cfg && ref($cfg) eq 'HASH') ? $cfg->{$agent_id} : undef;
    unless ($agent && ref($agent) eq 'HASH') {
        return $class->display_rank($c) >= 2 ? 1 : 0;
    }
    my $min = $agent->{min_role};
    if (!defined $min || !length $min) {
        $min = (exists $agent->{public_access} && !$agent->{public_access})
            ? 'developer' : 'guest';
    }
    return $class->display_rank($c) >= $class->_display_rank_for($min) ? 1 : 0;
}

# catalog_json filtered to the caller's role tier — used by endpoints that
# serialize the raw Router catalog to the client (so guests get only their
# tier, not the full list).
sub json_for_role {
    my ($class, $c) = @_;
    $class->_build($c) if $class->_expired;
    my $flat = $class->_filter_for_role($CACHE_ARR || [], $class->_role_tier($c));
    return try { JSON->new->utf8->canonical->encode($flat) } catch { '[]' };
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
            next if $svc eq 'grok' || $svc eq 'supergrok';
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

# Guest / anonymous default: a LIVE OpenRouter :free instruction model
# good for navigation, helpdesk, and general questions. Verified present
# on openrouter.ai/api/v1/models (2026-08-23). Never default guests to
# Ollama — that burns workstation GPU. First entry is the startup default.
our @FREE_PREFERENCE = (
    'openrouter|google/gemma-4-31b-it:free',           # 31B IT, 256k ctx, free
    'openrouter|google/gemma-4-26b-a4b-it:free',
    'openrouter|nvidia/nemotron-3-nano-30b-a3b:free',
    'openrouter|nvidia/nemotron-nano-9b-v2:free',
    'openrouter|nvidia/nemotron-3.5-lightning:free',
    'openrouter|stealth/ox-alpha',                     # 0/0 priced, no :free suffix
);

our $CODING_DEFAULT = 'openrouter|tencent/hy3';

sub default_for {
    my ($class, $c, %opts) = @_;
    my $page = $opts{page} || '';
    my $cat  = $class->catalog($c);
    return '' unless $cat && @$cat;

    my %have = map { $_->{value} => 1 } @$cat;

    my $tier = $class->_role_tier($c);

    # Coding surfaces get the designated coding model when the user may use it.
    if ($page eq 'editor' && $have{$CODING_DEFAULT} && $class->_is_priv($c)) {
        return $CODING_DEFAULT;
    }

    # Guests and members: first available FREE OpenRouter model. Never Ollama —
    # local models consume the workstation GPU (user: guest default must be a
    # free, available OpenRouter agent for nav / helpdesk / general questions).
    for my $v (@FREE_PREFERENCE) {
        return $v if $have{$v};
    }
    for my $m (@$cat) {
        next if $m->{local} || ($m->{provider} || '') eq 'ollama';
        return $m->{value} if $m->{free};
    }
    if ($tier eq 'guest' || $tier eq 'member') {
        return $FREE_PREFERENCE[0];
    }

    # Privileged: any remaining free, then coding default, then local.
    for my $m (@$cat) {
        return $m->{value} if $m->{free};
    }
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
    return ( grep { $_ =~ /^(admin|developer)$/i } @$roles ) ? 1 : 0;
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
    $CACHE_GEN_LOADED = $CACHE_GEN;
    return scalar @$flat;
}

# Normalize the Router's catalog into the flat shape every surface consumes.
sub _flatten {
    my ($class, $catalog) = @_;
    my @flat;
    for my $m (@$catalog) {
        # Defensive: the catalog is built from upstream provider JSON (Ollama
        # /api/tags, OpenRouter /v1/models). If a provider returns a malformed
        # entry (a bare string or array instead of a model object) it must NOT
        # 500 every page load — Root->auto calls catalog() on each request.
        # Skip and let the Router's own sanitizer log the offending element.
        # Matches the guard used by Api.pm/_focus_external_models and AI.pm.
        next unless $m && ref($m) eq 'HASH' && $m->{name} && $m->{provider};
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
            paid     => ( $svc ne 'ollama' && $svc ne 'supergrok' && $name !~ /:free$/ ? 1 : 0 ),
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
    return 'prepaid' if ($m->{provider} || '') eq 'supergrok' || $m->{prepaid};
    return 'free'   if $max <= 0;
    return 'cheap'  if $max <= 1;
    return 'mid'    if $max <= 5;
    return 'premium';
}

sub _build {
    my ($class, $c, %opts) = @_;

    my $catalog = try {
        $c->model('AI2')->get_available_models($c, include_ollama => 0);
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
        $CACHE_GEN_LOADED = $CACHE_GEN;
    }
    else {
        # Keep any previous good cache rather than blanking the dropdown.
        $CACHE_ARR  ||= [];
        $CACHE_JSON ||= '[]';
        $CACHE_AT = time() - $TTL + 30;   # retry sooner than a full TTL
    }
    return $CACHE_ARR;
}

=head2 refresh($c, %opts)

Explicitly rebuild the catalog with the live provider lists (Ollama + external).
Called by AI surfaces when the user opens chat, the AI editor, or an admin
explicitly triggers a refresh. The cache is process-level, so this helps every
subsequent request on this worker.

If opts{once_per_session} is true, a flag is stored in the session to avoid
refreshing more than once per user session.

=cut

sub refresh {
    my ($class, $c, %opts) = @_;

    if ($opts{once_per_session}) {
        my $sess_key = '_ai_catalog_refreshed_v' . $CACHE_GEN;
        return $CACHE_ARR if $c->session && $c->session->{$sess_key};
    }

    my $catalog = try {
        $c->model('AI2')->get_available_models($c, include_ollama => 1);
    } catch {
        my $err = $_;
        eval { $c->log->warn("ModelCatalog: refresh failed: $err") };
        undef;
    };

    if ($catalog && ref($catalog) eq 'ARRAY') {
        $CACHE_RAW = $catalog;   # keep raw Router shape for grouping endpoints
        my $flat = $class->_flatten($catalog);
        if (@$flat) {
            $CACHE_ARR  = $flat;
            $CACHE_JSON = try { JSON->new->utf8->canonical->encode($flat) } catch { '[]' };
        }
        $CACHE_AT = time();
        $CACHE_GEN_LOADED = $CACHE_GEN;
    }

    if ($opts{once_per_session}) {
        my $sess_key = '_ai_catalog_refreshed_v' . $CACHE_GEN;
        $c->session->{$sess_key} = time() if $c->session;
    }

    return $CACHE_ARR;
}

=head2 raw_catalog

Returns the most recently fetched raw Router catalog (array of hashes with
name/provider/local etc.) as used by /ai2/providers for grouping. Empty if no
refresh has run yet.

=cut

sub raw_catalog {
    my ($class, $c) = @_;
    $class->refresh($c, once_per_session => 1) unless $CACHE_RAW;
    return $CACHE_RAW || [];
}

1;
