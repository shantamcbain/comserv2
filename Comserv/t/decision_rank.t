use strict;
use warnings;
use utf8;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use File::Temp qw(tempdir);
use JSON qw(encode_json);
use Comserv::Util::AI::DecisionRank;

# Decision-model ordering (AISYSTEMPlan 5f).
#
# Covers: cache read/TTL/branch isolation, the confidence gate, and that
# apply_order never disturbs a row group it does not own. The live model call is
# NOT made here (nimble cold is ~130s) — script/compute_decision_rank.pl is the
# end-to-end proof for that half; this file proves the render-time half, which is
# what runs on every page load.

my $dir  = tempdir(CLEANUP => 1);
my $file = "$dir/ai_rank_order.json";
local $ENV{COMSERV_DECISION_RANK_FILE} = $file;

sub row {
    my (%a) = @_;
    return { record_id => $a{id}, subject => $a{subject} || "todo $a{id}",
             status => $a{status} || '2', priority => $a{priority} || 5,
             project_id => $a{project_id} || 280, ap_score => $a{ap_score} || 0 };
}

# --- no cache file at all ---------------------------------------------------
is(Comserv::Util::AI::DecisionRank->read_cache('aisystem'), undef,
   'no cache file -> undef');

# --- a cache with one branch ------------------------------------------------
open my $fh, '>:raw', $file or die $!;
print {$fh} encode_json({
    version  => 1,
    branches => {
        aisystem => {
            model => 'nimble:latest', gate => 0.30, window => 20,
            computed_at => time,
            rows => {
                2 => { score => 1.80, confidence => 0.60 },
                3 => { score => 1.20, confidence => 0.10 },
                4 => { score => 0.90, confidence => 0.90 },
            },
        },
    },
});
close $fh;

my $c = Comserv::Util::AI::DecisionRank->read_cache('aisystem');
ok(ref $c eq 'HASH', 'cache read for the branch that exists');
is($c->{model}, 'nimble:latest', 'model carried through');
is(scalar keys %{ $c->{rows} }, 3, 'three scored rows');
is(Comserv::Util::AI::DecisionRank->read_cache('otherbranch'), undef,
   'a branch with no entry -> undef');
is(Comserv::Util::AI::DecisionRank->read_cache(undef), undef, 'undef branch -> undef');

# --- TTL --------------------------------------------------------------------
{
    my $stale = "$dir/stale.json";
    open my $o, '>:raw', $stale or die $!;
    print {$o} encode_json({ version => 1, branches => { aisystem => {
        model => 'x', gate => 0.3, computed_at => time - (7 * 3600),
        rows => { 2 => { score => 1, confidence => 0.9 } } } } });
    close $o;
    local $ENV{COMSERV_DECISION_RANK_FILE} = $stale;
    is(Comserv::Util::AI::DecisionRank->read_cache('aisystem'), undef,
       'stale cache is ignored at render time');
    ok(ref Comserv::Util::AI::DecisionRank->read_cache('aisystem', ignore_ttl => 1) eq 'HASH',
       'ignore_ttl still returns it');
}
