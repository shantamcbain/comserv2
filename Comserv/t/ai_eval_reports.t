use strict;
use warnings;
use utf8;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use File::Temp qw(tempdir);
use File::Copy qw(copy);
use JSON ();

# Daily AI Eval Reports (AISYSTEM plan §5d). No live DB: an in-memory SQLite
# schema holding only the two eval Results. No real config: temp copies.

eval { require DBD::SQLite; require SQL::Translator; 1 }
    or plan skip_all => 'DBD::SQLite + SQL::Translator needed for model-level tests';

BEGIN {
    use_ok('Comserv::Util::AI::EvalAllowList');
    use_ok('Comserv::Model::AI2::EvalReports');
    use_ok('Comserv::Model::Schema::Ency::Result::AiEvalReport');
    use_ok('Comserv::Model::Schema::Ency::Result::AiEvalProposal');
}

{
    package T::Schema;
    use base 'DBIx::Class::Schema';
    __PACKAGE__->register_class('AiEvalReport',   'Comserv::Model::Schema::Ency::Result::AiEvalReport');
    __PACKAGE__->register_class('AiEvalProposal', 'Comserv::Model::Schema::Ency::Result::AiEvalProposal');
}
{
    package T::Logger;
    sub new { bless { lines => [] }, shift }
    sub log_with_details { my ($s, $c, $lvl, $f, $l, $sub, $msg) = @_; push @{ $s->{lines} }, "$lvl $sub $msg"; 1 }
}
{
    package T::C;
    sub new { bless { session => {}, stash => {} }, shift }
    sub model { die "no Catalyst models in tests\n" }
    sub session { $_[0]{session} }
    sub stash { $_[0]{stash} }
}

# MySQL-only column defaults (CURRENT_TIMESTAMP ON UPDATE ...) do not parse in
# SQLite; the model always sets timestamps itself, so drop them for the test DB.
for my $s (qw(AiEvalReport AiEvalProposal)) {
    my $src = T::Schema->source($s);
    for my $col ($src->columns) {
        my $info = $src->column_info($col);
        delete $info->{default_value} if ref $info->{default_value};
    }
}

sub fresh_schema {
    my $schema = T::Schema->connect('dbi:SQLite:dbname=:memory:', '', '', { RaiseError => 1, PrintError => 0 });
    $schema->deploy;
    return $schema;
}

my $REAL_CFG = "$FindBin::Bin/../root/config";
sub temp_config {
    my $dir = tempdir(CLEANUP => 1);
    copy("$REAL_CFG/$_", "$dir/$_") or die "copy $_: $!" for qw(ai_grounding.json ai_usage.json);
    return $dir;
}
sub slurp { my $f = shift; open my $fh, '<:raw', $f or die "$f: $!"; local $/; my $x = <$fh>; close $fh; $x }
sub jfile { JSON->new->utf8->decode(slurp(shift)) }

my $SEED_FILE = "$FindBin::Bin/../data/ai_eval_inbox/2026-09-25-ai-usage-monitor.json";
my $seed = jfile($SEED_FILE);
my $real_grounding_before = slurp("$REAL_CFG/ai_grounding.json");
my $real_usage_before     = slurp("$REAL_CFG/ai_usage.json");

my @todo_calls;
sub model {
    my (%a) = @_;
    return Comserv::Model::AI2::EvalReports->new(
        logger              => T::Logger->new,
        schema_override     => $a{schema},
        config_dir_override => $a{cfg} || temp_config(),
        inbox_dir_override  => $a{inbox},
        token_override      => (exists $a{token} ? $a{token} : ''),
        todo_creator        => $a{todo} || sub { my ($c, %t) = @_; push @todo_calls, \%t; +{ ok => 1, todo_id => 9000 + scalar(@todo_calls) } },
    );
}
my $c = T::C->new;

# ── 1. allow-list ────────────────────────────────────────────────────────
{
    my $al = Comserv::Util::AI::EvalAllowList->new;
    my ($ok, $msg) = $al->validate('ai_grounding.json:evil_key', 'x');
    ok(!$ok, 'unknown key rejected'); like($msg, qr/not allow-listed/, '... with reason');
    ok(!($al->validate('../../etc/passwd:mode', 'off'))[0], 'path-ish target rejected');
    ok(!($al->validate(undef, 'off'))[0], 'missing target rejected');
    is_deeply([ $al->validate('ai_grounding.json:mode', 'enforce') ], [1, 'enforce'], 'mode enforce ok');
    ok(!($al->validate('ai_grounding.json:mode', 'yolo'))[0], 'mode enum rejects bad value');
    ok(!($al->validate('ai_grounding.json:mode', undef))[0], 'missing value rejected');
    ok(!($al->validate('ai_grounding.json:mode', { a => 1 }))[0], 'ref value rejected');
    is_deeply([ $al->validate('ai_grounding.json:max_snippets', '8') ], [1, 8], 'int normalized');
    ok(!($al->validate('ai_grounding.json:max_snippets', 0))[0],    'int below range rejected');
    ok(!($al->validate('ai_grounding.json:max_snippets', 21))[0],   'int above range rejected');
    ok(!($al->validate('ai_grounding.json:max_snippets', '6.5'))[0], 'non-integer rejected');
    ok(!($al->validate('ai_grounding.json:postcheck_action', 'delete'))[0], 'postcheck enum');
    is_deeply([ $al->validate('ai_grounding.json:web_search', JSON::false) ], [1, 0], 'bool from JSON false');
    ok(!($al->validate('ai_grounding.json:web_search', 2))[0], 'bool rejects 2');
    is_deeply([ $al->validate('ai_usage.json:supergrok_monthly_limit_usd', '12.5') ], [1, 12.5], 'number ok');
    ok(!($al->validate('ai_usage.json:supergrok_monthly_limit_usd', 'inf'))[0], 'inf rejected');
    ok(!($al->validate('ai_usage.json:alert_percent', 101))[0], 'alert_percent max 100');
    ok(!($al->validate('ai_usage.json:xai_auto_fill', JSON::false))[0], 'auto-fill billing flags are NOT allow-listed');
    my $al2 = Comserv::Util::AI::EvalAllowList->new(
        allow => { 'router.json:free_order' => { type => 'slug_list' } },
        known_slugs => [ 'openrouter|a:free', 'openrouter|b:free' ]);
    ok(($al2->validate('router.json:free_order', [ 'openrouter|a:free' ]))[0], 'slug_list known slug ok');
    ok(!($al2->validate('router.json:free_order', [ 'openrouter|zzz:free' ]))[0], 'slug_list unknown slug rejected');
    ok(scalar @{ $al->describe } >= 8, 'describe lists allow-list');
}

# ── 2. payload validation ────────────────────────────────────────────────
{
    my $m = model(schema => fresh_schema());
    my (undef, $e) = $m->validate_payload([]);
    ok(@$e, 'array body rejected');
    (undef, $e) = $m->validate_payload({ summary => 'x' });
    ok((grep { /report_date/ } @$e), 'report_date required');
    (undef, $e) = $m->validate_payload({ report_date => '2026-02-30' });
    ok((grep { /report_date/ } @$e), 'impossible date rejected');
    (undef, $e) = $m->validate_payload({ report_date => '2026-09-25', proposals => {} });
    ok((grep { /proposals must be an array/ } @$e), 'proposals must be array');
    (undef, $e) = $m->validate_payload({ report_date => '2026-09-25', proposals => [ { title => 'x', change_type => 'magic' } ] });
    ok((grep { /change_type/ } @$e), 'bad change_type rejected');
    (undef, $e) = $m->validate_payload({ report_date => '2026-09-25', proposals => [ { change_type => 'code' } ] });
    ok((grep { /title is required/ } @$e), 'proposal title required');
    (undef, $e) = $m->validate_payload({ report_date => '2026-09-25', metrics => [1] });
    ok((grep { /metrics must be a JSON object/ } @$e), 'metrics must be object');
    my ($r, $e2, $w) = $m->validate_payload({ report_date => '2026-09-25',
        proposals => [ { title => 'Bad key', change_type => 'config', target => 'ai_grounding.json:nope', payload => { value => 1 } } ] });
    is(scalar @$e2, 0, 'non-allow-listed config proposal is not a hard error');
    ok((grep { /not allow-listed/ } @$w), '... but is reported as a warning');
    ($r, $e2) = $m->validate_payload($seed);
    is(scalar @$e2, 0, 'seed file validates');
    is($r->{source}, 'AI usage monitor', 'source from seed');
}

# ── 3. graceful before tables exist ──────────────────────────────────────
{
    my $empty = T::Schema->connect('dbi:SQLite:dbname=:memory:', '', '', { RaiseError => 1, PrintError => 0 });
    my $m = model(schema => $empty);
    my $r = $m->ingest($c, $seed, by => 't');
    is($r->{ok}, 0, 'ingest fails without tables');
    is($r->{error}, 'table_missing', '... error=table_missing');
    is($r->{http}, 503, '... http 503');
    is($m->list_reports($c)->{table_missing}, 1, 'list: table_missing');
    is($m->get_report($c, 1)->{table_missing}, 1, 'detail: table_missing');
    is($m->latest_summary($c)->{table_missing}, 1, 'usage card: table_missing');
    my $v = $m->ingest($c, { summary => 'no date' });
    is($v->{http}, 400, 'validation error beats table check (400)');
}

# ── 4. ingest / upsert / dedupe ──────────────────────────────────────────
my $schema = fresh_schema();
my $cfg    = temp_config();
my $m      = model(schema => $schema, cfg => $cfg);
{
    my $r = $m->ingest($c, $seed, by => 'ingest-token');
    ok($r->{ok}, 'seed ingested') or diag explain $r;
    is($r->{created}, 1, 'report created');
    is($r->{proposals_created}, 3, '3 proposals created');
    my $rid = $r->{report_id};

    my $r2 = $m->ingest($c, $seed, by => 'ingest-token');
    is($r2->{report_id}, $rid, 're-post updates the same report');
    is($r2->{created}, 0, '... not created again');
    is($r2->{proposals_created}, 0, '... no duplicate proposals');
    is($r2->{proposals_skipped}, 3, '... 3 skipped as existing');
    is($schema->resultset('AiEvalReport')->count, 1, 'one report row');
    is($schema->resultset('AiEvalProposal')->count, 3, 'three proposal rows');

    ok($m->save_notes($c, $rid, 'tune: watch nemotron', 'admin1')->{ok}, 'admin notes saved');
    my %changed = %$seed;
    $changed{summary} = 'updated summary';
    $changed{proposals} = [
        { title => '  switch HERMES idle   model to flash ', change_type => 'workstation' },   # same title, other case/spaces
        { title => 'Enforce grounding', change_type => 'config', target => 'ai_grounding.json:mode', payload => { value => 'enforce' } },
    ];
    my $r3 = $m->ingest($c, \%changed, by => 'ingest-token');
    is($r3->{proposals_created}, 1, 'case/space-insensitive title dedupe; only the new one added');
    my $rep = $schema->resultset('AiEvalReport')->find($rid);
    is($rep->summary, 'updated summary', 'summary updated on upsert');
    is($rep->admin_notes, 'tune: watch nemotron', 'admin_notes survive re-ingest');
    my %other = (%$seed, source => 'Other monitor', proposals => []);
    my $r4 = $m->ingest($c, \%other);
    isnt($r4->{report_id}, $rid, 'different source = different report (unique date+source)');

    my $list = $m->list_reports($c);
    is(scalar @{ $list->{rows} }, 2, 'list shows 2 reports');
    my ($row) = grep { $_->{id} == $rid } @{ $list->{rows} };
    is($row->{key}{bot_pct_left}, 90, 'key metric: bot % left');
    is($row->{key}{openrouter_balance}, 19.49, 'key metric: OpenRouter balance');
    is($row->{counts}{proposed}, 4, 'counts: 4 proposed');
    my $d = $m->get_report($c, $rid);
    ok((grep { $_->[0] eq 'openrouter.caps.day_usd' && $_->[1] == 1.65 } @{ $d->{report}{metrics_flat} }), 'metrics flattened');
    like($d->{report}{markdown_html}, qr/<h1>|<h2>/, 'markdown rendered');
    is(scalar @{ $d->{proposals} }, 4, 'detail lists proposals');
    is($m->latest_summary($c)->{open}, 5 - 1, 'usage card counts open proposals');
}

# ── 5. markdown safety ───────────────────────────────────────────────────
{
    my $h = $m->render_markdown("# T\n\n<script>alert(1)</script>\n\n[x](javascript:alert(1)) [ok](https://openrouter.ai) [rel](/ai/usage) [pr](//evil.example)");
    unlike($h, qr/<script/i, 'raw HTML escaped');
    unlike($h, qr/href="javascript:/i, 'javascript: link neutralized');
    like($h, qr/href="https:\/\/openrouter.ai"/, 'https link kept');
    like($h, qr/href="\/ai\/usage"/, 'relative link kept');
    unlike($h, qr/href="\/\/evil/, 'protocol-relative link neutralized');
}

# ── 6. status transitions + apply / revert ───────────────────────────────
{
    my $prs = $schema->resultset('AiEvalProposal');
    my $cfgp = "$cfg/ai_grounding.json";
    my $orig_bytes = slurp($cfgp);
    my $orig = jfile($cfgp);
    my ($p) = $prs->search({ title => 'Enforce grounding' })->all;

    my $r = $m->apply($c, $p->id, 'admin1');
    ok(!$r->{ok}, 'cannot apply a proposed (unapproved) proposal');
    like($r->{error}, qr/status 'proposed'/, '... reason names the status');
    is(slurp($cfgp), $orig_bytes, '... config untouched');

    ok($m->reject($c, $p->id, 'admin1')->{ok}, 'reject');
    ok(!$m->apply($c, $p->id, 'admin1')->{ok}, 'rejected proposal cannot be applied');
    ok(!$m->revert($c, $p->id, 'admin1')->{ok}, 'rejected proposal cannot be reverted');
    ok($m->approve($c, $p->id, 'admin1')->{ok}, 're-approve after reject');
    $p->discard_changes;
    is($p->status, 'approved', 'status approved');
    is($p->approved_by, 'admin1', 'approved_by recorded');
    ok(!$p->todo_id, 'approving config creates no todo');

    $r = $m->apply($c, $p->id, 'admin1');
    ok($r->{ok}, 'apply approved allow-listed config') or diag explain $r;
    is(jfile($cfgp)->{mode}, 'enforce', 'config value written');
    my $after = slurp($cfgp);
    like($after, qr/\A\{\n  "_doc": /, 'top-level key order and 2-space format kept');
    ok(!(grep { /^\.ai_eval_/ } do { opendir(my $dh, $cfg); readdir $dh }), 'no temp files left behind');
    $p->discard_changes;
    is($p->status, 'applied', 'status applied');
    is($p->applied_by, 'admin1', 'applied_by recorded');
    is_deeply(JSON->new->decode($p->before_value), { present => 1, value => $orig->{mode} }, 'before_value captured');
    like($p->result, qr/applied by admin1: ai_grounding.json:mode "shadow" -> "enforce"/, 'apply logged in result');

    ok(!$m->apply($c, $p->id, 'admin1')->{ok}, 'cannot apply twice');
    ok(!$m->approve($c, $p->id, 'admin1')->{ok}, 'applied cannot be re-approved');
    $r = $m->revert($c, $p->id, 'admin2');
    ok($r->{ok}, 'revert applied proposal');
    is_deeply(jfile($cfgp), $orig, 'revert restores before-value exactly (decoded)');
    is(slurp($cfgp), $orig_bytes, 'revert restores the file byte-for-byte');
    $p->discard_changes;
    is($p->status, 'reverted', 'status reverted');
    like($p->result, qr/reverted by admin2/, 'revert logged in result');
    ok(!$m->revert($c, $p->id, 'admin1')->{ok}, 'cannot revert twice');

    # Absent key: apply adds it, revert removes it again.
    my $g = jfile($cfgp); delete $g->{web_search};
    open my $fh, '>:raw', $cfgp or die; print $fh JSON->new->utf8->pretty->encode($g); close $fh;
    my $no_ws = jfile($cfgp);
    my $rid = $p->get_column('report_id');
    my $np = $prs->create({ report_id => $rid, title => 'ws off', change_type => 'config',
        target => 'ai_grounding.json:web_search', payload_json => '{"value":0}', status => 'proposed', created_at => '2026-09-25 00:00:00' });
    ok($m->approve($c, $np->id, 'a')->{ok} && $m->apply($c, $np->id, 'a')->{ok}, 'apply to absent key');
    is(jfile($cfgp)->{web_search}, 0, 'key added');
    ok($m->revert($c, $np->id, 'a')->{ok}, 'revert absent key');
    is_deeply(jfile($cfgp), $no_ws, 'key removed again on revert');

    # Not allow-listed / bad value: approve OK, apply refused, file unchanged.
    my $before = slurp($cfgp);
    my $bad = $prs->create({ report_id => $rid, title => 'evil', change_type => 'config',
        target => 'ai_grounding.json:evil', payload_json => '{"value":"x"}', status => 'proposed', created_at => '2026-09-25 00:00:00' });
    ok($m->approve($c, $bad->id, 'a')->{ok}, 'approve non-allow-listed config');
    $r = $m->apply($c, $bad->id, 'a');
    ok(!$r->{ok}, 'apply refused for unknown key'); like($r->{error}, qr/not allow-listed/, '... reason');
    my $badv = $prs->create({ report_id => $rid, title => 'yolo', change_type => 'config',
        target => 'ai_grounding.json:mode', payload_json => '{"value":"yolo"}', status => 'proposed', created_at => '2026-09-25 00:00:00' });
    $m->approve($c, $badv->id, 'a');
    $r = $m->apply($c, $badv->id, 'a');
    ok(!$r->{ok}, 'apply refused for bad value'); like($r->{error}, qr/not in/, '... enum reason');
    $badv->discard_changes;
    is($badv->status, 'approved', 'failed apply leaves status approved');
    like($badv->result, qr/FAILED/, 'failed apply recorded in result');
    is(slurp($cfgp), $before, 'config unchanged after refused applies');

    # Code / workstation: approve -> todo, never applied.
    @todo_calls = ();
    my ($code) = $prs->search({ title => 'Stop counting zero-token Ollama calls as success' })->all;
    $r = $m->approve($c, $code->id, 'admin1');
    ok($r->{ok}, 'approve code proposal');
    $code->discard_changes;
    ok($code->todo_id, 'todo_id stored');
    is(scalar @todo_calls, 1, 'todo creator called once');
    is($todo_calls[0]{project_code}, 'AISYSTEM', 'todo goes to project AISYSTEM');
    like($todo_calls[0]{subject}, qr/^\[AI eval\] Stop counting/, 'todo subject');
    $r = $m->apply($c, $code->id, 'admin1');
    ok(!$r->{ok}, 'code proposal can never be applied');
    like($r->{error}, qr/only change_type=config/, '... reason');
    $m->reject($c, $code->id, 'admin1'); $m->approve($c, $code->id, 'admin1');
    is(scalar @todo_calls, 1, 're-approve keeps the existing todo (no duplicate)');

    my $mfail = model(schema => $schema, cfg => $cfg, todo => sub { +{ ok => 0, error => 'no project with project_code AISYSTEM' } });
    my ($ws) = $prs->search({ title => 'Switch Hermes idle model to flash' })->all;
    $r = $mfail->approve($c, $ws->id, 'admin1');
    ok($r->{ok}, 'approve still succeeds when todo creation fails');
    $ws->discard_changes;
    ok(!$ws->todo_id, 'no todo_id on failure');
    like($ws->result, qr/todo NOT created: no project/, 'failure reason recorded in result');

    ok(!$m->transition($c, 'explode', $ws->id, 'a')->{ok}, 'unknown action refused');
    ok(!$m->approve($c, 999999, 'a')->{ok}, 'missing proposal refused');
}

# ── 7. ingest token ──────────────────────────────────────────────────────
{
    my $mt = model(schema => $schema, token => '');
    is($mt->check_token($c, 'anything-long-enough'), 'not_configured', 'no token configured -> refused');
    $mt = model(schema => $schema, token => 'short');
    is($mt->check_token($c, 'short'), 'not_configured', 'too-short token treated as not configured');
    $mt = model(schema => $schema, token => 'a' x 32);
    is($mt->check_token($c, undef), 'bad_token', 'missing token -> bad_token');
    is($mt->check_token($c, 'b' x 32), 'bad_token', 'wrong token -> bad_token');
    is($mt->check_token($c, 'a' x 32), 'ok', 'right token -> ok');
}

# ── 8. inbox import ──────────────────────────────────────────────────────
{
    my $inbox = tempdir(CLEANUP => 1);
    copy($SEED_FILE, "$inbox/2026-09-25-ai-usage-monitor.json") or die;
    open my $fh, '>', "$inbox/zz-broken.json" or die; print $fh '{not json'; close $fh;
    my $mi = model(schema => fresh_schema(), inbox => $inbox);
    my $r = $mi->import_inbox($c, by => 'admin1');
    is($r->{count}, 2, 'two inbox files seen');
    ok($r->{files}[0]{ok} && $r->{files}[0]{proposals_created} == 3, 'seed imported with 3 proposals');
    ok(!$r->{files}[1]{ok} && $r->{files}[1]{error} =~ /bad_json/, 'broken file reported, not fatal');
    my $again = $mi->import_inbox($c, by => 'admin1');
    is($again->{files}[0]{proposals_created}, 0, 're-import is idempotent');
    ok(-f "$inbox/2026-09-25-ai-usage-monitor.json", 'inbox file left in place');
}

# ── 9. glossary + real config untouched ──────────────────────────────────
{
    require Comserv::Util::AI::Glossary;
    ok(Comserv::Util::AI::Glossary->definition($_), "glossary defines $_")
        for ('Eval Report', 'Eval Proposal', 'Allow-listed Config Change');
    unlike(Comserv::Util::AI::Glossary->system_prompt_text, qr/Eval Report/, 'admin terms stay out of the model prompt');
    is(slurp("$REAL_CFG/ai_grounding.json"), $real_grounding_before, 'real ai_grounding.json untouched by tests');
    is(slurp("$REAL_CFG/ai_usage.json"),     $real_usage_before,     'real ai_usage.json untouched by tests');
}

# ── 10. controller access gate (same admin rule as /ai/usage) ────────────
SKIP: {
    eval { require Comserv::Controller::AI::Eval; 1 } or skip "controller did not load: $@", 9;
    {
        package T::Res;
        sub new { bless { status => 200 }, shift }
        sub status { my $s = shift; $s->{status} = shift if @_; $s->{status} }
        sub content_type { my $s = shift; $s->{ct} = shift if @_; $s->{ct} }
        sub body { my $s = shift; $s->{body} = shift if @_; $s->{body} }
        sub redirect { my $s = shift; $s->{redirect} = shift if @_; $s->{redirect} }
        package T::Req;
        sub new { bless {}, shift }
        sub path { 'ai/eval' }
        sub uri { 'http://x/ai/eval' }
        package T::CC;
        sub new { my ($cl, %s) = @_; bless { session => {%s}, res => T::Res->new, req => T::Req->new }, $cl }
        sub session { $_[0]{session} }
        sub response { $_[0]{res} }
        sub req { $_[0]{req} }
        sub uri_for { '/user/login' }
    }
    my $ctl = bless { logging => T::Logger->new }, 'Comserv::Controller::AI::Eval';
    my $anon = T::CC->new;
    is($ctl->_require_admin($anon), 0, 'anonymous denied');
    is($anon->response->redirect, '/user/login', '... redirected to login');
    my $member = T::CC->new(username => 'bob', roles => ['member']);
    is($ctl->_require_admin($member), 0, 'member denied');
    is($member->response->status, 403, '... 403');
    my $str = T::CC->new(username => 'bob', roles => 'member,editor');
    is($ctl->_is_admin($str), 0, 'string roles without admin denied');
    my $adm = T::CC->new(username => 'ann', roles => ['member', 'admin']);
    is($ctl->_require_admin($adm), 1, 'admin allowed');
    is($ctl->_is_admin(T::CC->new(username => 'ann', roles => 'user,Admin')), 1, 'string roles with admin allowed (same rule as usage)');
    ok(!$ctl->_is_admin(T::CC->new(username => 'x', roles => ['sysadmin'])), 'role must be exactly admin');
    ok(!$ctl->_is_admin(T::CC->new()), 'no roles denied');
}

done_testing();
