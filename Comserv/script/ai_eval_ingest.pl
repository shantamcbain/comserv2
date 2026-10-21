#!/usr/bin/env perl
# Post a Daily AI Eval Report JSON file to POST /ai/eval/ingest (AISYSTEM plan §5d).
# Same code path as the AI usage monitor's daily routine: the server upserts by
# (report_date, source) and never duplicates proposals, so re-running is safe.
# Falls back across servers (see ServerFallback) unless --url forces exact single URL.
#
#   perl script/ai_eval_ingest.pl [--url URL] FILE.json [FILE2.json ...]
#   perl script/ai_eval_ingest.pl --inbox
#   perl script/ai_eval_ingest.pl --collect /ai/usage_live [--out out.json] [--bases "http://a:1,http://b:2"]
#
# Token: env AI_EVAL_INGEST_TOKEN (for ingest/collect if set), else ~/.comserv/secrets/ai_eval_ingest_token
# (the same places the server reads). Never pass it on the command line.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use Getopt::Long;
use LWP::UserAgent;
use HTTP::Request;
use JSON ();
use Comserv::Util::AI::ServerFallback;

my $force_url;
my $inbox = 0;
my $bases_opt;
my $collect;
my $outf;
GetOptions(
    'url=s'     => \$force_url,
    'inbox'     => \$inbox,
    'bases=s'   => \$bases_opt,
    'collect=s' => \$collect,
    'out=s'     => \$outf,
) or die "bad options\n";

my $url = $force_url || 'http://127.0.0.1:4006/ai/eval/ingest';
my @files = @ARGV;
push @files, sort glob("$Bin/../data/ai_eval_inbox/*.json") if $inbox;
die "usage: $0 [--url URL] FILE.json ... | --inbox | --collect PATH [--out FILE]\n" unless @files || $collect;

my $token = $ENV{AI_EVAL_INGEST_TOKEN};
unless (defined $token && length $token) {
    my $f = ($ENV{HOME} // '') . '/.comserv/secrets/ai_eval_ingest_token';
    if (-r $f && open my $fh, '<', $f) { $token = <$fh>; close $fh }
}
$token //= '';
$token =~ s/^\s+|\s+$//g;
# token required only for ingest (and collect if set); collect allows no-token for public paths
my $need_token = !$collect;
if ($need_token) {
    die "No ingest token: set AI_EVAL_INGEST_TOKEN or ~/.comserv/secrets/ai_eval_ingest_token\n" unless length $token;
}

my $ua = LWP::UserAgent->new(timeout => 60);
my $fail = 0;

if ($collect) {
    my %req_o = (
        ua      => $ua,
        method  => 'GET',
        path    => $collect,
        headers => {},
    );
    if (length $token) {
        $req_o{headers}{'Authorization'} = "Bearer $token";
    }
    if ($bases_opt) {
        my @b = map { s/^\s+|\s+$//g; $_ } split /,/, $bases_opt;
        @b = grep { length } @b;
        $req_o{bases} = \@b if @b;
    }
    my $r = Comserv::Util::AI::ServerFallback->request(%req_o);
    my $src = Comserv::Util::AI::ServerFallback->source_record($r);
    my $decoded;
    if ($r->{ok} && $r->{code} == 200) {
        $decoded = eval { JSON->new->utf8->decode($r->{content}); 1 } ? JSON->new->utf8->decode($r->{content}) : $r->{content};
    }
    my $out = { collected_from => $src, data => $decoded };
    my $json_out = JSON->new->utf8->pretty->encode($out);
    if ($outf) {
        if (open my $ofh, '>', $outf) {
            print $ofh $json_out;
            close $ofh;
        } else {
            warn "could not write $outf: $!\n";
            $fail = 1;
        }
    } else {
        print $json_out;
    }
    $fail = 1 unless $r->{ok};
    exit($fail ? 1 : 0);
}

# normal ingest mode
for my $file (@files) {
    open my $fh, '<:raw', $file or do { warn "$file: $!\n"; $fail++; next };
    my $body = do { local $/; <$fh> };
    close $fh;
    my $payload;
    eval { $payload = JSON->new->utf8->decode($body); 1 } or do { warn "$file: not valid JSON: $@"; $fail++; next };
    my $report_date = $payload->{report_date} // '';

    my $r;
    if ($force_url) {
        # --url forces exact single URL, no fallback
        my $req = HTTP::Request->new(POST => $url);
        $req->header('Content-Type'  => 'application/json');
        $req->header('Authorization' => "Bearer $token") if length $token;
        $req->content($body);
        my $res = $ua->request($req);
        $r = {
            ok      => $res->is_success ? 1 : 0,
            code    => $res->code,
            content => $res->decoded_content // $res->content // '',
            base    => $url,
            url     => $url,
            tried   => [ { base => $url, code => $res->code, error => $res->is_success ? undef : ($res->decoded_content//'') } ],
        };
    } else {
        my %req_o = (
            ua      => $ua,
            method  => 'POST',
            path    => '/ai/eval/ingest',
            headers => {
                'Content-Type'  => 'application/json',
                'Authorization' => "Bearer $token",
            },
            content => $body,
        );
        if ($bases_opt) {
            my @b = map { s/^\s+|\s+$//g; $_ } split /,/, $bases_opt;
            @b = grep { length } @b;
            $req_o{bases} = \@b if @b;
        }
        $r = Comserv::Util::AI::ServerFallback->request(%req_o);
    }

    my $tried_n = scalar(@{ $r->{tried} || [] });
    my $base_str = $r->{base} // 'NONE';
    printf "%s -> %s via %s (tried %d)\n", $file, $r->{code}, $base_str, $tried_n;
    print $r->{content} // '', "\n";

    # record source
    my $rec = Comserv::Util::AI::ServerFallback->source_record($r);
    $rec->{file} = $file;
    $rec->{report_date} = $report_date;
    $rec->{ok} = $r->{ok} ? 1 : 0;
    my $jsonl = "$Bin/../data/ai_eval_ingest_sources.jsonl";
    if (open my $jfh, '>>', $jsonl) {
        print $jfh JSON->new->utf8->encode($rec) . "\n";
        close $jfh;
    } else {
        warn "could not append to $jsonl: $!\n";
    }

    $fail++ unless $r->{ok};
}
exit($fail ? 1 : 0);
