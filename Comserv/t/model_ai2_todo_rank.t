use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

BEGIN { use_ok('Comserv::Model::AI2::TodoRank'); }

my $m = Comserv::Model::AI2::TodoRank->new;
ok($m, 'TodoRank model instantiates');

# ── build_prompt: deterministic shuffle + JSON-only contract ──
my @batch = map {
    { record_id => 100 + $_, priority => 1, status => 1,
      subject => "todo $_", description => 'desc', todo_type => 'task',
      due_date => '2026-08-01' }
} 1 .. 20;

my ($system, $user) = $m->build_prompt(\@batch);
like($system, qr/JSON object/, 'system prompt demands JSON only');
like($system, qr/record_id/,   'contract names record_id');
unlike($user, qr/ap_score/,    'coded score not leaked as the answer');
for my $id (map { 100 + $_ } 1 .. 20) {
    like($user, qr/rec=$id\b/, "rec=$id presented");
}

# ── site/branch/role context framing ──
my ($sys3d, undef) = $m->build_prompt(\@batch, {
    sitename => '3d', branch => '3d', project_name => '3D Print Ops',
    roles => ['admin'],
});
like($sys3d, qr/SiteName=3d/,            'prompt names the SiteName');
like($sys3d, qr/'3d' branch/,            'branch framing present');
like($sys3d, qr/3D Print Ops/,           'coordination project named');
like($sys3d, qr/admin/,                  'requester roles included');
like($sys3d, qr/NO git access/i,         'no-git/no-shell constraint stated');

# ── parse_result: valid rows kept, garbage dropped, priority clamped 1..10 ──
my $res = {
    success  => 1,
    response => '{"records":['
        . '{"record_id":101,"priority":0,"todo_type":"EVENT","due_date":"2026-09-01","reason":"routine"},'
        . '{"record_id":102,"priority":11,"todo_type":"task","reason":"blocker"},'
        . '{"record_id":999,"priority":3,"reason":"not in batch"},'
        . '{"record_id":103,"priority":"nope","reason":"bad pri"}'
        . ']}',
};
my $parsed = $m->parse_result($res, [101, 102, 103]);
is($parsed->{proposals}{101}{priority},   1,      'priority clamped to min 1');
is($parsed->{proposals}{101}{todo_type}, 'event', 'todo_type normalized to lowercase');
is($parsed->{proposals}{102}{priority},  10,      'priority clamped to max 10');
ok(!exists $parsed->{proposals}{999},             'unknown record_id rejected');
ok(!exists $parsed->{proposals}{103}{priority},   'non-numeric priority dropped');
is($parsed->{rejected}, 0, 'no fully-empty proposals among valid ids');
ok(exists $parsed->{proposals}{103} && !exists $parsed->{proposals}{103}{priority},
   'reason-only row kept without a priority change');

# fenced markdown tolerated
my $fenced = $m->parse_result({
    success  => 1,
    response => "```json\n{\"records\":[{\"record_id\":101,\"priority\":5}]}\n```",
}, [101]);
is($fenced->{proposals}{101}{priority}, 5, 'markdown fence stripped');

# failed dispatch → no proposals, no crash
my $failed = $m->parse_result({ success => 0, error => 'x' }, [101]);
is(keys %{ $failed->{proposals} }, 0, 'failed result yields nothing');

# ── rank_handoff: agent-to-agent spawn (Phase A) ──
use Comserv::Model::AI2::TodoCreate;
my $tc = Comserv::Model::AI2::TodoCreate->new;
{
    package _StubRank;
    our $gather_calls = 0;
    sub new { bless {}, shift }
    sub gather_calls { my $n = $gather_calls; return $n ? int($n) : 1; }
    our %gather_args;
    our $response = '{"records":[{"record_id":77,"priority":2,"todo_type":"task","reason":"unblocks W1"}]}';
    sub gather_todos {
        my ($self, $c, %o) = @_;
        $gather_calls++;
        %_StubRank::gather_args = %o;
        return ([{ record_id => 77, subject => 'wire x', priority => 3, status => 1 }], {});
    }
    sub build_prompt { ('SYS', 'USER') }
    sub run_batch {
        my ($self, $c, $target, $sys, $usr) = @_;
        return { success => 1, response => $response };
    }
    sub parse_result {
        my ($self, $res, $ids) = @_;
        return Comserv::Model::AI2::TodoRank->new->parse_result($res, $ids);
    }

    package _StubC;
    sub model {
        my ($self, $name) = @_;
        return $name eq 'AI2::TodoRank' ? bless({}, '_StubRank') : undef;
    }
}

my $note = $tc->rank_handoff(bless({}, '_StubC'),
    todo_id => 77, project_id => 287, sitename => 'CSC', model => 'grok-4.6');
ok($note->{suggestion},            'handoff returns a suggestion');
like($note->{suggestion}, qr/[Pp]riority 2/, 'suggestion names proposed priority');
like($note->{suggestion}, qr/unblocks W1/, 'suggestion carries the reason');
is(_StubRank->gather_calls, 1,     'TodoRank gathered exactly once');

# no model → skip, never guess (FocusTune no-default-model rule)
my $skip = $tc->rank_handoff(bless({}, '_StubC'),
    todo_id => 77, project_id => 287, sitename => 'CSC');
is($skip->{skipped}, 'no rank_model given', 'skips without an explicit model');

# todo outside gather scope → skipped cleanly
my $out = $tc->rank_handoff(bless({}, '_StubC'),
    todo_id => 999, project_id => 287, sitename => 'CSC', model => 'm');
ok($out->{skipped},                'foreign todo id skipped, not errored');

done_testing();
