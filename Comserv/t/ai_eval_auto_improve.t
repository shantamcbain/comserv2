use strict;
use warnings;
use utf8;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use File::Temp qw(tempdir);
use File::Copy qw(copy);
use JSON ();

# Safe auto-improver (AISYSTEM items 2): auto_safe_check / auto_plan /
# auto_apply / auto_changes + one-click revert through the normal machinery.
# In-memory SQLite + temp copies of root/config and data/ai_model_chains.json.

eval { require DBD::SQLite; require SQL::Translator; 1 }
    or plan skip_all => 'DBD::SQLite + SQL::Translator needed for model-level tests';

use_ok('Comserv::Model::AI2::EvalReports');
use_ok('Comserv::Model::Schema::Ency::Result::AiEvalReport');
use_ok('Comserv::Model::Schema::Ency::Result::AiEvalProposal');

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
for my $s (qw(AiEvalReport AiEvalProposal)) {
    my $src = T::Schema->source($s);
    for my $col ($src->columns) {
        my $info = $src->column_info($col);
        delete $info->{default_value} if ref $info->{default_value};
    }
}

my $ROOT = "$FindBin::Bin/..";
sub slurp { my $f = shift; open my $fh, '<:raw', $f or die "$f: $!"; local $/; my $x = <$fh>; close $fh; $x }
sub jfile { JSON->new->utf8->decode(slurp(shift)) }
my $real_chains = slurp("$ROOT/data/ai_model_chains.json");

my $A = 'openrouter|cohere/north-mini-code:free';
my $B = 'openrouter|nvidia/nemotron-3.5-lightning:free';
my $G = 'openrouter|google/gemma-4-31b-it:free';
my $NOW = 1_800_000_000;

sub setup {
    my (%a) = @_;
    my $cfg  = tempdir(CLEANUP => 1);
    copy("$ROOT/root/config/$_", "$cfg/$_") or die "copy $_: $!" for qw(ai_grounding.json ai_usage.json);
    my $data = tempdir(CLEANUP => 1);
    my $chains = JSON->new->decode($real_chains);
    $chains->{chain_chat}   = [ $G, $A, $B, 'ollama|auto' ];
    $chains->{chain_docs}   = [ $A, $B, 'ollama|auto' ];
    $chains->{chain_coding} = [ $B, 'ollama|auto' ];
    $chains->{chain_title}  = [ $B, 'ollama|auto' ];
    $chains->{openrouter_soft_cap_day_usd} = 1.00;
    $chains->{model_caps_usd_per_day} = { 'openrouter|deepseek/deepseek-v4-pro' => 0.50 };
    open my $fh, '>:raw', "$data/ai_model_chains.json" or die; print {$fh} JSON->new->pretty->canonical->encode($chains); close $fh;
    my $schema = T::Schema->connect('dbi:SQLite:dbname=:memory:', '', '', { RaiseError => 1, PrintError => 0 });
    $schema->deploy;
    my $m = Comserv::Model::AI2::EvalReports->new(
        logger => T::Logger->new, schema_override => $schema, config_dir_override => $cfg,
        data_dir_override => $data, token_override => '',
        known_slugs_override => [ $A, $B, $G, 'ollama|auto', 'openrouter|deepseek/deepseek-v4-pro' ],
        now_override => $NOW,
        health_override => $a{health} // {},
        todo_creator => sub { die "auto-improver must never create todos\n" },
    );
    return ($m, $data, $schema);
}
my $c = T::C->new;
sub chains_now { jfile(shift . '/ai_model_chains.json') }

# ── 1. auto_safe_check ───────────────────────────────────────────────────
{
    my ($m) = setup();
    my $t = 'data/ai_model_chains.json:chain_chat';
    ok(($m->auto_safe_check($c, $t, [ $A, $B, 'ollama|auto', $G ]))[0], 'pure re-order of a chain is safe');
    my ($ok, $why) = $m->auto_safe_check($c, $t, [ $A, $B, 'ollama|auto' ]);
    ok(!$ok, 'dropping a slug is not safe'); like($why, qr/re-ordering/, '... reason');
    ok(!($m->auto_safe_check($c, $t, [ $A, $B, 'ollama|auto', $G, 'openrouter|deepseek/deepseek-v4-pro' ]))[0], 'adding a slug is not safe');
    ok(!($m->auto_safe_check($c, $t, [ $G, $A, $B, 'ollama|auto' ]))[0], 'no-op is not applied');
    my $cap = 'data/ai_model_chains.json:openrouter_soft_cap_day_usd';
    ok(($m->auto_safe_check($c, $cap, 0.5))[0], 'lowering a soft cap is safe');
    ($ok, $why) = $m->auto_safe_check($c, $cap, 1.5);
    ok(!$ok, 'raising a soft cap is refused'); like($why, qr/only be lowered/, '... caps can only be lowered');
    my $mc = 'data/ai_model_chains.json:model_caps_usd_per_day';
    ok(($m->auto_safe_check($c, $mc, { 'openrouter|deepseek/deepseek-v4-pro' => 0.25 }))[0], 'lowering a per-model cap is safe');
    ok(!($m->auto_safe_check($c, $mc, { 'openrouter|deepseek/deepseek-v4-pro' => 0.75 }))[0], 'raising a per-model cap refused');
    ok(!($m->auto_safe_check($c, $mc, { 'openrouter|deepseek/deepseek-v4-pro' => 0.25, $A => 0.1 }))[0], 'adding a cap key refused');
    ok(!($m->auto_safe_check($c, 'ai_grounding.json:mode', 'off'))[0], 'non-chain/cap targets never auto-applied');
    ok(!($m->auto_safe_check($c, 'data/ai_model_chains.json:removed', [ $G ]))[0], 'removals never auto-applied');
}

# ── 2. auto_plan: open circuit / repeated 429 -> end of chain ───────────
{
    my ($m) = setup(health => {
        $G => { state => 'open', cooldown_until => $NOW + 600, open_reason => 'probe_failed:http_429', last_failure_at => $NOW - 60 },
    });
    my $plan = $m->auto_plan($c);
    is(scalar @$plan, 1, 'one chain contains the open-circuit model');
    is_deeply($plan->[0]{value}, [ $A, $B, 'ollama|auto', $G ], 'open-circuit model moved to the end of chat');
    like($plan->[0]{rationale}, qr/circuit open/, '... why recorded');

    ($m) = setup(health => { $A => { state => 'closed', last_failure_reason => 'http_429', consecutive_failures => 3, last_failure_at => $NOW - 120 } });
    $plan = $m->auto_plan($c);
    is(scalar @$plan, 2, 'repeated 429 model demoted in both chains it is in');
    like($plan->[0]{rationale}, qr/repeated 429/, '... reason repeated 429');

    ($m) = setup(health => {
        $G => { state => 'open', cooldown_until => $NOW - 10, last_failure_at => $NOW - 7200 },
        $A => { last_failure_reason => 'http_429', consecutive_failures => 5, last_failure_at => $NOW - 7 * 3600 },
    });
    is(scalar @{ $m->auto_plan($c) }, 0, 'expired circuit and old 429s are left alone');
}

# ── 3. auto_apply -> logged -> listed -> one-click revert ────────────────
{
    my ($m, $data) = setup(health => {
        $G => { state => 'open', cooldown_until => $NOW + 600, open_reason => 'x', last_failure_at => $NOW - 60 },
    });
    my $dry = $m->auto_apply($c, dry_run => 1);
    is(scalar @{ $dry->{planned} }, 1, 'dry run plans one change');
    is_deeply(chains_now($data)->{chain_chat}, [ $G, $A, $B, 'ollama|auto' ], 'dry run writes nothing');

    my $r = $m->auto_apply($c, reason => 'test');
    ok($r->{ok}, 'auto_apply ok');
    is(scalar @{ $r->{applied} }, 1, 'one change applied');
    is_deeply(chains_now($data)->{chain_chat}, [ $A, $B, 'ollama|auto', $G ], 'chain file re-ordered');
    my $row = $r->{applied}[0];
    like($row->{who}, qr/^auto: test/, 'who = auto: <reason>');
    is_deeply($row->{before}{value}, [ $G, $A, $B, 'ollama|auto' ], 'before recorded');
    is_deeply($row->{after}, [ $A, $B, 'ollama|auto', $G ], 'after recorded');
    ok(-s "$data/ai_auto_changes.jsonl", 'data/ai_auto_changes.jsonl written');
    my @log = map { JSON->new->decode($_) } split /\n/, slurp("$data/ai_auto_changes.jsonl");
    is($log[-1]{target}, 'data/ai_model_chains.json:chain_chat', '... with target');
    ok($log[-1]{why}, '... and why');

    my $ac = $m->auto_changes($c);
    is(scalar @{ $ac->{rows} }, 1, 'auto_changes lists it');
    my $p = $ac->{rows}[0];
    is($p->{status}, 'applied', '... status applied');
    ok($p->{can_revert}, '... revertable from /ai/eval');
    like($p->{after_text}, qr/gemma-4-31b/, '... after text');
    like($p->{before_text}, qr/^\["openrouter\|google/, '... before text');

    my $rv = $m->revert($c, $p->{id}, 'Shanta');
    ok($rv->{ok}, 'one-click revert ok');
    is_deeply(chains_now($data)->{chain_chat}, [ $G, $A, $B, 'ollama|auto' ], 'revert restored the chain');
    is($m->auto_changes($c)->{rows}[0]{status}, 'reverted', 'auto_changes shows reverted');

    my $again = $m->auto_apply($c, reason => 'test');
    is(scalar @{ $again->{applied} }, 0, 'a reverted change is NOT re-applied the same day');
    like(join(' ', map { $_->{why} } @{ $again->{skipped} }), qr/already proposed today/, '... reason given');
    is_deeply(chains_now($data)->{chain_chat}, [ $G, $A, $B, 'ollama|auto' ], 'chain stays reverted');
}

# ── 4. approve_apply_as (approved report proposal logged as auto) ────────
{
    my ($m, $data, $schema) = setup();
    my $ing = $m->ingest($c, { report_date => '2026-10-01', source => 'AI usage monitor', proposals => [
        { title => 'chat lead north-mini', change_type => 'config', target => 'data/ai_model_chains.json:chain_chat',
          payload => { value => [ $A, $B, $G, 'ollama|auto' ] } } ] }, by => 'test');
    ok($ing->{ok}, 'report ingested');
    my ($pr) = $schema->resultset('AiEvalProposal')->search({ report_id => $ing->{report_id} })->all;
    my $r = $m->approve_apply_as($c, $pr->id, 'auto (Shanta approved report #11)');
    ok($r->{ok}, 'approve_apply_as ok');
    is_deeply(chains_now($data)->{chain_chat}, [ $A, $B, $G, 'ollama|auto' ], 'chat chain re-ordered');
    $pr->discard_changes;
    like($pr->approved_by, qr/^auto/, 'approved_by is auto (shows under Auto-changes)');
    is(scalar @{ $m->auto_changes($c)->{rows} }, 1, 'listed under auto-changes');
    ok($m->revert($c, $pr->id, 'Shanta')->{ok}, 'and revertable');
    is_deeply(chains_now($data)->{chain_chat}, [ $G, $A, $B, 'ollama|auto' ], 'revert restores');
}

is(slurp("$ROOT/data/ai_model_chains.json"), $real_chains, 'real data/ai_model_chains.json untouched');
done_testing();
