use strict; use warnings; use Test::More;
use Comserv::Util::AI::DecisionRank;
my $DR = 'Comserv::Util::AI::DecisionRank';
my @rows = (
  { record_id => 1, priority => 1, status => '1', due_date => '2026-10-01', subject => 'Update docs page', description => 'typo cleanup' },
  { record_id => 2, priority => 5, status => '1', due_date => '2026-12-31', subject => 'Login broken', description => '<b>All users</b> get 500 on login' },
  { record_id => 3, priority => 3, status => '2', subject => 'No content row' },
);
my ($state, $key_of) = $DR->build_state(\@rows);
unlike($state, qr/\bP[0-9]\b|due=|s=/, 'state has no field values');
like($state, qr/All users get 500 on login/, 'description included, html stripped');
my $q = $DR->build_questions($key_of);
is(scalar(keys %$q), 6, 'two questions per todo');
is($q->{t2}{type}, 'score'); is($q->{t2_why}{type}, 'choice');
is($DR->field_score({}, 0, 3), 1, 'field_score top (class call)');
is(Comserv::Util::AI::DecisionRank::field_score({}, 2, 3), 0, 'field_score bottom');
like(Comserv::Util::AI::DecisionRank::reason_text({ why => 'broken', why_p => 0.6, content => 0.9 }), qr/broken/, 'reason_text');
my $cache = { weights => { content => 0.7, fields => 0.3 }, rows => {
  1 => { content => 0.1, why => 'housekeeping', why_p => 0.5 },
  2 => { content => 1.0, why => 'broken', why_p => 0.8 },
} };
my $out = $DR->apply_order([ map { {%$_} } @rows ], $cache, {});
is_deeply([ map { $_->{record_id} } @$out ], [2, 1, 3], 'content outranks field order; unscored stays after');
ok($out->[0]{decision_used} && $out->[0]{decision_reason} =~ /broken/, 'reason attached');
ok(abs($out->[0]{decision_score} - 0.7) < 1e-9, 'blend = 0.7*1 + 0.3*0 (field rank 2 of 2)');
my $out2 = $DR->apply_order([ map { {%$_} } @rows ], { weights => { content => 0, fields => 1 }, rows => $cache->{rows} }, {});
is_deeply([ map { $_->{record_id} } @$out2 ], [1, 2, 3], 'weights configurable: fields-only keeps field order');
done_testing;
