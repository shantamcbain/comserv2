use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

require_ok 'Comserv::Util::AI::ReplyBudget';

my $R = 'Comserv::Util::AI::ReplyBudget';

# Minimal fake Catalyst context: only $c->stash->{...} is used by the module.
{
    package FakeC;
    sub new { my ($cl, %s) = @_; bless { stash => { %s } }, $cl }
    sub stash { $_[0]{stash} }
}

# --------------------------------------------------------------------------
# reply_max_tokens
# --------------------------------------------------------------------------
is $R->reply_max_tokens(undef),
    4096, 'reply_max_tokens: no ctx, no args -> default 4096';

is $R->reply_max_tokens(undef, max_tokens => 2000),
    2000, 'reply_max_tokens: caller 2000 kept for non-coding call';

is $R->reply_max_tokens(undef, phase => 'implement'),
    16384, 'reply_max_tokens: implement phase -> 16384';

is $R->reply_max_tokens(undef, max_tokens => 8192, phase => 'implement'),
    16384, 'reply_max_tokens: implement raises small caller value to 16384';

is $R->reply_max_tokens(undef, max_tokens => 32000, phase => 'implement'),
    32000, 'reply_max_tokens: implement keeps larger caller value (32000)';

my $c_impl = FakeC->new(ai2_agent_ctx => { phase => 'implement' });
is $R->reply_max_tokens($c_impl),
    16384, 'reply_max_tokens: implement phase read from ctx stash -> 16384';

is $R->reply_max_tokens(undef, purpose => 'coding', phase => 'clarify'),
    4096, 'reply_max_tokens: coding purpose in clarify phase -> 4096';

is $R->reply_max_tokens(undef, purpose => 'coding', phase => 'plan'),
    16384, 'reply_max_tokens: coding purpose in plan phase -> 16384';

# --------------------------------------------------------------------------
# is_coding_call
# --------------------------------------------------------------------------
is $R->is_coding_call(undef),
    0, 'is_coding_call: undef ctx, no args -> 0';

is $R->is_coding_call(undef, phase => 'analyze'),
    0, 'is_coding_call: analyze phase -> 0';

# --------------------------------------------------------------------------
# extract_reply_text
# --------------------------------------------------------------------------
my $fence = '`' x 3;

# 1. Plain content is trimmed; no error.
{
    my ($text, $err) = $R->extract_reply_text({
        choices => [ {
            message       => { content => "  ${fence}perl\n1;\n${fence}  " },
            finish_reason => 'stop',
        } ],
    });
    is $text, "${fence}perl\n1;\n${fence}",
        'extract: content trimmed of surrounding whitespace';
    is $err, undef, 'extract: no error for normal content';
}

# 2. Content given as an array of parts is joined.
{
    my ($text, $err) = $R->extract_reply_text({
        choices => [ {
            message       => { content => [ { text => 'a' }, { content => 'b' }, 'c' ] },
            finish_reason => 'stop',
        } ],
    });
    is $text, 'abc', 'extract: array content parts joined to abc';
    is $err, undef, 'extract: no error for array content';
}

# 3. Empty content, reasoning present, finish=length, non-coding -> truncation.
{
    my ($text, $err) = $R->extract_reply_text({
        choices => [ {
            message           => { content => '', reasoning_content => 'thinking...' },
            finish_reason     => 'length',
        } ],
    }, coding => 0);
    is $text, '', 'extract: truncated reasoning reply yields empty text';
    like $err, qr/whole token budget thinking/,
        'extract: truncated reasoning reply reports whole token budget thinking';
    like $err, qr/finish_reason=length/,
        'extract: truncated reasoning reply reports finish_reason=length';
}

# 4. Empty content, reasoning present, finish=stop, coding -> truncation.
{
    my ($text, $err) = $R->extract_reply_text({
        choices => [ {
            message           => { content => undef, reasoning_content => 'thinking...' },
            finish_reason     => 'stop',
        } ],
    }, coding => 1);
    is $text, '', 'extract: coding call rejects reasoning-only reply';
    like $err, qr/whole token budget thinking/,
        'extract: coding call reports reasoning-only reply as truncation';
}

# 5. nemotron-style answer in reasoning field kept for chat (non-coding).
{
    my ($text, $err) = $R->extract_reply_text({
        choices => [ {
            message           => { content => undef, reasoning_content => 'The answer is 42' },
            finish_reason     => 'stop',
        } ],
    }, coding => 0);
    is $text, 'The answer is 42',
        'extract: reasoning field kept as answer for non-coding call';
    is $err, undef, 'extract: no error for nemotron-style chat reply';
}

# 6. Empty content, no reasoning, finish=length -> token limit reached.
{
    my ($text, $err) = $R->extract_reply_text({
        choices => [ {
            message       => { content => '' },
            finish_reason => 'length',
        } ],
    });
    is $text, '', 'extract: length-truncated empty reply yields empty text';
    like $err, qr/token limit reached/,
        'extract: length-truncated empty reply reports token limit reached';
}

# 7. Empty content, no reasoning, finish=stop -> ('', undef); caller handles it.
{
    my ($text, $err) = $R->extract_reply_text({
        choices => [ {
            message       => { content => '' },
            finish_reason => 'stop',
        } ],
    });
    is $text, '', 'extract: empty stop reply yields empty text';
    is $err, undef, 'extract: empty stop reply leaves error to caller';
}

# 8. No choices at all -> ('', undef).
{
    my ($text, $err) = $R->extract_reply_text({});
    is $text, '', 'extract: no choices yields empty text';
    is $err, undef, 'extract: no choices yields no error';
}

done_testing();
