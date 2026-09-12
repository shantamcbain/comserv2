#!/usr/bin/env perl
#
# Wire up the parts that exist on disk / in models but never made it into the
# print queue, because /3d/queue_sync reports nothing needed.
#
#  1. FLS02 (model 31) — has no nfs_path. The file FLS02_.stl exists and is
#     geometry-confirmed as the mirror of FRS02 (5.8x chamfer separation),
#     so link it and queue it.
#  2. Any other base-unit printed part with no live job.
#
# Idempotent, dry-run by default.
#
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Comserv::Model::RemoteDB;
use Comserv::Util::PartGeometry;

my $APPLY = grep { $_ eq '--apply' } @ARGV;
my $CONN  = 'db_production_mysql';
my $SITE  = '3d';

my $rdb = Comserv::Model::RemoteDB->new;
my $geo = Comserv::Util::PartGeometry->new;

my $FLS02 = '/data/nfs/hdry_parts/023030_HDRY_System_V3__Module_2/FLS02_.stl';

print "=" x 76 . "\n";
print "Wire up missing base-unit parts" . ($APPLY ? "  [APPLY]" : "  [DRY RUN]") . "\n";
print "=" x 76 . "\n\n";

# ---------- 1. link FLS02 ----------
print "--- 1. link FLS02 (model 31) ---\n";
my $m31 = $rdb->execute_query(undef, $CONN,
    'SELECT id,name,nfs_path FROM printing_3d_models WHERE id=31 AND sitename=?', [$SITE]);
my $row = ($m31 && @$m31) ? $m31->[0] : undef;
if ($row && !$row->{nfs_path} && -r $FLS02) {
    my $v = $geo->validate_part_link($row->{name}, $FLS02);
    if ($v->{ok}) {
        printf "  model 31 %-34s -> FLS02_.stl  (%.0fmm)\n",
            substr($row->{name},0,34), $v->{actual_z}//0;
        if ($APPLY) {
            my $vol = $geo->parse_stl_volume_cm3($FLS02);
            $rdb->execute_query(undef, $CONN,
                'UPDATE printing_3d_models SET nfs_path=?, stl_volume_cm3=?, stl_weight_g=?
                 WHERE id=31 AND sitename=?',
                [$FLS02, sprintf('%.4f',$vol), sprintf('%.3f',$vol*1.24), $SITE]);
            print "      LINKED (vol=".sprintf('%.4f',$vol).")\n";
        }
    } else {
        printf "  BLOCKED: %s\n", $v->{error} // 'validation failed';
    }
} elsif ($row && $row->{nfs_path}) {
    print "  already linked: $row->{nfs_path}\n";
}

# ---------- 2. find printed base-unit parts with no live job ----------
print "\n--- 2. printed base-unit parts with NO live job ---\n";
my $missing = $rdb->execute_query(undef, $CONN, q{
  SELECT b.component_item_id, b.quantity AS bom_qty, i.name, i.sku, i.item_origin
  FROM inventory_item_bom b
  JOIN inventory_items i ON i.id = b.component_item_id
  WHERE b.parent_item_id = 52 AND i.item_origin = '3d_printed'
    AND NOT EXISTS (
      SELECT 1 FROM printing_3d_jobs j
      WHERE j.sitename='3d' AND j.status IN ('queued','assigned','printing')
        AND (j.source_item_id = b.component_item_id
          OR j.model_id IN (SELECT id FROM printing_3d_models
                            WHERE item_id = b.component_item_id AND sitename='3d')))
  ORDER BY i.name
}, []);

for my $m (@$missing) {
    printf "  %-44s bom=%s  %s\n", substr($m->{name},0,44), int($m->{bom_qty}//0), $m->{sku}//'';
}

# ---------- 3. queue those that have a usable model ----------
print "\n--- 3. queue what we can ---\n";
my (@todo,@blocked);
for my $m (@$missing) {
    my $iid = $m->{component_item_id};
    my $mods = $rdb->execute_query(undef, $CONN,
        'SELECT id,name,nfs_path FROM printing_3d_models WHERE item_id=? AND sitename=? AND is_active=1',
        [$iid, $SITE]);
    unless ($mods && @$mods) { push @blocked, [$m->{name},'no model row']; next }
    my $mo = $mods->[0];
    unless ($mo->{nfs_path} && -r $mo->{nfs_path}) {
        push @blocked, [$m->{name}, 'model '.$mo->{id}.' has no readable file']; next
    }
    push @todo, { mid=>$mo->{id}, name=>$m->{name}, qty=>int($m->{bom_qty}//1),
                  sku=>$m->{sku}, item=>$iid };
}
# also FLS02 after linking
my $fls = $rdb->execute_query(undef, $CONN,
    'SELECT id,name FROM printing_3d_models WHERE id=31 AND sitename=?', [$SITE]);
if ($fls && @$fls) {
    push @todo, { mid=>31, name=>$fls->[0]{name}, qty=>1, sku=>'', item=>undef };
}

for my $t (@todo) {
    my $live = $rdb->execute_query(undef,$CONN,
      q{SELECT id FROM printing_3d_jobs WHERE model_id=? AND sitename=?
        AND status IN ('queued','assigned','printing')}, [$t->{mid}, $SITE]);
    if ($live && @$live) { printf "  skip %-40s (live #%s)\n",substr($t->{name},0,40),
        join(",",map{$_->{id}}@$live); next }
    printf "  queue model %-4d %-40s q%s\n", $t->{mid}, substr($t->{name},0,40), $t->{qty};
    if ($APPLY) {
        my $res = $rdb->execute_query(undef, $CONN, q{
            INSERT INTO printing_3d_jobs
              (sitename, model_id, source_item_id, user_id, username, status, quantity,
               item_name, notes, inventory_reserved, created_at)
            VALUES (?,?,?,0,'system','queued',?,?,?,0,NOW())
        }, [$SITE, $t->{mid}, $t->{item}, $t->{qty}, $t->{name},
            'Queued to complete base unit (sync reported nothing)']);
        my $ok = (ref $res eq 'HASH' && $res->{success}) ? 1 : 0;
        printf "      %s\n", $ok ? "QUEUED" : "FAILED: ".(($res->{error})//'?');
    }
}
for my $b (@blocked) { printf "  BLOCKED %-40s %s\n", substr($b->[0],0,40), $b->[1] }

print "\n" . "=" x 76 . "\n";
printf "queue=%d blocked=%d  %s\n", scalar(@todo), scalar(@blocked),
    $APPLY ? "(WRITTEN)" : "(dry run — --apply)";
print "=" x 76 . "\n";
