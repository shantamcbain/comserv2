package Comserv::Model::AI2::ModelSiteSearch;

# Searches 3D model aggregator sites for individual STL model listings.
# Targets server-side rendered sites (Yeggi, STLFinder) because client-side
# rendered sites (Printables, MakerWorld, Thingiverse) return empty shells
# to LWP. Each result is a normalized card identical to the local format:
#   { title, url, thumbnail, site, site_url, cost, file_type, description }
#
# Strategy (in order):
#   1. Yeggi      — server-side rendered, finds individual models from all sites
#   2. STLFinder  — server-side rendered aggregator
#   3. Thangs     — static render attempt (may be CSR-dependent)
#   Fallback: SearXNG in the caller (_run_web_search_for_browse)

use strict;
use warnings;
use Try::Tiny;
use LWP::UserAgent;
use HTTP::Request;

sub new { bless {}, shift }

# ── shared UA ────────────────────────────────────────────────────────────
my $_ua;
sub _ua {
    $_ua ||= do {
        my $ua = LWP::UserAgent->new(
            timeout => 15,
            agent   => 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36'
                     . ' (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        );
        $ua->default_header('Accept' => 'text/html,application/xhtml+xml');
        $ua;
    };
}

# ── search_all ──────────────────────────────────────────────────────────
sub search_all {
    my ($self, %args) = @_;
    my $query = $args{query} // '';
    my $max   = $args{max}   // 36;
    return [] unless length $query;

    my @all;
    push @all, @{ $self->_search_yeggi(query => $query, max => 18) };
    push @all, @{ $self->_search_stlfinder(query => $query, max => 12) };
    push @all, @{ $self->_search_thangs(query => $query, max => 12) };

    my %seen;
    @all = grep { !$seen{$_->{url}}++ } @all;
    return [ splice(@all, 0, $max) ];
}

# ── Yeggi ───────────────────────────────────────────────────────────────
# Aggregator with server-side rendered results listing individual models
# from Printables, Thingiverse, MyMiniFactory, Cults3D, etc.
# URL: https://www.yeggi.com/q/<query>/
sub _search_yeggi {
    my ($self, %args) = @_;
    my $query = $args{query} // '';
    my $max   = $args{max}   // 20;
    return [] unless length $query;

    my $url = 'https://www.yeggi.com/q/'
            . _encode($query)
            . '/';
    my $res = try { _ua()->get($url) } catch { undef };
    return [] unless $res && $res->is_success;

    my $html = $res->decoded_content;
    return [] unless $html && length $html > 500;

    my @results;

    # Yeggi result items: each has a link, image, and source site label.
    # The page is server-rendered so all model data is in the raw HTML.
    #
    # Pattern 1: standard listing blocks
    while ($html =~ m{
        <(?:div|li)[^>]* class="[^"]*(?:result|item)[^"]*"[^>]*>
        (?:
            <a[^>]* href="([^"]+)"[^>]*>
            .*?
            <img[^>]* (?:src|data-src)="([^"]+)"[^>]*>
            .*?
            (?:class="[^"]*(?:title|name)[^"]*"[^>]*)?
            ([^<]{3,200})
            </a>
            .*?
            (?:on\s+([^<]+))?
        )
    }gsx) {
        my ($url, $img, $title, $source) = ($1, $2, $3, $4);
        $title =~ s/<[^>]+>//g;
        $title = trim($title);
        next unless length($title) > 3;
        $source = trim($source || '');
        $source = 'Model Site' unless length($source) > 2;

        push @results, {
            title       => $title,
            url         => _abs_url($url),  # Ensure absolute URL
            thumbnail   => $img,
            site        => $source,
            site_url    => _abs_url($url),
            cost        => '?',
            file_type   => 'STL',
            description => '',
        };
        last if @results >= $max;
    }

    # Pattern 2: simpler link+img extraction if pattern 1 missed
    if (!@results) {
        while ($html =~ m{
            <a[^>]* href="(/q/[^"]+)"[^>]*>
            <img[^>]* (?:src|data-src)="([^"]+)"[^>]*>
            .*?
            (?:<\/a>.*?)?([^<]{4,160})$
        }gsmx) {
            my ($path, $img, $title) = ($1, $2, $3);
            $title = trim($title);
            next unless length($title) > 3;
            push @results, {
                title       => $title,
                url         => "https://www.yeggi.com$path",
                thumbnail   => $img,
                site        => 'Model Site',
                site_url    => 'https://www.yeggi.com',
                cost        => '?',
                file_type   => 'STL',
                description => '',
            };
            last if @results >= $max;
        }
    }

    return \@results;
}

# ── STLFinder ───────────────────────────────────────────────────────────
# https://www.stlfinder.com/search/<query>/
# Server-side rendered; lists individual models with source site indicator.
sub _search_stlfinder {
    my ($self, %args) = @_;
    my $query = $args{query} // '';
    my $max   = $args{max}   // 12;
    return [] unless length $query;

    my $url = 'https://www.stlfinder.com/search/'
            . _encode($query)
            . '/';
    my $res = try { _ua()->get($url) } catch { undef };
    return [] unless $res && $res->is_success;

    my $html = $res->decoded_content;
    return [] unless $html && length $html > 500;

    my @results;

    while ($html =~ m{
        <img[^>]* src="([^"]+)"[^>]*>
        .*?
        <a[^>]* href="([^"]+)"[^>]*>\s*([^<]{3,150})\s*</a>
    }gsx) {
        my ($img, $href, $title) = ($1, $2, $3);
        $title = trim($title);
        next unless length($title) > 3;
        next if $title =~ /^(?:Search|Home|Login|Register|Sort|Filter|Next|Prev)$/i;

        push @results, {
            title       => $title,
            url         => _abs_url($href),
            thumbnail   => $img,
            site        => 'STLFinder',
            site_url    => _abs_url($href),
            cost        => '?',
            file_type   => 'STL',
            description => '',
        };
        last if @results >= $max;
    }

    return \@results;
}

# ── Thangs ──────────────────────────────────────────────────────────────
# https://thangs.com/search?q=<query>&type=models
# Thangs may SSR some data; attempt extraction from structured markup.
sub _search_thangs {
    my ($self, %args) = @_;
    my $query = $args{query} // '';
    my $max   = $args{max}   // 12;
    return [] unless length $query;

    my $url = 'https://thangs.com/search?q='
            . _encode($query)
            . '&type=models';
    my $res = try { _ua()->request(
        HTTP::Request->new(GET => $url,
            [ 'User-Agent' => 'Mozilla/5.0 (compatible; AI-agent/1.0)',
              'Accept'     => 'text/html' ])
    ) } catch { undef };
    return [] unless $res && $res->is_success;

    my $html = $res->decoded_content;
    return [] unless $html && length $html > 500;

    my @results;

    # Try JSON-LD @graph extraction first
    while ($html =~ m{"\@type"\s*:\s*"3DModel".*?"name"\s*:\s*"([^"]{3,150})".*?"image"\s*:\s*"([^"]+)".*?"url"\s*:\s*"([^"]+)"}gs) {
        push @results, {
            title       => $1,
            url         => $3,
            thumbnail   => $2,
            site        => 'Thangs',
            site_url    => 'https://thangs.com',
            cost        => '?',
            file_type   => 'STL',
            description => '',
        };
        last if @results >= $max;
    }

    return \@results;
}

# ── helpers ─────────────────────────────────────────────────────────────
sub _encode {
    my $s = shift;
    utf8::encode($s) if utf8::is_utf8($s);
    $s =~ s/([^a-zA-Z0-9_.~-])/sprintf '%%%02X', ord($1)/eg;
    return $s;
}

sub trim {
    my $s = shift;
    $s =~ s/^\s+|\s+$//g;
    return $s;
}

sub _abs_url {
    my $url = shift;
    return $url if $url =~ /^https?:\/\//;
    return "https:$url" if $url =~ m{^//};
    return "https://www.yeggi.com$url" if $url =~ m{^/};
    return "https://$url";
}

1;