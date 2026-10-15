use strict;
use warnings;
use utf8;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

# Golden Data / Anti-Hallucination tests. Stubs only: no live DB, no live model.

BEGIN {
    use_ok('Comserv::Util::AI::Glossary');
    use_ok('Comserv::Util::AI::Ledger');
    use_ok('Comserv::Model::AI2::GoldenData');
    use_ok('Comserv::Model::AI2::Grounding');
}

my $FALLBACK = "I don't have golden data for this yet, so I can't give you a verified answer.";

# ── stubs ────────────────────────────────────────────────────────────────
{
    package T::Logger;
    sub new { bless { lines => [] }, shift }
    sub log_with_details { my ($s, $c, $lvl, $f, $l, $sub, $msg) = @_; push @{ $s->{lines} }, "$lvl $sub $msg"; 1 }
}
{
    package T::Store;   # stands in for Comserv::Model::AI2::GoldenData
    sub new { my ($cl, %a) = @_; bless { golden => [], candidates => [], table_missing => 0, %a }, $cl }
    sub list_golden     { my $s = shift; { rows => $s->{golden},     table_missing => $s->{table_missing} } }
    sub list_candidates { my $s = shift; { rows => $s->{candidates}, table_missing => $s->{table_missing} } }
}
{
    package T::AIModel;  # $c->model('AI') — records Ledger writes
    sub new { bless { logged => [] }, shift }
    sub log_usage { my ($s, $c, %a) = @_; push @{ $s->{logged} }, \%a; 1 }
}
{
    package T::AICtrl;   # $c->controller('AI') with a canned SearXNG result
    sub new { my ($cl, $ctx) = @_; bless { ctx => $ctx, calls => 0 }, $cl }
    sub _do_web_search { my $s = shift; $s->{calls}++; return ($s->{ctx}, 'searxng') }
}
{
    package T::C;
    sub new { my ($cl, %a) = @_; bless { ai => T::AIModel->new, ctrl => undef, %a }, $cl }
    sub model {
        my ($s, $name) = @_;
        return $s->{ai} if $name eq 'AI';
        die "no DB in tests\n";          # DBEncy: prior web hits must degrade quietly
    }
    sub controller { $_[0]->{ctrl} }
}

sub grounding {
    my (%a) = @_;
    my $g = Comserv::Model::AI2::Grounding->new(
        logger          => T::Logger->new,
        golden_store    => $a{store} || T::Store->new,
        config_override => { mode => 'enforce', max_snippets => 6, max_total_chars => 6000,
                             postcheck_action => 'strip', web_search => 0, %{ $a{cfg} || {} } },
    );
    return $g;
}

# ── glossary ─────────────────────────────────────────────────────────────
is(Comserv::Util::AI::Glossary->definition('Golden Data'),
   'organization-agreed truth fed to AI models. It comes from corporate policy, verified research in our databases, and verified documentation of how the app runs. A record is golden only once it is agreed/verified (status=golden). Existing in the DB is not enough.',
   'Golden Data definition is the agreed wording');
like(Comserv::Util::AI::Glossary->system_prompt_text, qr/Status today: EMPTY \/ NOT YET QUALIFIED/, 'glossary states store is empty');
for my $t ('Candidate Data', 'Grounding Context', 'Hallucination', 'Ungrounded Generation', 'Router', 'Ledger', 'Budget', 'Effectiveness') {
    ok(Comserv::Util::AI::Glossary->definition($t), "glossary defines $t");
}
is_deeply([ Comserv::Util::AI::Glossary->known_domains ], [qw(policy research app_docs todo customer)], 'known domains');
is(Comserv::Model::AI2::Grounding::FALLBACK_NO_GOLDEN(), $FALLBACK, 'fallback constant is the exact sentence');

# ── 1. empty golden store -> Ungrounded path, structured miss ────────────
{
    my $store = T::Store->new(table_missing => 1);
    my $g = grounding(store => $store);
    my $c = T::C->new;
    my @thinking;
    my $turn = $g->prepare_turn($c, prompt => 'What is echinacea used for?', args => {}, thinking => \@thinking);
    is($turn->{mode}, 'enforce', 'empty: mode enforce');
    ok($turn->{enforce}, 'empty: factual question is enforced');
    ok(!$turn->{messages}, 'empty: no model payload built (no call for invented facts)');
    is_deeply($turn->{miss}, { grounded => 0, reason => 'no_golden_data', answer => $FALLBACK }, 'empty: structured miss');
    is($turn->{ledger}{grounded}, 0, 'empty: ledger grounded=0');
    is($turn->{ledger}{golden_table_missing}, 1, 'empty: ledger notes table missing');

    my $reply = $g->miss_reply($c, $turn, args => {}, duration_ms => 3, thinking => \@thinking);
    is($reply->{response}, $FALLBACK, 'empty: user-visible answer is exactly the fallback');
    is($reply->{provider}, 'ai2-grounding', 'empty: no provider called');
    is(scalar @{ $c->{ai}{logged} }, 1, 'empty: one Ledger row');
    is($c->{ai}{logged}[0]{grounding}{grounded}, 0, 'empty: Ledger row grounded=0');
    is($c->{ai}{logged}[0]{total_tokens}, 0, 'empty: Ledger row 0 tokens');
}

# ── 2. one golden row -> GOLDEN label, citation required ─────────────────
{
    my $store = T::Store->new(golden => [
        { id => 12, domain => 'research', title => 'Echinacea', status => 'golden',
          canonical_text => 'Echinacea is traditionally used to support the immune system.',
          source_ref => 'research:ency_herb_tb:4' },
        { id => 13, domain => 'research', title => 'Not reviewed', status => 'candidate',
          canonical_text => 'This row was returned by mistake and must not be labelled golden.' },
    ]);
    my $g = grounding(store => $store);
    my $c = T::C->new;
    my $turn = $g->prepare_turn($c, prompt => 'What is echinacea used for?', args => {}, thinking => []);
    is(scalar @{ $turn->{snippets} }, 1, 'golden: only status=golden rows used as Golden Data');
    my $s = $turn->{snippets}[0];
    is($s->{id}, 'G:12', 'golden: id G:12');
    is($s->{label}, 'GOLDEN', 'golden: labelled GOLDEN');
    is($s->{source}, 'research:ency_herb_tb:4', 'golden: source_ref kept');
    like($s->{retrieved_at}, qr/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/, 'golden: retrieved_at ISO8601');
    is($turn->{ledger}{grounded}, 1, 'golden: ledger grounded=1');
    is($turn->{ledger}{golden_hit_count}, 1, 'golden: golden_hit_count=1');

    my $msgs = $turn->{messages};
    is($msgs->[0]{role}, 'system', 'golden: first message is system');
    like($msgs->[0]{content}, qr/GLOSSARY/, 'golden: system has glossary');
    like($msgs->[0]{content}, qr/Answer ONLY from the GROUNDING/, 'golden: system has answer-only policy');
    like($msgs->[0]{content}, qr/Cite the snippet id/, 'golden: citation instruction');
    like($msgs->[-1]{content}, qr/1\. \[G:12\] \[GOLDEN\] source=research:ency_herb_tb:4/, 'golden: GROUNDING block labels GOLDEN');
    like($msgs->[-1]{content}, qr/QUESTION: What is echinacea used for\?/, 'golden: user question last');

    # uncited factual answer is stripped -> fallback; flagged
    my $t2 = { %$turn, ledger => { %{ $turn->{ledger} } } };
    my $ans = $g->finish_turn($c, $t2, 'Echinacea is used to shorten colds in adults by 3 days.', []);
    is($ans, $FALLBACK, 'golden: uncited claim stripped -> fallback');
    is($t2->{ledger}{flagged_count}, 1, 'golden: flagged_count=1');

    my $pc = $g->post_check('Echinacea supports the immune system [G:12]. It also cures cancer in 2 weeks.',
        $turn->{snippets}, action => 'flag');
    is($pc->{flagged_count}, 1, 'golden: flag mode counts the uncited sentence');
    like($pc->{answer}, qr/cures cancer in 2 weeks\. \[uncited — unverified\]/, 'golden: uncited sentence flagged');
    is_deeply($pc->{cited_ids}, ['G:12'], 'golden: cited id recorded');

    my $t3 = { %$turn, ledger => { %{ $turn->{ledger} } } };
    my $ok = $g->finish_turn($c, $t3, 'Echinacea is traditionally used to support the immune system [G:12].', []);
    like($ok, qr/\[G:12\]/, 'golden: cited answer kept');
    unlike($ok, qr/^Unverified/, 'golden: golden-grounded answer not labelled candidate');
    is($t3->{ledger}{flagged_count}, 0, 'golden: nothing flagged');

    my $pc2 = $g->post_check('It is used for colds [G:99].', $turn->{snippets}, action => 'strip');
    is($pc2->{flagged_count}, 1, 'golden: citing an id not in the Grounding Context does not count');
}

# ── 3. candidate-only -> unverified label, never golden ──────────────────
{
    my $store = T::Store->new(candidates => [
        { id => 5, domain => 'app_docs', title => 'Draft note', status => 'candidate',
          canonical_text => 'Echinacea page draft: used for colds.', source_ref => 'app_docs:Documentation/Herbs' },
    ]);
    my $ctrl = T::AICtrl->new("Web search results (searxng) for: \"echinacea\"\n\n## Echinacea - Wiki\nURL: https://example.org/echinacea\nEchinacea is a genus of flowering plants.\n\nUse the above search results to answer accurately.\n");
    my $g = grounding(store => $store, cfg => { web_search => 1 });
    my $c = T::C->new(ctrl => $ctrl);
    my $turn = $g->prepare_turn($c, prompt => 'Tell me about echinacea', args => {}, thinking => []);
    is($ctrl->{calls}, 1, 'candidate: SearXNG web search consulted');
    my @ids = map { $_->{id} } @{ $turn->{snippets} };
    is_deeply(\@ids, ['C:gd-5', 'C:web-1'], 'candidate: store candidate + web hit ids');
    ok(!(grep { $_->{label} ne 'CANDIDATE' } @{ $turn->{snippets} }), 'candidate: every snippet labelled CANDIDATE');
    is($turn->{snippets}[1]{source}, 'web:searxng:https://example.org/echinacea', 'candidate: web source_ref convention');
    is($turn->{ledger}{golden_hit_count}, 0, 'candidate: golden_hit_count=0');
    is($turn->{ledger}{candidate_hit_count}, 2, 'candidate: candidate_hit_count=2');
    my $block = $turn->{messages}[-1]{content};
    like($block, qr/\[CANDIDATE — unverified\]/, 'candidate: block says unverified');
    unlike($block, qr/\[GOLDEN\]/, 'candidate: block never says GOLDEN');

    my $ans = $g->finish_turn($c, $turn, 'Echinacea is a genus of flowering plants [C:web-1].', []);
    like($ans, qr/^Unverified — Candidate Data only/, 'candidate: answer labelled unverified');
    unlike($ans, qr/\bverified answer\b|\bis golden\b/i, 'candidate: answer never claims golden/verified');
}

# ── 4. modes / opt-outs ──────────────────────────────────────────────────
{
    my $g = grounding(cfg => { mode => 'shadow' });
    my $c = T::C->new;
    my $t = $g->prepare_turn($c, prompt => 'What is echinacea used for?', args => {}, thinking => []);
    is($t->{mode}, 'shadow', 'default config shadow');
    ok(!$t->{enforce}, 'shadow: not enforced (live chat unchanged)');
    is($t->{ledger}{reason}, 'shadow_not_enforced', 'shadow: ledger reason');
    is($t->{ledger}{grounded}, 0, 'shadow: Ungrounded Generation recorded');

    my $t2 = $g->prepare_turn($c, prompt => 'What is echinacea used for?', args => { grounding => 'enforce' }, thinking => []);
    ok($t2->{enforce}, 'request grounding=enforce opts in');

    my $e = grounding();
    ok(!$e->prepare_turn($c, prompt => 'Write me a poem about echinacea', args => {}, thinking => [])->{enforce}, 'creative prompt not enforced');
    ok(!$e->prepare_turn($c, prompt => 'What is echinacea?', args => { creative => 1 }, thinking => [])->{enforce}, 'creative flag opts out');
    is($e->prepare_turn($c, prompt => 'What is echinacea?', args => { grounding => 'off' }, thinking => [])->{mode}, 'off', 'grounding=off');
    is($e->prepare_turn($c, prompt => 'What is this function?', args => { agent_id => 'code' }, thinking => [])->{mode}, 'off', 'code agent off');
}

# ── 5. GoldenData service: never promotes, degrades without table ────────
{
    package T::RS;
    sub new { my ($cl, %a) = @_; bless { created => [], %a }, $cl }
    sub search { my $s = shift; die $s->{die} if $s->{die}; return $s }
    sub single { undef }
    sub all { () }
    sub next { undef }
    sub create { my ($s, $h) = @_; push @{ $s->{created} }, $h; return T::Row->new(77) }
    package T::Row; sub new { bless { id => $_[1] }, $_[0] } sub id { $_[0]{id} }
    package T::Schema; sub new { bless { rs => $_[1] }, $_[0] } sub resultset { $_[0]{rs} }
    package main;

    my $rs = T::RS->new;
    my $gd = Comserv::Model::AI2::GoldenData->new(logger => T::Logger->new, schema_override => T::Schema->new($rs));
    my $r = $gd->ingest_candidate(undef, domain => 'Policy', title => 'Refunds', canonical_text => 'Refunds within 30 days.',
        source_ref => 'policy:refunds', status => 'golden');
    ok($r->{ok}, 'ingest ok');
    is($rs->{created}[0]{status}, 'candidate', 'ingest_candidate forces status=candidate even when golden requested');
    is($rs->{created}[0]{domain}, 'policy', 'domain lowercased');
    like($rs->{created}[0]{content_hash}, qr/^[0-9a-f]{64}$/, 'content_hash sha256');

    my $missing = T::RS->new(die => "DBI Exception: Table 'ency.ai_golden_data' doesn't exist");
    my $gd2 = Comserv::Model::AI2::GoldenData->new(logger => T::Logger->new, schema_override => T::Schema->new($missing));
    my $lg = $gd2->list_golden(undef, query => 'echinacea');
    is($lg->{table_missing}, 1, 'list_golden: table_missing flag');
    is_deeply($lg->{rows}, [], 'list_golden: empty rows');
    is($gd2->list_candidates(undef)->{table_missing}, 1, 'list_candidates: table_missing flag');
    is($gd2->counts_by_status(undef)->{table_missing}, 1, 'counts_by_status: table_missing flag');
    ok(!$gd2->ingest_candidate(undef, title => 't', canonical_text => 'x')->{ok}, 'ingest fails soft without table');
}

# ── 6. Ledger helper ─────────────────────────────────────────────────────
{
    my $meta = {};
    my $cols = Comserv::Util::AI::Ledger->prepare(undef, { grounded => 0, golden_hit_count => 0, feature => 'ai2_chat' }, $meta);
    is_deeply($cols, {}, 'Ledger: no columns written without a schema probe');
    is($meta->{grounding}{grounded}, 0, 'Ledger: grounding mirrored into metadata');
    like(Comserv::Util::AI::Ledger->log_suffix({ grounded => 1, golden_hit_count => 1, snippet_ids => ['G:12'] }),
        qr/grounded=1 golden_hit_count=1 candidate_hit_count=0 flagged_count=0 feature=ai2_chat snippet_ids=G:12/, 'Ledger: log suffix');
}

done_testing();
