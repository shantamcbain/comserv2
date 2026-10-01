package Comserv::Model::Ollama::Decision;
use Moose::Role;
use namespace::autoclean -except => [qw(try catch finally)];  # keep Try::Tiny subs (Perl 5.40)
use HTTP::Request;
use JSON;
use Try::Tiny;
use Comserv::Util::Logging;

requires qw(endpoint ua last_error timeout);

# SystemOne / decision models — Ollama 0.35+ POST /v1/systemone.
#
# Unlike /api/chat, this endpoint generates NO free text. The server reads the
# model's probabilities directly and returns TYPED answers, so there is nothing
# to parse and off-schema output is impossible:
#
#   {"model":"...","state":<text|object|array>,
#    "questions":{"<key>":{"type":"choice|noul|score",
#                          "instructions":"...","criteria":...}}}
#   -> {"model":"...",
#       "answers":{"<key>":{"type":"choice","choice":"bug",
#                           "probabilities":{...},"confidence":0.68},
#                  "<key>":{"type":"noul","noul":0.74},
#                  "<key>":{"type":"score","score":1.24,"legend":{...},
#                           "probabilities":{...},"confidence":0.25}},
#       "usage":{"input_tokens":N,"output_tokens":N}}
#
# Question types / limits (server-enforced, mirrored here so a bad call never
# leaves the app):
#   choice  2..255 named options with descriptions -> label + per-option probs
#   noul    yes/no, optional criteria {true,false} -> P(true)
#   score   2..10 ordered levels, low end first     -> probability-weighted level
# 1..64 questions per request; answers come back under the same keys. No
# streaming. Decision models reject /v1/chat/completions and vice versa.
#
# `confidence` measures how concentrated the distribution is (1 = certain,
# 0 = uniform). It is NOT a probability of being correct — threshold on it as
# "should I trust this", never as accuracy.

our %DECISION_TYPES = map { $_ => 1 } qw(choice noul score);
our $MAX_QUESTIONS  = 64;
our $MIN_CHOICE     = 2;
our $MAX_CHOICE     = 255;
our $MIN_SCORE      = 2;
our $MAX_SCORE      = 10;

# Raise the default for decision calls: a cold decision model must load weights
# first (nimble measured 56s cold on this workstation, tev1:0.8b 3.8s).
our $DECISION_TIMEOUT_COLD = 900;

sub _decision_fail {
    my ($self, $reason) = @_;
    $self->last_error("systemone: $reason");
    return;
}

# Client-side validation. Returns undef when the request is well formed, else a
# human-readable reason. Pure: no network, no state change.
sub validate_systemone {
    my ($self, %args) = @_;

    my $state = $args{state};
    return 'state is required'
        if !defined $state || (!ref $state && !length "$state");

    my $questions = $args{questions};
    return 'questions must be a map of name => question'
        unless ref($questions) eq 'HASH';

    my @keys = keys %$questions;
    return 'questions must contain 1-' . $MAX_QUESTIONS . ' fields'
        if @keys < 1 || @keys > $MAX_QUESTIONS;

    for my $key (sort @keys) {
        my $q = $questions->{$key};
        return "question '$key' must be an object"
            unless ref($q) eq 'HASH';

        my $type = $q->{type};
        return "question '$key' needs a type"
            if !defined $type || ref $type || !length $type;
        return "question '$key' has unknown type '$type'"
            unless $DECISION_TYPES{$type};

        my $ins = $q->{instructions};
        my $ins_ok = ref($ins) eq 'ARRAY'
            ? (@$ins ? 1 : 0)
            : (defined $ins && !ref($ins) && length $ins);
        return "question '$key' needs instructions" unless $ins_ok;

        if ($type eq 'choice') {
            my $criteria = $q->{criteria};
            return "question '$key' (choice) needs criteria"
                unless defined $criteria;
            return "question '$key' (choice) criteria must be a map of option => description"
                unless ref($criteria) eq 'HASH';
            my @opts = keys %$criteria;
            return "question '$key' (choice) needs $MIN_CHOICE-$MAX_CHOICE options, got " . scalar(@opts)
                if @opts < $MIN_CHOICE || @opts > $MAX_CHOICE;
            for my $opt (@opts) {
                # a null description is allowed (option needs no extra rubric)
                next if !defined $criteria->{$opt};
                return "question '$key' (choice) option '$opt' description must be text"
                    if ref $criteria->{$opt};
            }
        }
        elsif ($type eq 'score') {
            my $criteria = $q->{criteria};
            return "question '$key' (score) needs criteria"
                unless defined $criteria;
            return "question '$key' (score) criteria must be an ordered list of levels"
                unless ref($criteria) eq 'ARRAY';
            return "question '$key' (score) needs $MIN_SCORE-$MAX_SCORE levels, got " . scalar(@$criteria)
                if @$criteria < $MIN_SCORE || @$criteria > $MAX_SCORE;
            for my $i (0 .. $#$criteria) {
                my $lvl = $criteria->[$i];
                return "question '$key' (score) level $i must be text"
                    if !defined $lvl || ref $lvl || !length $lvl;
            }
        }
        elsif ($type eq 'noul') {
            my $criteria = $q->{criteria};
            if (defined $criteria) {
                return "question '$key' (noul) criteria must be {true => .., false => ..}"
                    unless ref($criteria) eq 'HASH';
            }
        }
    }

    return;    # valid
}

# POST /v1/systemone. Returns the DECODED response hashref on success (so
# callers get probabilities/legend, not just a label), undef on any failure
# with the reason in last_error. Never dies: a 400 from the server is read from
# the response body and surfaced like the sibling roles do.
sub systemone {
    my ($self, %args) = @_;

    my $reason = $self->validate_systemone(%args);
    return $self->_decision_fail($reason) if defined $reason;

    my $model = $args{model} // $self->model;

    # Connection's timeout trigger clears the (lazy) UA so the next request
    # rebuilds it with the new value — same contract Provider::Ollama::chat uses
    # for cold starts.
    $self->timeout($args{timeout}) if $args{timeout};

    my $payload = {
        model     => $model,
        state     => $args{state},
        questions => $args{questions},
    };

    my $req = HTTP::Request->new(POST => $self->endpoint . '/v1/systemone');
    $req->header('Content-Type' => 'application/json');
    $req->content(encode_json($payload));

    my $res = $self->ua->request($req);

    unless ($res->is_success) {
        my $body = eval { decode_json($res->decoded_content) } // {};
        my $detail = (ref($body) eq 'HASH' && $body->{error})
            ? $body->{error}
            : $res->status_line;
        $self->last_error($detail);
        return;
    }

    my $data = eval { decode_json($res->decoded_content) };
    unless (ref($data) eq 'HASH' && ref($data->{answers}) eq 'HASH') {
        $self->last_error('systemone: response carried no answers');
        return;
    }

    $self->last_error('');
    return $data;
}

# --- accessors: callers should not re-implement the answer shapes ------------

sub _decision_answer {
    my ($resp, $key, $type) = @_;
    return unless ref($resp) eq 'HASH' && ref($resp->{answers}) eq 'HASH';
    my $a = $resp->{answers}{$key};
    return unless ref($a) eq 'HASH';
    return if defined $type && ($a->{type} // '') ne $type;
    return $a;
}

sub systemone_choice {
    my ($self, $resp, $key) = @_;
    my $a = _decision_answer($resp, $key, 'choice') or return;
    my $label = $a->{choice};
    my $p = ref($a->{probabilities}) eq 'HASH' ? $a->{probabilities}{$label} : undef;
    return ($label, $p, $a->{confidence});
}

sub systemone_noul {
    my ($self, $resp, $key) = @_;
    my $a = _decision_answer($resp, $key, 'noul') or return;
    return $a->{noul};
}

sub systemone_score {
    my ($self, $resp, $key) = @_;
    my $a = _decision_answer($resp, $key, 'score') or return;
    return ($a->{score}, $a->{legend}, $a->{confidence});
}

# One call's worth of metrics for logging. NEVER includes `state`: callers pass
# user text (tickets, mail, transcripts) and it must not land in the log.
sub systemone_summary {
    my ($self, $resp, $model) = @_;
    return 'systemone: no response' unless ref($resp) eq 'HASH';
    my @keys = ref($resp->{answers}) eq 'HASH' ? sort keys %{ $resp->{answers} } : ();
    return sprintf 'systemone model=%s questions=[%s] input_tokens=%s',
        ($model // '?'), join(',', @keys),
        ($resp->{usage}{input_tokens} // '?');
}

1;
