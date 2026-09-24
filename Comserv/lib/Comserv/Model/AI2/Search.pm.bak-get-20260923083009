package Comserv::Model::AI2::Search;

# v2 web-search backend for the Comserv AI stack.
#
# TIERS
#   internal - MariaDB FULLTEXT over documentation/ENCY (free, verifiable).
#              Handled by KnowledgeRecall, not this module.
#   free     - self-hosted SearXNG container (this module). No per-query cost,
#              and unlike OpenRouter it actually honours scope.
#   cheap    - perplexity/sonar via OpenRouter (~$0.005/query).
#   best     - Grok native search_parameters.
#
# WHY SELF-HOSTED IS THE DEFAULT `free` TIER
#   OpenRouter's web_search_options.search_domain_filter is silently ignored:
#   a strict en.wikipedia.org filter returned 0 Wikipedia hits and 16
#   off-filter hosts (verified 2026-09-09). Scope control — e.g. ENCY
#   searching EMA/PubMed/traditional sources rather than the US medical
#   industry — therefore needs a service we run.
#
# CONFIG
#   Comserv/root/config/services.json -> "search": { "url": "...", "enabled": 0 }
#   DISABLED BY DEFAULT: enabled=0 means every call returns disabled and no
#   network traffic happens. Flip it on only after the container is running.

use strict;
use warnings;
use JSON qw(encode_json decode_json);
use Try::Tiny;
use LWP::UserAgent;

my $SERVICE_KEY = 'search';

sub _cfg {
    my ($self, $c) = @_;
    return {} unless $c && $c->can('path_to');

    # Same pattern as Util::SignGenerator: services.json is read from disk via
    # path_to(), NOT from $c->config — the file is never merged into the
    # Catalyst config, so $c->config->{services} is always undef.
    my $path = try { $c->path_to('root', 'config', 'services.json') } catch { undef };
    return {} unless $path;

    my $cfg;
    try {
        open my $fh, '<', $path or die "open $path: $!";
        local $/;
        my $raw = scalar <$fh>;
        close $fh;
        $cfg = decode_json($raw);
    } catch {
        $self->_log($c, 'error',
            "search service config unusable (path=$path): $_");
        $cfg = {};
    };

    return {} unless ref $cfg eq 'HASH';
    return $cfg->{$SERVICE_KEY} || {};
}

# True only when the service is configured AND explicitly enabled.
sub enabled {
    my ($self, $c) = @_;
    my $cfg = $self->_cfg($c) or return 0;
    return 0 unless $cfg->{enabled};
    return 0 unless $cfg->{url};
    return 1;
}

# Query the self-hosted service. Returns:
#   { success => 1, results => [ { title, url, content } ], engine => 'searxng' }
#   { success => 0, error => '...' }
sub query {
    my ($self, $c, %args) = @_;

    my $q = $args{query} // '';
    $q =~ s/^\s+|\s+$//g;
    return { success => 0, error => 'No query provided' } unless length $q;

    unless ($self->enabled($c)) {
        return { success => 0, error => 'search service disabled',
                 disabled => 1 };
    }

    my $cfg = $self->_cfg($c);
    my $url = $cfg->{url};
    $url =~ s{/+$}{};
    my $timeout = $cfg->{timeout} || 20;

    # Scope control: the whole reason for self-hosting. A caller passes
    # sites => ['ema.europa.eu', ...] and we OR them into site: operators so
    # the result set is limited to sources we have vetted.
    if ($args{sites} && ref $args{sites} eq 'ARRAY' && @{ $args{sites} }) {
        my @ok = grep { /^[a-z0-9.-]+$/i } @{ $args{sites} };
        if (@ok) {
            $q .= ' ' . join(' OR ', map { "site:$_" } @ok);
        }
    }

    my $ua = LWP::UserAgent->new(timeout => $timeout);
    $ua->agent('Comserv-AI/1.0');

    my $res = try {
        $ua->post(
            "$url/search",
            'Content-Type' => 'application/json',
            'Accept'       => 'application/json',
            Content        => encode_json({
                q      => $q,
                format => 'json',
                ($args{language} ? (language => $args{language}) : ()),
            }),
        );
    } catch {
        $self->_log($c, 'error', "search request failed: $_");
        undef;
    };

    return { success => 0, error => 'search request failed' }
        unless $res && $res->is_success;

    my $data = try { decode_json($res->decoded_content) } catch { undef };
    return { success => 0, error => 'bad JSON from search service' }
        unless $data && ref $data eq 'HASH';

    my @out;
    for my $r (@{ $data->{results} || [] }) {
        next unless ref $r eq 'HASH';
        push @out, {
            title   => $r->{title}   // '',
            url     => $r->{url}     // '',
            content => $r->{content} // '',
        };
    }

    $self->_log($c, 'info', sprintf('search "%s" -> %d results',
        substr($args{query} // '', 0, 60), scalar @out));

    return { success => 1, results => \@out, engine => 'searxng' };
}

# Render results as a compact context block for the system prompt.
# Every result carries its URL so the model can cite it — the point being
# verifiable references, not confident prose.
sub context_block {
    my ($self, $c, %args) = @_;
    my $r = $self->query($c, %args);
    return '' unless $r->{success} && @{ $r->{results} || [] };

    my $max = $args{max_results} || 5;
    my @lines = ('WEB SEARCH RESULTS (cite the URL for every claim you take from these):');
    my $n = 0;
    for my $hit (@{ $r->{results} }) {
        last if $n++ >= $max;
        next unless $hit->{url};
        my $snippet = $hit->{content} // '';
        $snippet =~ s/\s+/ /g;
        $snippet = substr($snippet, 0, 400);
        push @lines, sprintf('- %s — %s <%s>',
            ($hit->{title} || '(untitled)'), $snippet, $hit->{url});
    }
    return join("\n", @lines);
}

sub _log {
    my ($self, $c, $level, $msg) = @_;
    return unless $c;
    try {
        my $logging = $c->model('AI2')->logging
                   || Comserv::Util::Logging->instance;
        $logging->log_with_details($c, $level, __FILE__, __LINE__,
            'ai2_search', $msg);
    } catch {
        # never let logging failure break a search
    };
}

1;
