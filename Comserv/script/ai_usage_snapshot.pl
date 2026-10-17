#!/usr/bin/env perl
# Daily usage snapshot for the eval inbox (Oct 12 2026; cron 04:50 PT, before the
# 05:00 PT work-day boundary). Tries, in order:
#   1. /ai/usage_pacing_json on 127.0.0.1:4006 then 127.0.0.1:3001
#   2. /ai/usage_live on 127.0.0.1:3001
#   3. /ai/usage_pacing_json, then /ai/usage_live, on the other ServerFallback hosts/ports
# Writes data/ai_eval_inbox/YYYY-MM-DD-snapshot.json (PT date) with the source URL
# and timestamp, or an error stub listing every attempt if all fail.
#   perl script/ai_usage_snapshot.pl [--out FILE] [--bases "http://a:1,..."]
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Getopt::Long;
use JSON;
use LWP::UserAgent;
use POSIX qw(strftime);
use Comserv::Util::AI::ServerFallback;

my ($out, $bases_opt);
GetOptions('out=s' => \$out, 'bases=s' => \$bases_opt) or die "usage: $0 [--out FILE] [--bases LIST]\n";
my $SF = 'Comserv::Util::AI::ServerFallback';
my $ua = LWP::UserAgent->new(timeout => 90);
my $token = $ENV{AI_EVAL_INGEST_TOKEN} // do {
    my $f = "$ENV{HOME}/.comserv/secrets/ai_eval_ingest_token";
    open my $fh, '<', $f ? $f : '' or undef; my $t = $fh ? <$fh> : ''; $t //= ''; chomp $t; $t };
my %hdr = length($token // '') ? (Authorization => "Bearer $token") : ();

my @local = ('http://127.0.0.1:4006', 'http://127.0.0.1:3001');
my @rest  = $bases_opt ? (split /,/, $bases_opt) : grep { my $b = $_; !grep { $_ eq $b } @local } $SF->candidate_bases;
my @plan  = $bases_opt
    ? ([ '/ai/usage_pacing_json', \@rest ], [ '/ai/usage_live', \@rest ])
    : ([ '/ai/usage_pacing_json', \@local ], [ '/ai/usage_live', ['http://127.0.0.1:3001'] ],
       [ '/ai/usage_pacing_json', \@rest ], [ '/ai/usage_live', \@rest ]);

my (@attempts, $doc);
for my $step (@plan) {
    my ($path, $bases) = @$step;
    next unless @$bases;
    my $r = $SF->request(ua => $ua, method => 'GET', path => $path, headers => {%hdr}, bases => $bases);
    my $src = $SF->source_record($r);
    push @attempts, { path => $path, tried => $src->{tried} };
    next unless $r->{ok} && $r->{code} == 200;
    my $data = eval { JSON->new->utf8->decode($r->{content}) };
    unless (ref $data) { $attempts[-1]{error} = 'non-JSON 200 response'; next }
    $doc = { ok => JSON::true, source_url => $src->{url}, source_path => $path, data => $data };
    last;
}
$doc ||= { ok => JSON::false, error => 'all sources failed', data => undef };
my $date = do { local $ENV{TZ} = 'America/Vancouver'; POSIX::tzset(); strftime('%Y-%m-%d', localtime) };
$doc->{report_date} = $date;
$doc->{source} = 'usage snapshot';
$doc->{created_by} = 'script/ai_usage_snapshot.pl';
$doc->{fetched_at_utc} = strftime('%Y-%m-%dT%H:%M:%SZ', gmtime);
$doc->{fetched_at_pt} = do { local $ENV{TZ} = 'America/Vancouver'; POSIX::tzset(); strftime('%Y-%m-%d %H:%M %Z', localtime) };
$doc->{attempts} = \@attempts;
# Oct 13 2026 (Shanta): Grok Bot usage alongside Super Grok (pacing_json carries data.grok_bot).
$doc->{grok_bot} = $doc->{data}{grok_bot} if ref $doc->{data} eq 'HASH' && $doc->{data}{grok_bot};
$out //= "$FindBin::Bin/../data/ai_eval_inbox/$date-snapshot.json";
(my $dir = $out) =~ s{/[^/]+$}{};
mkdir $dir unless -d $dir;
open my $fh, '>', "$out.tmp" or die "write $out: $!";
print $fh JSON->new->utf8->canonical->pretty->encode($doc);
close $fh;
rename "$out.tmp", $out or die "rename: $!";
print "$doc->{grok_bot}{line}\n" if ref $doc->{grok_bot} eq 'HASH' && $doc->{grok_bot}{line};
printf "%s %s -> %s\n", ($doc->{ok} ? 'OK' : 'FAIL'), ($doc->{source_url} // $doc->{error}), $out;
exit($doc->{ok} ? 0 : 1);
