package Comserv::Util::AI::TaskTier;
# Is a chat prompt real work or chit-chat, and which small models are too weak
# for real work (Nov 8 2026, Shanta: "good answers done by the most cost
# effective model for the job"). Pure functions; Router uses them.
use strict;
use warnings;

# Known-weak small models: never chosen for substantive work (still usable as a
# last-resort failover inside Router::chat_with_fallback).
our $WEAK_MODEL_RE = qr{nemotron-3-nano|nemotron-nano|nano-9b|-9b-|gemma-4-26b-a4b|:1b\b|:3b\b}i;

sub is_weak { my ($class, $m) = @_; return (defined $m && $m =~ $WEAK_MODEL_RE) ? 1 : 0 }

# is_substantive($text) -> 1 unless it is short chit-chat.
sub is_substantive {
    my ($class, $p) = @_;
    $p //= '';
    (my $t = $p) =~ s/^\s+|\s+$//g;
    return 0 if $t eq '';
    return 0 if length($t) < 60 && $t =~ /^(hi|hello|hey|thanks?|thank you|ok(ay)?|good (morning|night|evening)|yes|no|cool|great|bye)\b[\s!.?]*\w{0,20}[\s!.?]*$/i;
    return 1 if $t =~ /\b(page|button|click|code|bug|error|fix|why|how|explain|template|controller|function|log|todo|start|done|close|stop|recipe|herb|symptom|plan|compare|analy[sz]e|write|draft|summari[sz]e)\b/i;
    return length($t) >= 80 ? 1 : 0;
}

1;
