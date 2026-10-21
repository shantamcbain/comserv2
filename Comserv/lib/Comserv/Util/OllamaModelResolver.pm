package Comserv::Util::OllamaModelResolver;

use strict;
use warnings;
use Try::Tiny;
use JSON qw(decode_json);
use LWP::UserAgent;

our @CHAT_PREFERENCE = ('gemma4-64k:latest', 'qwen2.5-coder:14b');
our $NON_CHAT_RE = qr/^(nimble|tev1|clef-flash)\b|embed/i;

# In-process cache: "host:port" => [ timestamp, arrayref_of_names_or_undef ]
our %INSTALLED_CACHE;

# installed_models($host, $port, %opt) - IO, cached 300s TTL
# Returns arrayref of model *names* or undef if unreachable.
# Callers MUST treat undef as "leave requested model unchanged" and NOT block.
sub installed_models {
    my ($host, $port, %opt) = @_;
    $host ||= 'localhost';
    $port ||= 11434;
    my $key = "$host:$port";
    my $ttl = $opt{ttl} // 300;
    my $now = time();

    if (my $hit = $INSTALLED_CACHE{$key}) {
        my ($ts, $names) = @$hit;
        if ($now - $ts < $ttl) {
            return $names;
        }
    }

    my $url = "http://$host:$port/api/tags";
    my $ua  = LWP::UserAgent->new(timeout => 3);
    my $res = try { $ua->get($url) } catch { undef };

    my $names;
    if ($res && $res->is_success) {
        my $data = try { decode_json($res->decoded_content || '{}') } catch { undef };
        if ($data && ref($data) eq 'HASH' && $data->{models} && ref($data->{models}) eq 'ARRAY') {
            $names = [];
            for my $m (@{ $data->{models} }) {
                my $nm = ref($m) eq 'HASH' ? ($m->{name} // '') : (defined $m ? $m : '');
                push @$names, $nm if length $nm;
            }
        }
    }

    # Cache both success and failure for the TTL to avoid storms on unreachable hosts
    # failures are cached briefly (30s) so a restarted Ollama is picked up quickly
    $INSTALLED_CACHE{$key} = [ defined $names ? $now : $now - $ttl + 30, $names ];
    return $names;
}

# resolve($requested, \@installed) -> ($model, $note)  -- PURE
# exact, or :latest variant; else first preferred chat model installed,
# else first non-NON_CHAT installed, else undef.
# Provider tokens or / ids are treated as non-Ollama -> fallback.
sub resolve {
    my ($requested, $installed_ref) = @_;
    $requested //= '';
    return (undef, '') unless length $requested;

    my @installed;
    if ($installed_ref && ref($installed_ref) eq 'ARRAY') {
        for my $it (@$installed_ref) {
            if (ref($it) eq 'HASH') {
                push @installed, $it->{name} if $it->{name};
            } elsif (defined($it) && length($it)) {
                push @installed, $it;
            }
        }
    }

    my $orig = $requested;

    # Never treat provider token or OpenRouter-style id as an Ollama local name
    if ($requested =~ /^(openrouter|grok|supergrok|openai|ollama|external)$/i || $requested =~ m{/}) {
        return _resolve_fallback($orig, \@installed);
    }

    # Exact match (case-insensitive but preserve installed casing)
    for my $m (@installed) {
        return ($m, '') if lc($m) eq lc($requested);
    }

    # Variant match: strip/add :latest
    my $req_base = $requested;
    $req_base =~ s/:latest$//i;
    my $req_latest = $requested =~ /:/ ? $requested : "$requested:latest";

    for my $m (@installed) {
        my $m_base = $m;
        $m_base =~ s/:latest$//i;
        if (lc($m_base) eq lc($req_base) || lc($m) eq lc($req_latest)) {
            return ($m, "requested '$orig' not installed; using '$m'");
        }
    }

    return _resolve_fallback($orig, \@installed);
}

sub _resolve_fallback {
    my ($orig, $inst_ref) = @_;
    my @inst = @$inst_ref;

    # First preferred chat model that is installed
    for my $pref (@CHAT_PREFERENCE) {
        for my $m (@inst) {
            if (lc($m) eq lc($pref)) {
                return ($m, "requested '$orig' not installed; using '$m'");
            }
        }
    }

    # First installed that is NOT a decision/embed model
    for my $m (@inst) {
        next if $m =~ $NON_CHAT_RE;
        return ($m, "requested '$orig' not installed; using '$m'");
    }

    # Nothing usable
    return (undef, "requested '$orig' not installed; no suitable Ollama model available");
}

# resolve_for_host - convenience that fetches via installed_models (IO) then resolve (pure)
# When tags unreachable, return ($requested, '') unchanged (do not block)
sub resolve_for_host {
    my ($host, $port, $requested) = @_;
    my $inst = installed_models($host, $port);
    if (!defined $inst) {
        return ($requested, '');
    }
    return resolve($requested, $inst);
}

# normalize_provider_model($provider, $model) -> ($provider, $model)  -- PURE
# Fixes swapped cases like provider='nvidia/...', model='openrouter'
# Must be called AFTER any pipe-delimited normalization.
sub normalize_provider_model {
    my ($provider, $model) = @_;
    $provider //= '';
    $model    //= '';

    my $orig_p = $provider;
    my $orig_m = $model;

    my %KNOWN = map { $_ => 1 } qw(ollama grok supergrok grok-oauth openrouter openai external);

    my $changed = 0;

    # If model is a bare provider token...
    if ($model && $model =~ /^(openrouter|grok|supergrok|openai|ollama|external)$/i) {
        my $bare = lc($model);
        if (!$provider || lc($provider) eq 'ollama' || !$KNOWN{ lc($provider) }) {
            # swap: provider becomes the token, model becomes what was in provider (the id)
            $provider = $bare;
            # swapped pair: the old provider value is the real model id, unless it was
            # itself just a provider token (e.g. 'ollama') - then there is no model.
            $model    = ($orig_p ne '' && !$KNOWN{ lc $orig_p }) ? $orig_p : '';
            $changed  = 1;
        } elsif ($KNOWN{ lc($provider) }) {
            $model   = '';
            $changed = 1;
        }
    }

    # If provider is not known but looks like a model id ( / or :free ), treat as model
    if ($provider && !$KNOWN{ lc($provider) } && ( $provider =~ m{/} || $provider =~ /:free/i )) {
        if ($provider =~ m{/}) {
            $model    = $provider unless length $model;
            $provider = 'openrouter';
        } else {
            $model    = $provider unless length $model;
            $provider = 'ollama';
        }
        $changed = 1;
    }

    $provider = lc($provider) if length $provider;

    return ($provider, $model);
}

1;

__END__

=head1 NAME

Comserv::Util::OllamaModelResolver - Resolve requested Ollama model names against installed tags + normalize swapped provider|model pairs from UI

=head1 SYNOPSIS

  use Comserv::Util::OllamaModelResolver;

  my ($model, $note) = Comserv::Util::OllamaModelResolver::resolve_for_host($host, $port, $requested);
  my ($p, $m) = Comserv::Util::OllamaModelResolver::normalize_provider_model($provider, $model);

=cut
