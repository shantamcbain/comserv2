package main;

use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use File::Temp qw(tempdir);
use JSON::PP qw(encode_json);
use Comserv::Util::AI::CodeReviewer;
use Comserv::Util::AI::ReviewGate;

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
sub _wj {
    my ($file, $data) = @_;
    open my $fh, '>', $file or die "write $file: $!";
    print $fh encode_json($data);
    close $fh;
    return 1;
}

sub fresh_root {
    my (%o) = @_;
    my $d = tempdir(CLEANUP => 1);
    mkdir "$d/data" or die "mkdir $d/data: $!";

    _wj("$d/data/ai_reviewer.json", {
        enabled        => 1,
        mode           => 'block',
        cap_usd_per_day => 0.5,
        primary        => 'anthropic/claude-sonnet-5.5',
        alternate      => 'openai/gpt-6-sol',
        prices         => {
            'anthropic/claude-sonnet-5.5' => { in => 2, out => 10 },
            'openai/gpt-6-sol'            => { in => 2, out => 10 },
        },
        max_tokens  => 8000,
        free_models => [],
        %{ $o{cfg} || {} },
    });

    unless ($o{no_chains}) {
        _wj("$d/data/ai_model_chains.json", {
            chain_coding => [
                'openrouter|cohere/north-mini-code:free',
                'openrouter|qwen/qwen2.5-vl-3b:free',
                'openrouter|z-ai/glm-5:free',
                'ollama|qwen2.5-coder:14b',
            ],
        });
    }

    if ($o{spent}) {
        my $today = Comserv::Util::AI::CodeReviewer->new(root => $d)->today_pt;
        _wj("$d/data/ai_reviewer_spend.json", { $today => { usd => $o{spent}, calls => 1 } });
    }

    return $d;
}

package T::Q;

sub new {
    my ($class, @replies) = @_;
    return bless { q => [@replies], calls => [] }, $class;
}

sub chat {
    my ($self, $c, %a) = @_;
    push @{ $self->{calls} }, \%a;
    my $r = shift @{ $self->{q} };
    return $r if ref $r eq 'HASH';
    return { success => 0, error => 'no scripted reply' };
}

sub calls { $_[0]{calls} }

package T::Usage;

sub new { return bless { rows => [] }, shift }

sub log {
    my ($self, $c, %a) = @_;
    push @{ $self->{rows} }, \%a;
    return 1;
}

sub rows { $_[0]{rows} }

package main;

my $GOOD = { success => 1,
             response => '{"correctness":4,"security":5,"quality":4,"verdict":"pass","summary":"ok","findings":[]}',
             usage => { prompt_tokens => 1000, completion_tokens => 200, cost => 0.004 } };
my $CUT  = { success => 0, truncated => 1,
             error => 'OpenRouter reply cut off (finish_reason=length)',
             usage => { prompt_tokens => 1000, completion_tokens => 8000, cost => 0.08 } };
my $ERR  = { success => 0, error => 'HTTP 500' };
my $JUNK = { success => 1, response => 'Looks fine to me.',
             usage => { prompt_tokens => 10, completion_tokens => 5 } };
my $HIGH = { success => 1,
             response => '{"correctness":4,"security":5,"quality":4,"verdict":"warn","findings":[{"severity":"high","issue":"x"}]}',
             usage => { prompt_tokens => 100, completion_tokens => 20, cost => 0.001 } };

sub run_review {
    my ($root, $q, %extra) = @_;
    my $rv = Comserv::Util::AI::CodeReviewer->new(root => $root);
    my $u  = T::Usage->new;
    my $r  = $rv->review(undef,
        diff          => "+my \$x = 1;\n",
        author_models => ['grok-4.7'],
        provider      => $q,
        usage_model   => $u,
        %extra,
    );
    return ($rv, $r, $u);
}

sub assert_blocked {
    my ($rv, $r, $name) = @_;
    ok($rv->should_block($r), "$name: should_block");
    my $v = $rv->gate_view($r);
    ok($v->{blocking} && !$v->{allow} && $v->{not_reviewed} && $v->{retry},
       "$name: gate blocked with Retry review");
    like($v->{warning}, qr/^Not reviewed, commit blocked: /, "$name: blocked message");
    return $v;
}

# ---------------------------------------------------------------------------
# 1) free_models
# ---------------------------------------------------------------------------
is_deeply(
    [ Comserv::Util::AI::ReviewGate->free_models(root => fresh_root()) ],
    ['cohere/north-mini-code:free'],
    'free list keeps coder, drops vision/3B, glm, non-openrouter'
);

is_deeply(
    [ Comserv::Util::AI::ReviewGate->free_models(
        root  => fresh_root(no_chains => 1),
        extra => ['x-ai/grok-4:free', 'nvidia/nemotron-3.5-lightning:free'],
    ) ],
    ['nvidia/nemotron-3.5-lightning:free'],
    'extra list, grok never'
);

# ---------------------------------------------------------------------------
# 2) fallover order
# ---------------------------------------------------------------------------
{
    my $d  = fresh_root();
    my $rv = Comserv::Util::AI::CodeReviewer->new(root => $d);
    my @s  = Comserv::Util::AI::ReviewGate->steps(
        cfg           => $rv->config,
        author_models => ['grok-4.7'],
        free_models   => ['cohere/north-mini-code:free'],
    );
    is_deeply(
        [ map { "$_->{why} $_->{model} $_->{max_tokens}" } @s ],
        [
            'primary anthropic/claude-sonnet-5.5 8000',
            'primary retry anthropic/claude-sonnet-5.5 12000',
            'alternate openai/gpt-6-sol 8000',
            'free cohere/north-mini-code:free 12000',
        ],
        'steps: primary, primary retry, alternate, free'
    );
}

# ---------------------------------------------------------------------------
# 3) same-vendor skip
# ---------------------------------------------------------------------------
{
    my @s = Comserv::Util::AI::ReviewGate->steps(
        cfg           => Comserv::Util::AI::CodeReviewer->new(root => fresh_root())->config,
        author_models => ['anthropic/claude-opus-5'],
        free_models   => ['cohere/north-mini-code:free'],
    );
    is($s[0]{model}, 'openai/gpt-6-sol', 'anthropic author: first reviewer is the alternate');
    ok(!grep({ $_->{model} =~ /anthropic/ } @s), 'anthropic author: no anthropic reviewer step');

    my @s2 = Comserv::Util::AI::ReviewGate->steps(
        cfg           => Comserv::Util::AI::CodeReviewer->new(root => fresh_root())->config,
        author_models => ['anthropic/x', 'openai/y'],
        free_models   => ['cohere/north-mini-code:free'],
    );
    is_deeply([ map { $_->{why} } @s2 ], ['free'], 'anthropic+openai author: only free steps');

    my @s3 = Comserv::Util::AI::ReviewGate->steps(
        cfg           => Comserv::Util::AI::CodeReviewer->new(root => fresh_root())->config,
        author_models => ['cohere/north-mini-code'],
        free_models   => ['cohere/north-mini-code:free'],
    );
    ok(!grep({ $_->{why} eq 'free' } @s3), 'cohere author: no cohere free step');
}

# ---------------------------------------------------------------------------
# 4) cut-off then retry
# ---------------------------------------------------------------------------
{
    my $q = T::Q->new($CUT, $GOOD);
    my ($rv, $r, $u) = run_review(fresh_root(), $q);

    ok($r->{ok}, 'cut-off then retry: reviewed');
    is($r->{model}, 'anthropic/claude-sonnet-5.5', 'cut-off: model is sonnet');
    is($r->{pick}, 'primary retry', 'cut-off: pick is primary retry');
    is_deeply([ map { $_->{max_tokens} } @{ $q->calls } ], [8000, 12000], 'cut-off: token budget grew');

    my $rows = $u->rows;
    is(scalar @$rows, 2, 'cut-off: two usage rows');
    is($rows->[0]{status}, 'error', 'cut-off: first row error');
    is($rows->[1]{status}, 'success', 'cut-off: second row success');
    is($rows->[1]{metadata}{reviewer_step}, 'primary retry', 'cut-off: metadata reviewer_step');

    ok(!$rv->should_block($r), 'cut-off: should_block false');
    my $v = $rv->gate_view($r);
    is($v->{reviewed}, 1, 'cut-off: gate reviewed');
    is($v->{allow}, 1, 'cut-off: gate allows');
    is($r->{usd}, 0.084, 'cut-off: usd accumulated');
}

# ---------------------------------------------------------------------------
# 5) errors then alternate then free
# ---------------------------------------------------------------------------
{
    my $q = T::Q->new($ERR, $ERR, $ERR, $GOOD);
    my ($rv, $r) = run_review(fresh_root(), $q);

    ok($r->{ok}, 'errors then free: reviewed');
    is($r->{model}, 'cohere/north-mini-code:free', 'errors then free: model is free coder');
    is($r->{pick}, 'free', 'errors then free: pick free');
    is_deeply(
        [ map { $_->{model} } @{ $q->calls } ],
        ['anthropic/claude-sonnet-5.5', 'anthropic/claude-sonnet-5.5', 'openai/gpt-6-sol', 'cohere/north-mini-code:free'],
        'errors then free: call order'
    );
    is(scalar @{ $r->{attempts} }, 4, 'errors then free: four attempts');
    is($r->{attempts}[3]{result}, 'ok', 'errors then free: last attempt ok');
}

# ---------------------------------------------------------------------------
# 6) all models failing
# ---------------------------------------------------------------------------
{
    my $q = T::Q->new($CUT, $ERR, $ERR, $ERR);
    my ($rv, $r) = run_review(fresh_root(), $q);

    ok(!$r->{ok}, 'all failing: not reviewed');
    like($r->{reason}, qr/^all reviewer models failed/, 'all failing: reason');
    is(scalar @{ $q->calls }, 4, 'all failing: four calls');
    assert_blocked($rv, $r, 'all failing');
}

# ---------------------------------------------------------------------------
# 7) unparseable
# ---------------------------------------------------------------------------
{
    my $q = T::Q->new($JUNK, $GOOD);
    my ($rv, $r) = run_review(fresh_root(), $q);
    ok($r->{ok}, 'unparseable then good: reviewed');
    is($r->{pick}, 'primary retry', 'unparseable then good: pick primary retry');

    my $q2 = T::Q->new(($JUNK) x 4);
    my ($rv2, $r2) = run_review(fresh_root(), $q2);
    like($r2->{reason}, qr/unparseable/, 'unparseable x4: reason mentions unparseable');
    assert_blocked($rv2, $r2, 'unparseable x4');
}

# ---------------------------------------------------------------------------
# 8) cap hit goes to free reviewer
# ---------------------------------------------------------------------------
{
    my $q = T::Q->new($GOOD);
    my ($rv, $r) = run_review(fresh_root(spent => 0.499), $q);

    ok($r->{ok}, 'cap hit: reviewed by free model');
    is($r->{model}, 'cohere/north-mini-code:free', 'cap hit: model is free coder');
    is($r->{pick}, 'free', 'cap hit: pick free');
    is($r->{cap_hit}, 1, 'cap hit: flag set');
    is(scalar @{ $q->calls }, 1, 'cap hit: exactly one call');
    is($q->calls->[0]{model}, 'cohere/north-mini-code:free', 'cap hit: the call was the free model');
    is($q->calls->[0]{max_tokens}, 12000, 'cap hit: free model got 12000 tokens');
}

# ---------------------------------------------------------------------------
# 9) cap hit, no free model
# ---------------------------------------------------------------------------
{
    my $q = T::Q->new($GOOD);
    my ($rv, $r) = run_review(fresh_root(spent => 0.499, no_chains => 1), $q);

    is(scalar @{ $q->calls }, 0, 'cap, no free: no calls');
    like($r->{reason}, qr/^daily cap reached and no free reviewer model/, 'cap, no free: reason');
    assert_blocked($rv, $r, 'cap, no free');
}

# ---------------------------------------------------------------------------
# 10) disabled
# ---------------------------------------------------------------------------
{
    my $q = T::Q->new($GOOD);
    my ($rv, $r) = run_review(fresh_root(cfg => { enabled => 0 }), $q);

    is($r->{disabled}, 1, 'disabled: flag set');
    is(scalar @{ $q->calls }, 0, 'disabled: no calls');
    my $v = assert_blocked($rv, $r, 'disabled');
    like($v->{warning}, qr/reviewer disabled/, 'disabled: warning mentions disabled');
}

# ---------------------------------------------------------------------------
# 11) empty diff
# ---------------------------------------------------------------------------
{
    my $q = T::Q->new($GOOD);
    my ($rv, $r) = run_review(fresh_root(), $q, diff => '   ');

    is($r->{empty_diff}, 1, 'empty diff: flag set');
    is(scalar @{ $q->calls }, 0, 'empty diff: no calls');
    ok(!$rv->should_block($r), 'empty diff: not blocking');
    my $v = $rv->gate_view($r);
    is($v->{allow}, 1, 'empty diff: allowed');
    is($v->{blocking}, 0, 'empty diff: not blocking in gate');
    is($v->{retry}, 0, 'empty diff: no retry offered');
}

# ---------------------------------------------------------------------------
# 12) warn mode
# ---------------------------------------------------------------------------
{
    my $root = fresh_root(cfg => { mode => 'warn' });
    my ($rv, $r) = run_review($root, T::Q->new($HIGH));
    ok($r->{ok}, 'warn mode: reviewed');
    ok(!$rv->should_block($r), 'warn mode: high finding is advice only');

    my ($rv2, $r2) = run_review($root, T::Q->new($ERR, $ERR, $ERR, $ERR));
    assert_blocked($rv2, $r2, 'warn mode all failing');
}

# ---------------------------------------------------------------------------
# 13) ok without a review hash
# ---------------------------------------------------------------------------
{
    my $rv = Comserv::Util::AI::CodeReviewer->new(root => fresh_root());
    assert_blocked($rv, { ok => 1, review => undef, reason => 'x' }, 'ok but no review');

    my $v = $rv->gate_view({ ok => 0, reason => 'review call failed: 500', blocking => 0 });
    is($v->{blocking}, 1, 'gate_view blocks despite blocking => 0');
}

done_testing();
