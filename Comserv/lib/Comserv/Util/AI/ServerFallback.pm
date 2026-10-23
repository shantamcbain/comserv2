=pod

=head1 NAME

Comserv::Util::AI::ServerFallback - fallback across configured servers/ports for /ai/eval/ingest (and collect) so one down server does not blank the daily report, and record which source was used.

=cut

package Comserv::Util::AI::ServerFallback;

use strict;
use warnings;

use LWP::UserAgent;
use HTTP::Request;
use JSON ();
use POSIX qw(strftime);

our @PORTS = (4006, 3001, 5000);
our @HOSTS = ('127.0.0.1', 'workstation.local', '172.30.131.126');

sub candidate_bases {
    shift if @_ && $_[0] && !ref($_[0]) && $_[0] =~ /::/;
    my %o = @_;
    my @cands;
    if (my $b = $o{bases}) {
        @cands = ref($b) eq 'ARRAY' ? @$b : (defined $b ? ($b) : ());
    } elsif (my $env = $ENV{COMSERV_FALLBACK_BASES}) {
        @cands = split /,/, $env;
    } else {
        for my $p (@PORTS) {
            for my $h (@HOSTS) {
                push @cands, "http://$h:$p";
            }
        }
    }
    # trim, drop empties, strip trailing /, dedup preserving order
    my %seen;
    my @out;
    for my $b (@cands) {
        next unless defined $b;
        $b =~ s/^\s+|\s+$//g;
        next unless length $b;
        $b =~ s|/$||;
        next if $seen{$b}++;
        push @out, $b;
    }
    return @out;
}

sub should_try_next {
    shift if @_ && $_[0] && !ref($_[0]) && $_[0] =~ /::/;
    my ($code, $internal) = @_;
    $code = defined $code ? $code : 0;
    $internal = defined $internal ? $internal : 0;
    return 1 if $code == 0;
    return 1 if $code == 404;
    if ($code == 500) {
        return $internal ? 1 : 0;
    }
    return 1 if $code == 502 || $code == 503 || $code == 504;
    return 0 if $code >= 200 && $code < 300;
    return 0 if $code == 400 || $code == 401 || $code == 403 || $code == 409 || $code == 413 || $code == 422;
    # unlisted codes (e.g. other 5xx, 429): stop (treat as definitive)
    return 0;
}

sub request {
    shift if @_ && $_[0] && !ref($_[0]) && $_[0] =~ /::/;
    my %o = @_;
    my $ua = $o{ua} || LWP::UserAgent->new(timeout => 20);
    my $method = $o{method} || 'GET';
    my $path = $o{path} || '';
    $path =~ s|^(?!/)|/|;  # ensure leading /
    my $headers = $o{headers} || {};
    my $content = exists $o{content} ? $o{content} : '';
    my @cands = candidate_bases(%o);
    my @tried;
    my $last_code;
    my $final_base;
    my $final_url;
    my $final_code;
    my $final_content;
    my $final_ok = 0;
    for my $base (@cands) {
        my $url = $base . $path;
        my $req = HTTP::Request->new($method => $url);
        for my $k (keys %$headers) {
            $req->header($k => $headers->{$k});
        }
        if (defined $content && length $content) {
            $req->content($content);
        }
        my $res = $ua->request($req);
        my $code = $res->code;
        my $body = $res->decoded_content;
        $body = $res->content if !defined $body || !length $body;
        $body //= '';
        my $internal = 0;
        my $cw = $res->header('Client-Warning');
        $internal = 1 if defined $cw && $cw eq 'Internal response';
        push @tried, { base => $base, code => $code, error => ($code && $code >= 400 ? substr($body,0,200) : undef) };
        $last_code = $code;
        if ($res->is_success || !should_try_next($code, $internal)) {
            $final_ok = $res->is_success ? 1 : 0;
            $final_code = $code;
            $final_content = $body;
            $final_base = $base;
            $final_url = $url;
            last;
        }
        # else try next
    }
    my $result = {
        ok => $final_ok,
        code => (defined $final_code ? $final_code : $last_code),
        content => $final_content,
        base => $final_base,
        url => $final_url,
        tried => \@tried,
    };
    if (!defined $final_base) {
        $result->{ok} = 0;
        $result->{base} = undef;
        $result->{url} = undef;
    }
    return $result;
}

sub source_record {
    shift if @_ && $_[0] && !ref($_[0]) && $_[0] =~ /::/;
    my $arg = (@_ == 1 ? $_[0] : (@_ ? {@_} : {}));
    my %r = ref($arg) eq 'HASH' ? %$arg : ();
    my $at = strftime('%Y-%m-%dT%H:%M:%SZ', gmtime());
    return {
        base   => $r{base},
        url    => $r{url},
        code   => $r{code},
        at_utc => $at,
        tried  => $r{tried} || [],
    };
}

1;