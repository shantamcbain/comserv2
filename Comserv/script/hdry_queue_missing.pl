#!/usr/bin/env perl
#
# hdry_queue_missing.pl — queue the printed parts the base unit needs but that
# have no live job, using the quantities the user confirmed (2026-09-02):
#
#   * one wheel = 2 half-wheels + 1 tire   -> 4 wheels = 8 halves + 4 tires
#   * wheel support foot = 4 (one per wheel)
#   * door hinges/latches: 1 each of L and R (two hinges per door assembly)
#
# Idempotent: skips any part that already has a live (queued/assigned/printing) job.
# Dry-run by default.
#
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Comserv::Model::RemoteDB;

my $APPLY = grep { $_ eq '--apply' } @ARGV;
my $CONN  = 'db_production_mysql';
my $SITE  = '3d';

my $rdb = Comserv::Model::RemoteDB->new;

# model name (exact) => [ qty, note ]
my @QUEUE = (
  ['HDRY Female hinge left (FHL)',  1, 'door hardware'],
  ['HDRY Female hinge right (FHR)', 1, 'door hardware'],
  ['HDRY Male hinge left (MHL)',    1, 'door hardware'],
  ['HDRY Male hinge right (MHR)',   1, 'door hardware'],
  ['HDRY Hinge latch left (HLL)',   1, 'door hardware'],
  ['HDRY Hinge latch right (HLR)',  1, 'door hardware'],
  ['HDRY Door handle',              1, 'door hardware'],
  ['HDRY Wheel support foot',       4, 'one per wheel'],
  ['HDRY Wheel tire (Gomma)',       4, 'one per wheel (TPU)'],
  ['HDRY Wheel half wide (variant, unidentified)', 0, 'SKIP - variant not identified'],
);

print "=" x 76 . "\n";
print "HDRY queue missing parts" . ($APPLY ? "  [APPLY]" : "  [DRY RUN]") . "\n";
print "=" x 76 . "\n\n";

my (@todo, @skipped, @blocked);

for my $q (@QUEUE) {
    my ($name, $qty, $note) = @$q;

    if ($qty < 1) { push @skipped, [$name, $note]; next }

    my $m = $rdb->execute_query(undef, $CONN,
        'SELECT id, name FROM printing_3d_models WHERE name=? AND sitename=? AND is_active=1',
        [$name, $SITE]);
    unless ($m && @$m) { push @blocked, [$name, 'model not found']; next }
    my $mid = $m->[0]{id};

    my $live = $rdb->execute_query(undef, $CONN,
        q{SELECT id FROM printing_3d_jobs WHERE model_id=? AND sitename=?
          AND status IN ('queued','assigned','printing')}, [$mid, $SITE]);
    if ($live && @$live) {
        push @skipped, [$name, 'already live job #' . join(',', map { $_->{id} } @$live)];
        next;
    }

    push @todo, { mid => $mid, name => $name, qty => $qty, note => $note };
}

print "--- TO QUEUE (" . scalar(@todo) . ") ---\n";
for my $t (@todo) {
    printf "  model %-4d %-46s q%s   (%s)\n", $t->{mid}, substr($t->{name},0,46), $t->{qty}, $t->{note};
    if ($APPLY) {
        my $res = $rdb->execute_query(undef, $CONN, q{
            INSERT INTO printing_3d_jobs
              (sitename, model_id, user_id, username, status, quantity,
               item_name, notes, inventory_reserved, created_at)
            VALUES (?,?,?,?, 'queued', ?,?,?,0,NOW())
        }, [ $SITE, $t->{mid}, 0, 'system', $t->{qty},
             $t->{name}, 'Auto-queued: ' . $t->{note} ]);
        my $ok = (ref $res eq 'HASH' && $res->{success}) ? 1 : 0;
        printf "      %s\n", $ok ? "QUEUED" : "FAILED: " . (($res->{error}) // 'unknown');
    }
}

if (@skipped) {
    print "\n--- SKIPPED ---\n";
    printf "  %-46s %s\n", substr($_->[0],0,46), $_->[1] for @skipped;
}
if (@blocked) {
    print "\n--- BLOCKED ---\n";
    printf "  %-46s %s\n", substr($_->[0],0,46), $_->[1] for @blocked;
}

print "\n" . "=" x 76 . "\n";
printf "queue=%d skipped=%d blocked=%d  %s\n",
    scalar(@todo), scalar(@skipped), scalar(@blocked),
    $APPLY ? "(WRITTEN)" : "(dry run — --apply to write)";
print "=" x 76 . "\n";
