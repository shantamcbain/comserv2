#!/usr/bin/perl
# Probe: Comserv::Model::Ollama SystemOne (decision) client against a live Ollama.
#
#   perl -Ilib script/ollama_decision_probe.pl                 # localhost:11434
#   perl -Ilib script/ollama_decision_probe.pl host port model
#
# Proves the POST /v1/systemone client end-to-end: typed choice/noul/score
# answers, probabilities, confidence, and the accessor helpers. Never writes to
# the DB and never restarts anything. Exit 0 only when all three question types
# came back typed.
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Comserv::Model::Ollama;

my $host  = $ARGV[0] // '127.0.0.1';
my $port  = $ARGV[1] // 11434;
my $model = $ARGV[2] // 'tev1:0.8b';

my $o = Comserv::Model::Ollama->new(host => $host, port => $port);
$o->model($model);
$o->timeout(900);   # cold decision-model load is measured in tens of seconds

printf "== POST http://%s:%d/v1/systemone model=%s\n", $host, $port, $model;

my $t0 = time;
my $resp = $o->systemone(
    state => 'Our checkout has returned 500 errors since 9am. Customers cannot pay.',
    questions => {
        label => {
            type         => 'choice',
            instructions => 'Which label fits this ticket?',
            criteria     => {
                billing => 'Payments and refunds',
                bug     => 'Software errors',
                account => 'Login and account access',
            },
        },
        is_critical => {
            type         => 'noul',
            instructions => 'Is this a critical outage?',
        },
        urgency => {
            type         => 'score',
            instructions => 'How urgently does this need a response?',
            criteria     => [
                'Routine: no time pressure',
                'Soon: a customer is inconvenienced',
                'Immediate: a critical service is unavailable',
            ],
        },
    },
);
my $elapsed = time - $t0;

unless ($resp) {
    print "FAILED: ", $o->last_error || 'unknown error', "\n";
    exit 1;
}

print "elapsed=${elapsed}s\n";
print "usage: input_tokens=", ($resp->{usage}{input_tokens} // '?'),
      " output_tokens=", ($resp->{usage}{output_tokens} // '?'), "\n";
print $o->systemone_summary($resp, $model), "\n\n";

my $fail = 0;

my ($label, $lp, $lc) = $o->systemone_choice($resp, 'label');
if (defined $label) {
    printf "choice label=%s p=%.4f confidence=%.4f\n", $label, $lp // 0, $lc // 0;
} else {
    print "choice label=MISSING\n";
    $fail++;
}

my $noul = $o->systemone_noul($resp, 'is_critical');
if (defined $noul) {
    printf "noul  is_critical=P(true)=%.4f\n", $noul;
} else {
    print "noul  is_critical=MISSING\n";
    $fail++;
}

my ($score, $legend, $sc) = $o->systemone_score($resp, 'urgency');
if (defined $score) {
    printf "score urgency=%.4f confidence=%.4f levels=%d (0-based)\n",
        $score, $sc // 0, (ref $legend eq 'HASH' ? scalar keys %$legend : 0);
    print "      legend: ", join(' | ', map { "$_=$legend->{$_}" } sort keys %$legend), "\n"
        if ref $legend eq 'HASH';
} else {
    print "score urgency=MISSING\n";
    $fail++;
}

# raw response for the record
print "\nraw: ", do {
    require JSON;
    JSON::encode_json($resp);
}, "\n";

exit($fail ? 1 : 0);
