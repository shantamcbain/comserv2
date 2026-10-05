#!/usr/bin/env perl
# Post a Daily AI Eval Report JSON file to POST /ai/eval/ingest (AISYSTEM plan §5d).
# Same code path as the AI usage monitor's daily routine: the server upserts by
# (report_date, source) and never duplicates proposals, so re-running is safe.
#
#   perl script/ai_eval_ingest.pl [--url http://127.0.0.1:4006/ai/eval/ingest] FILE.json [FILE2.json ...]
#   perl script/ai_eval_ingest.pl --inbox        # every data/ai_eval_inbox/*.json
#
# Token: env AI_EVAL_INGEST_TOKEN, else ~/.comserv/secrets/ai_eval_ingest_token
# (the same places the server reads). Never pass it on the command line.
use strict;
use warnings;
use FindBin qw($Bin);
use Getopt::Long;
use LWP::UserAgent;
use HTTP::Request;
use JSON ();

my $url   = 'http://127.0.0.1:4006/ai/eval/ingest';
my $inbox = 0;
GetOptions('url=s' => \$url, 'inbox' => \$inbox) or die "bad options\n";
my @files = @ARGV;
push @files, sort glob("$Bin/../data/ai_eval_inbox/*.json") if $inbox;
die "usage: $0 [--url URL] FILE.json ... | --inbox\n" unless @files;

my $token = $ENV{AI_EVAL_INGEST_TOKEN};
unless (defined $token && length $token) {
    my $f = ($ENV{HOME} // '') . '/.comserv/secrets/ai_eval_ingest_token';
    if (-r $f && open my $fh, '<', $f) { $token = <$fh>; close $fh }
}
$token //= '';
$token =~ s/^\s+|\s+$//g;
die "No ingest token: set AI_EVAL_INGEST_TOKEN or ~/.comserv/secrets/ai_eval_ingest_token\n" unless length $token;

my $ua = LWP::UserAgent->new(timeout => 60);
my $fail = 0;
for my $file (@files) {
    open my $fh, '<:raw', $file or do { warn "$file: $!\n"; $fail++; next };
    my $body = do { local $/; <$fh> };
    close $fh;
    eval { JSON->new->utf8->decode($body); 1 } or do { warn "$file: not valid JSON: $@"; $fail++; next };
    my $req = HTTP::Request->new(POST => $url);
    $req->header('Content-Type'  => 'application/json');
    $req->header('Authorization' => "Bearer $token");
    $req->content($body);
    my $res = $ua->request($req);
    printf "%s -> %s %s\n", $file, $res->code, $res->decoded_content // '';
    $fail++ unless $res->is_success;
}
exit($fail ? 1 : 0);
