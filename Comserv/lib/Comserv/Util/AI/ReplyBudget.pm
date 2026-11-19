package Comserv::Util::AI::ReplyBudget;

# ==========================================================================
# Comserv::Util::AI::ReplyBudget  (2026-11-18, todo #2758)
#
# WHAT
#   Two pure rules used by Comserv::Model::AI2::Provider::OpenRouter when it
#   builds and reads an OpenAI-style chat completion:
#
#     1. reply_max_tokens()  - how many output tokens to allow for this call.
#     2. extract_reply_text() - what the answer actually is, and whether the
#                               reply was truncated before any answer existed.
#
# WHY
#   AI-editor "implement" calls on reasoning models (nemotron/hy3-style) spend
#   the whole max_tokens budget thinking. The provider then returns content=""
#   with finish_reason=length and the reasoning text in reasoning_content.
#   OpenRouter.pm used to hand that reasoning text back as the answer with
#   success => 1, so no code arrived AND the Router fallover never tried the
#   next model. Raising the budget for coding calls fixes the common case;
#   extract_reply_text() reports the truncated case as an ERROR so the normal
#   failover chain engages.
#
#   Kept in Util::AI::* (not inside OpenRouter.pm) so the rules stay small and
#   testable without a Catalyst context or an HTTP round trip.
#
# No Moose, no Catalyst, no DB, no environment keys.
# ==========================================================================

use strict;
use warnings;

# Unchanged default for ordinary chat turns.
use constant DEFAULT_MAX_TOKENS => 4096;

# Implement-phase / coding calls need room to think AND still emit the file.
use constant CODING_MAX_TOKENS  => 16384;

# --------------------------------------------------------------------------
# is_coding_call($class, $c, %args) -> 0|1
#
# True for an AI-editor implement turn, or an explicit purpose => 'coding'
# call outside the read-only clarify phase. $c may be undef (unit tests); the
# request context is read from $c->stash->{ai2_agent_ctx} when present, and
# explicit %args always win over the stash.
# --------------------------------------------------------------------------
sub is_coding_call {
    my ($class, $c, %args) = @_;

    my $ctx = (ref $c && eval { $c->stash->{ai2_agent_ctx} }) || {};
    $ctx = {} unless ref $ctx eq 'HASH';

    my $phase = $args{phase};
    $phase = $ctx->{phase} unless defined $phase && !ref $phase;
    $phase = '' unless defined $phase && !ref $phase;
    $phase = lc $phase;

    return 1 if $phase eq 'implement';

    my $purpose = $args{purpose};
    $purpose = '' unless defined $purpose && !ref $purpose;
    return 1 if lc($purpose) eq 'coding' && $phase ne '' && $phase ne 'clarify';

    return 0;
}

# --------------------------------------------------------------------------
# reply_max_tokens($class, $c, %args) -> integer
#
# $args{max_tokens} is the caller's own value (default 4096). A coding call
# never gets less than CODING_MAX_TOKENS, but a caller asking for MORE keeps
# its own larger value.
# --------------------------------------------------------------------------
sub reply_max_tokens {
    my ($class, $c, %args) = @_;

    my $mt = $args{max_tokens};
    $mt = DEFAULT_MAX_TOKENS unless defined $mt && !ref $mt && $mt =~ /^\d+$/;
    $mt = int $mt;

    if ($class->is_coding_call($c, %args)) {
        return $mt > CODING_MAX_TOKENS ? $mt : CODING_MAX_TOKENS;
    }
    return $mt;
}

# --------------------------------------------------------------------------
# extract_reply_text($class, $data, %opts) -> ($text, $error)
#
# $data is the decoded OpenAI-style chat completion:
#   { choices => [ { message => { content => ..., reasoning_content => ... },
#                    finish_reason => 'stop'|'length'|... } ] }
#
# Returns the answer text and no error, OR '' plus a short error string when
# the reply was truncated before an answer existed (so the caller can fail
# over instead of returning success with reasoning prose as the answer).
#
# %opts: coding => 0|1  - a coding call must never accept reasoning text as
#                         the answer; it is reported as a truncation.
# --------------------------------------------------------------------------
sub extract_reply_text {
    my ($class, $data, %o) = @_;

    return ('', undef)
        unless ref $data eq 'HASH'
            && ref $data->{choices} eq 'ARRAY'
            && @{ $data->{choices} };

    my $choice = ref $data->{choices}[0] eq 'HASH' ? $data->{choices}[0] : {};
    my $msg    = ref $choice->{message} eq 'HASH' ? $choice->{message} : {};
    my $finish = lc($choice->{finish_reason} // '');

    my $text = $msg->{content};

    # Some providers return content as an array of parts.
    if (ref($text) eq 'ARRAY') {
        $text = join('', map {
            ref($_) eq 'HASH' ? ($_->{text} // $_->{content} // '')
                              : (defined $_ && !ref $_ ? "$_" : '')
        } @$text);
    }
    $text = '' unless defined $text && !ref $text;
    $text =~ s/^\s+|\s+$//g;
    return ($text, undef) if length $text;

    my $reasoning = $msg->{reasoning_content} // $msg->{reasoning} // '';
    $reasoning = '' if ref $reasoning;
    $reasoning =~ s/^\s+|\s+$//g;

    # Reasoning model burned the budget thinking: no answer, only thoughts.
    if (length $reasoning && ($finish eq 'length' || $o{coding})) {
        return ('', 'reply cut off: model used its whole token budget thinking '
                  . '(finish_reason=' . ($finish || 'none') . ')');
    }
    if ($finish eq 'length') {
        return ('', 'reply cut off: token limit reached before any answer '
                  . '(finish_reason=length)');
    }

    # nemotron-style answer placed in the reasoning field (non-coding calls).
    return ($reasoning, undef);
}

1;

__END__

=head1 NAME

Comserv::Util::AI::ReplyBudget - output-token budget and reply extraction
rules for OpenAI-style chat completions (todo #2758).

=head1 SYNOPSIS

    use Comserv::Util::AI::ReplyBudget;

    # 1. How many output tokens does this call get?
    my $max = Comserv::Util::AI::ReplyBudget->reply_max_tokens(
        $c,
        max_tokens => 4096,
        phase      => 'implement',   # or purpose => 'coding'
    );

    # 2. Is this a coding/implement call at all?
    my $coding = Comserv::Util::AI::ReplyBudget->is_coding_call(
        $c, purpose => 'coding', phase => 'implement',
    );

    # 3. What did the provider actually answer?
    my ($text, $err) = Comserv::Util::AI::ReplyBudget->extract_reply_text(
        $data, coding => $coding,
    );
    if (defined $err) {
        # truncated before any answer -> let the Router fail over
    }

=head1 NOTES

Pure Perl: no Moose, no Catalyst, no database, no environment keys. The
request context is read from C<< $c->stash->{ai2_agent_ctx} >> when a
Catalyst context is supplied; explicit arguments always win.
