package Comserv::Util::AI::OpenRouterPrices;
# Proposal #34c (eval report 35, Oct 13 2026): OpenRouter list prices for the model scorecard.
# Same cache file + format as UsageMonitor::_openrouter_prices:
#   data/ai_openrouter_prices.json  { at => epoch, prices => { model => [prompt, completion, cache_read] } }  $/token
# Refreshed from the free public https://openrouter.ai/api/v1/models when older than 24 h.
use strict;
use warnings;
use JSON::PP qw(decode_json encode_json);

our $TTL = 86400;

# pure: $ for one call/segment at list price; undef if model unknown, 0 for :free
sub usd_for {
    my ($prices, $model, $in, $out, $cache) = @_;
    return undef unless defined $model && length $model;
    return 0 if $model =~ /:free\z/;
    (my $m = $model) =~ s{^openrouter/}{};
    my $p = ref $prices eq 'HASH' ? $prices->{$m} : undef;
    return undef unless ref $p eq 'ARRAY';
    my ($pp, $cp, $cr) = @$p;
    $in //= 0; $out //= 0; $cache //= 0;
    $cache = $in if $cache > $in;
    return ($in - $cache) * ($pp // 0) + $cache * ($cr // $pp // 0) + $out * ($cp // 0);
}

# IO: cached price table ({} on total failure)
sub load {
    my ($root, %o) = @_;
    my $f = ($root // '.') . '/data/ai_openrouter_prices.json';
    my $cached = eval { open my $fh, '<', $f or die; local $/; decode_json(<$fh>) };
    my $ok = ref $cached eq 'HASH' && ref $cached->{prices} eq 'HASH';
    return $cached->{prices} if $ok && ($o{no_fetch} || ($cached->{at} // 0) > time - $TTL);
    my $p = eval {
        require HTTP::Tiny;
        my $r = HTTP::Tiny->new(timeout => 10)->get('https://openrouter.ai/api/v1/models');
        die "HTTP $r->{status}\n" unless $r->{success};
        my %p;
        for my $m (@{ decode_json($r->{content})->{data} || [] }) {
            my $pr = $m->{pricing} || {};
            $p{ $m->{id} } = [ 0 + ($pr->{prompt} // 0), 0 + ($pr->{completion} // 0),
                               (defined $pr->{input_cache_read} ? 0 + $pr->{input_cache_read} : undef) ];
        }
        \%p;
    };
    if ($p && %$p) {
        if (open my $fh, '>', "$f.tmp") { print $fh encode_json({ at => time, prices => $p }); close $fh; rename "$f.tmp", $f }
        return $p;
    }
    return $ok ? $cached->{prices} : {};
}

1;
