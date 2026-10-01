use strict;
use warnings;
use utf8;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use JSON ();

# SystemOne / decision client (AISYSTEMPlan 5f step 2).
#
# Two halves:
#   1. validation + argument checking — no network at all
#   2. the answer accessors — driven by a REAL response captured from the live
#      server on 2026-09-30 (tev1:0.8b, below), so the shapes under test are the
#      shapes Ollama actually returns, not a guess.
#
# Deliberately NOT covered here: the HTTP round trip itself. That is proven by
# script/ollama_decision_probe.pl against the live daemon; faking LWP here would
# only test the fake. The port below is a dead one so a regression that starts
# making real calls fails loudly instead of silently passing.

BEGIN { use_ok('Comserv::Model::Ollama'); }

my $o = Comserv::Model::Ollama->new(host => '127.0.0.1', port => 1);
$o->model('tev1:0.8b');

# --- the role is actually composed -----------------------------------------
ok($o->can('systemone'),          'systemone composed into Model::Ollama');
ok($o->can('validate_systemone'), 'validate_systemone composed');
ok($o->can('systemone_choice'),   'systemone_choice composed');
ok($o->can('systemone_noul'),     'systemone_noul composed');
ok($o->can('systemone_score'),    'systemone_score composed');
ok($o->can('systemone_summary'),  'systemone_summary composed');

# --- validation: accept -----------------------------------------------------
my @good = (
    'noul with instructions only' => {
        state     => 'The printer is offline',
        questions => { is_hw => { type => 'noul', instructions => 'Is this hardware?' } },
    },
    'structured state' => {
        state     => { ticket => 'charged twice', user => 'guest-1' },
        questions => { refund => { type => 'noul', instructions => 'Wants a refund?' } },
    },
    'choice with 2 options' => {
        state     => 'x',
        questions => { l => { type => 'choice', instructions => 'pick',
                              criteria => { a => 'first', b => 'second' } } },
    },
    'choice with a null description (allowed)' => {
        state     => 'x',
        questions => { l => { type => 'choice', instructions => 'pick',
                              criteria => { a => 'first', b => undef } } },
    },
    'score with 2 levels' => {
        state     => 'x',
        questions => { s => { type => 'score', instructions => 'rate',
                              criteria => ['low', 'high'] } },
    },
    'noul with explicit criteria' => {
        state     => 'x',
        questions => { n => { type => 'noul', instructions => 'is it?',
                              criteria => { true => 'yes it is', false => 'no it is not' } } },
    },
    'all three types together' => {
        state     => 'x',
        questions => {
            c => { type => 'choice', instructions => 'pick', criteria => { a => 'A', b => 'B' } },
            n => { type => 'noul',   instructions => 'is it?' },
            s => { type => 'score',  instructions => 'rate', criteria => ['low', 'mid', 'high'] },
        },
    },
);
while (my ($name, $args) = splice @good, 0, 2) {
    is($o->validate_systemone(%$args), undef, "valid: $name");
}

# --- validation: reject -----------------------------------------------------
my @bad = (
    'missing state' => [{ questions => { q => { type => 'noul', instructions => 'x' } } },
                        qr/state is required/],
    'empty state' => [{ state => '', questions => { q => { type => 'noul', instructions => 'x' } } },
                      qr/state is required/],
    'missing questions' => [{ state => 'x' }, qr/questions must be a map/],
    'questions not a hashref' => [{ state => 'x', questions => [ 'q' ] },
                                  qr/questions must be a map/],
    'zero questions' => [{ state => 'x', questions => {} }, qr/must contain 1-64/],
    '65 questions' => [{
        state     => 'x',
        questions => { map { ("q$_" => { type => 'noul', instructions => 'is it?' }) } 1 .. 65 },
    }, qr/must contain 1-64/],
    'question not an object' => [{ state => 'x', questions => { q => 'is it?' } },
                                 qr/must be an object/],
    'missing type' => [{ state => 'x', questions => { q => { instructions => 'x' } } },
                       qr/needs a type/],
    'unknown type' => [{ state => 'x', questions => { q => { type => 'essay', instructions => 'x' } } },
                       qr/unknown type 'essay'/],
    'missing instructions' => [{ state => 'x', questions => { q => { type => 'noul' } } },
                               qr/needs instructions/],
    'empty instructions' => [{ state => 'x', questions => { q => { type => 'noul', instructions => '' } } },
                             qr/needs instructions/],
    'choice without criteria' => [{ state => 'x',
        questions => { q => { type => 'choice', instructions => 'pick' } } }, qr/choice\) needs criteria/],
    'choice criteria not a map' => [{ state => 'x',
        questions => { q => { type => 'choice', instructions => 'pick', criteria => ['a','b'] } } },
        qr/criteria must be a map/],
    'choice with 1 option' => [{ state => 'x',
        questions => { q => { type => 'choice', instructions => 'pick', criteria => { a => 'A' } } } },
        qr/needs 2-255 options, got 1/],
    'choice option description is a ref' => [{ state => 'x',
        questions => { q => { type => 'choice', instructions => 'pick',
                              criteria => { a => 'A', b => { deep => 1 } } } } },
        qr/description must be text/],
    'score without criteria' => [{ state => 'x',
        questions => { q => { type => 'score', instructions => 'rate' } } }, qr/score\) needs criteria/],
    'score criteria not a list' => [{ state => 'x',
        questions => { q => { type => 'score', instructions => 'rate', criteria => { a => 'A' } } } },
        qr/must be an ordered list/],
    'score with 1 level' => [{ state => 'x',
        questions => { q => { type => 'score', instructions => 'rate', criteria => ['only'] } } },
        qr/needs 2-10 levels, got 1/],
    'score with 11 levels' => [{ state => 'x',
        questions => { q => { type => 'score', instructions => 'rate',
                              criteria => [ map { "l$_" } 1 .. 11 ] } } },
        qr/needs 2-10 levels, got 11/],
    'score level is a ref' => [{ state => 'x',
        questions => { q => { type => 'score', instructions => 'rate',
                              criteria => ['low', { bad => 1 }] } } },
        qr/level 1 must be text/],
    'noul criteria not a hashref' => [{ state => 'x',
        questions => { q => { type => 'noul', instructions => 'is it?', criteria => ['true','false'] } } },
        qr/noul\) criteria must be/],
);
while (my ($name, $t) = splice @bad, 0, 2) {
    my ($args, $re) = @$t;
    my $why = $o->validate_systemone(%$args);
    ok(defined $why, "rejected: $name");
    like($why // '', $re, "  reason: $name");
}

# --- a rejected request must never reach HTTP -------------------------------
is($o->systemone(state => '', questions => {}), undef, 'systemone returns undef on invalid args');
like($o->last_error, qr/^systemone: /, 'last_error is prefixed systemone:');

# --- accessors against a REAL live response (2026-09-30, tev1:0.8b) ---------
my $resp = JSON::decode_json(<<'JSON');
{"usage":{"input_tokens":767,"output_tokens":4},
 "answers":{
   "urgency":{"legend":{"0":"Routine: no time pressure","1":"Soon: a customer is inconvenienced",
                        "2":"Immediate: a critical service is unavailable"},
              "confidence":0.251018539047729,
              "probabilities":{"0":0.0623428590026808,"1":0.635354008887051,"2":0.302303132110268},
              "type":"score","score":1.23996027310759},
   "is_critical":{"type":"noul","noul":0.7369452346902},
   "label":{"choice":"bug","confidence":0.681128622058928,"type":"choice",
            "probabilities":{"billing":0.0749204137635096,"account":0.0168356491363975,
                             "bug":0.908243937100093}}},
 "model":"tev1:0.8b"}
JSON

my ($label, $lp, $lc) = $o->systemone_choice($resp, 'label');
is($label, 'bug', 'choice label');
is($lp, $resp->{answers}{label}{probabilities}{bug}, "choice probability is the SELECTED option's");
is($lc, $resp->{answers}{label}{confidence}, 'choice confidence');

is($o->systemone_noul($resp, 'is_critical'),
   $resp->{answers}{is_critical}{noul}, 'noul probability');

my ($score, $legend, $sc) = $o->systemone_score($resp, 'urgency');
is($score, $resp->{answers}{urgency}{score}, 'score is the probability-weighted level');
is_deeply($legend, $resp->{answers}{urgency}{legend}, 'score legend returned');
is($sc, $resp->{answers}{urgency}{confidence}, 'score confidence');

# wrong type / missing key must be undef — never a wrong-shaped answer
is($o->systemone_choice($resp, 'is_critical'), undef, 'choice accessor rejects a noul answer');
is($o->systemone_score($resp, 'label'),        undef, 'score accessor rejects a choice answer');
is($o->systemone_noul($resp, 'label'),         undef, 'noul accessor rejects a choice answer');
is($o->systemone_choice($resp, 'nope'),        undef, 'unknown key yields undef');
is($o->systemone_choice(undef, 'label'),       undef, 'undef response yields undef');
is($o->systemone_choice({}, 'label'),          undef, 'answers-less response yields undef');

# --- the log summary must never carry caller text ---------------------------
my $sum = $o->systemone_summary($resp, 'tev1:0.8b');
like($sum, qr/model=tev1:0\.8b/, 'summary names the model');
like($sum, qr/questions=\[is_critical,label,urgency\]/, 'summary lists question keys');
like($sum, qr/input_tokens=767/, 'summary carries token usage');
unlike($sum, qr/checkout|ticket|guest/, 'summary never carries caller state text');
is($o->systemone_summary(undef, 'x'), 'systemone: no response', 'summary survives a missing response');

done_testing();
