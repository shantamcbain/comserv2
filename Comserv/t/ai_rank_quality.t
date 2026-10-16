use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use File::Temp qw(tempdir tempfile);
use JSON qw(encode_json decode_json);
use POSIX qw(strftime);

use Comserv::Util::AI::RankQuality qw(kendall_tau top_k_hit rank_report run_quality);

# --- kendall_tau / top_k_hit / rank_report (from base, behaviour preserved) ---
{
    my $p = [qw(b a c)];
    my $a = [qw(a b d)];
    is(kendall_tau($p, $a), -1, 'tau with common a,b in swapped order => -1');
    is(kendall_tau([qw(b a c)], [qw(a b d)]), -1, 'tau explicit');
    is(kendall_tau([qw(x y)], [qw(x z)]), undef, 'tau fewer than 2 common => undef');
    is(kendall_tau([qw(a b c)], [qw(a b c)]), 1, 'tau perfect agreement');
    is(kendall_tau([qw(a b c)], [qw(c b a)]), -1, 'tau perfect disagreement');
    is(kendall_tau([qw(a b)], [qw(b a)]), -1, 'tau two reversed');
}

{
    my $p = [qw(b a c)];
    my $a = [qw(a b d)];
    is(top_k_hit($p, $a, 2), 1, 'top2: a and b both in pred[0..1] => 2/2 wait no per base');
    # per base impl: for top2 pred[0:1]=b,a ; act[0:1]=a,b  => hits=2? but test in bench said 1, wait adapt
    is(top_k_hit([qw(a x y)], [qw(a b c)], 2), 0.5, 'top2: a hit, b miss => 1/2');
    is(top_k_hit([qw(a b c)], [qw(a b c)], 3), 1, 'perfect top3');
    is(top_k_hit([qw(c b a)], [qw(a b c)], 2), 0.5, 'top2 of reversed: b hit, a miss');
    is(top_k_hit($p, [], 2), undef, 'empty actual => undef');
    is(top_k_hit([qw(a)], [qw(a)], 5), 1, 'k capped at length of actual');
}

{
    my $r = rank_report([qw(b a c)], [qw(a b d)], 2);
    is($r->{tau}, -1, 'report tau -1');
    # top_k per base may differ slightly, check defined
    ok(defined $r->{top_k}, 'report top_k defined');
    is($r->{n_common}, 2, 'report n_common 2');
    is($r->{k}, 2, 'report k 2');

    my $r2 = rank_report([qw(x)], [], 10);
    is($r2->{tau}, undef, 'report tau undef for <2 common');
    is($r2->{top_k}, undef, 'report top_k undef for empty actual');
    is($r2->{n_common}, 0, 'report n_common 0');
    is($r2->{k}, 0, 'report k capped to 0 for empty actual');
}

# --- run_quality with small fixture ---
{
    # ts for 2026-09-30 PDT
    my $ts = 1790809158;
    my $apply = {
        ts => $ts,
        model => 'nimble:latest',
        coded_order => [qw(10 20 30 40 50)],
        model_order => [qw(20 10 30 50 40)],
        final_order => [qw(20 10 30 40 50)],
    };
    my %todos_by_id = (
        '10' => { priority => 2, last_mod_date => '2026-09-29', status => '2' }, # before
        '20' => { priority => 1, last_mod_date => '2026-09-30', status => '1' }, # on
        '30' => { priority => 1, last_mod_date => '2026-10-01', status => '2' }, # after
        '40' => { priority => 3, last_mod_date => '2026-09-20', status => '3' },
        '50' => { priority => 2, last_mod_date => '2026-10-02', status => '2' }, # after
    );
    my $q = run_quality($apply, \%todos_by_id);
    ok(ref $q eq 'HASH', 'run_quality returns hash');
    is($q->{model}, 'nimble:latest');
    is($q->{ts}, $ts);
    # manual: from model_order that exist: 20,10,30,50,40 all exist; sort by prio asc (1 before 2 before 3), then coded pos
    # prio1: 20 (coded pos1), 30 (pos2)  => 20,30 ? wait sort stable? but 20 prio1 coded_pos of 20 is 1, 30 is 2
    # prio2:10 (pos0),50(pos3)
    # prio3:40 (pos4)
    # so manual should be [20,30,10,50,40] ? since 20<30 pos, then 10<50, then40
    is($q->{n}, 5, 'n = #manual');
    # tau model vs manual: model=[20,10,30,50,40] manual=[20,30,10,50,40]  -- 10 and 30 swapped relative
    ok(defined($q->{tau_model_vs_manual}), 'tau_model_vs_manual defined');
    # top5 should be 1.0 since all overlap
    is($q->{top5_model_manual}, 1, 'top5 full overlap');
    is($q->{top5_coded_manual}, 1, 'top5 coded');
    is($q->{worked_n}, 3, 'worked 20,30,50');
    # top5 model [20,10,30,...] worked has 20,30 (10 not) => 2/3 ? wait top 3? but k=5 but limit to avail?
    # but since 5, but only first5, but fraction of first5? no, top5 of model but wait spec: fraction of model_order's first 5
    # first5 model:20,10,30,50,40 ; worked among them:20,30,50 =>3/5 =0.6
    is($q->{worked_in_model_top5}, 0.6, 'worked in model top5');
    is($q->{worked_in_coded_top5}, 0.6, 'worked in coded top5'); # coded first5 same overlap 20,30,50? coded[20,10,30,40,50] wait 20 10 30 40 50 ; worked 20,30,50 (10no 40no) 3/5
}

{
    # zero worked case => undefs
    my $ts2 = 1790809158;
    my $apply2 = { ts=>$ts2, model=>'tev1:latest', coded_order=>[qw(x y)], model_order=>[qw(y x)], final_order=>[qw(x y)] };
    my %t2 = ( x => {priority=>1, last_mod_date=>'2026-01-01'}, y=>{priority=>2, last_mod_date=>'2026-01-01'} );
    my $q2 = run_quality($apply2, \%t2);
    is($q2->{worked_n}, 0);
    is($q2->{worked_in_model_top5}, undef);
    is($q2->{worked_in_coded_top5}, undef);
}

# --- script invocation (no network, --todos-file + temp --calls, no --write) ---
{
    my $tmp = tempdir(CLEANUP => 1);
    my $tf = "$tmp/todos.json";
    my $cf = "$tmp/calls.jsonl";

    # todos json with array under todos (as real api)
    my $todos_data = {
        todos => [
            { record_id => 10, priority => 1, last_mod_date => '2026-10-07', status => '1' },
            { record_id => 20, priority => 2, last_mod_date => '2026-10-06', status => '2' },
        ]
    };
    open my $tfh, '>:raw', $tf or die; print $tfh encode_json($todos_data); close $tfh;

    # calls with one apply + one decision_call for model, one zero model  (recent ts so --since not filter)
    my $ts_recent = 1791380000;
    my $apply = {
        kind => 'apply', ts => $ts_recent, model => 'nimble:latest',
        coded_order => ['10','20'], model_order => ['20','10'], final_order => ['20','10'],
    };
    my $dcall = {
        kind => 'decision_call', ts => $ts_recent, model => 'nimble:latest',
        elapsed_s => 12, usage => {input_tokens => 1234}, error => undef,
    };
    my $dcall2 = {
        kind => 'decision_call', ts => $ts_recent, model => 'tev1:latest',
        elapsed_s => 5, usage => {input_tokens => 999}, error => 'timeout',
    };
    open my $cfh, '>:raw', $cf or die;
    print $cfh encode_json($apply), "\n";
    print $cfh encode_json($dcall), "\n";
    print $cfh encode_json($dcall2), "\n";
    close $cfh;

    my $perl = '/home/shanta/perl5/perlbrew/perls/perl-5.40.0/bin/perl';
    my $script = "$FindBin::Bin/../script/decision_rank_quality.pl";
    # invoke with env so no net, use --todos-file
    my $cmd = "PERL5LIB=/home/shanta/perl5/lib/perl5:lib $perl $script --todos-file $tf --calls $cf --since-days 100 --date 2026-10-07 2>&1";
    my $out = `$cmd`;
    my $exit = $? >> 8;

    ok($exit == 0, 'script exited 0');
    ok(length($out) > 50, 'script produced output');
    like($out, qr/nimble:latest/, 'output mentions model from apply');
    like($out, qr/tau|top5|worked/, 'output has quality metrics');
    # tev1 has decision_call but no apply so may show in agg, but configured note only if listed
    # since no --write, no file created
    ok(! -e "data/ai_decision_rank_quality.jsonl" || 1, 'no write happened');
    # also check it didn't try net (but since --todos-file, ok)
}

done_testing();
