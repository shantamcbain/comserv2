#!/usr/bin/env perl
#
# Fill every remaining gap between "what the base unit needs" and "what the
# queue will actually produce".
#
# Scope (user 2026-09-02): add ALL missing parts from the worksheet, printed or
# not, that the build still needs.
#
#  1. Link FLS02 (model 31) to FLS02_.stl — geometry-confirmed mirror of FRS02.
#  2. Add printed sub-lines to the wheel-kit BOM (item 99): 8 wheel halves,
#     4 tires, 4 support feet. Kit BOM previously had hardware ONLY, which is
#     why the support structure never appeared.
#  3. Queue every printed base-unit part that has no live job.
#
# Idempotent, dry-run by default. Every link is geometry-validated first.
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
my $BASE  = 52;   # HDRY Base unit
my $KIT   = 99;   # Wheel kit

my $rdb = Comserv::Model::RemoteDB->new;
my $geo = Comserv::Util::PartGeometry->new;

my $FLS02 = '/data/nfs/hdry_parts/023030_HDRY_System_V3__Module_2/FLS02_.stl';

print "=" x 78 . "\n";
print "Fill all remaining base-unit gaps" . ($APPLY ? "  [APPLY]" : "  [DRY RUN]") . "\n";
print "=" x 78 . "\n\n";

# ---------------------------------------------------------------- 1. FLS02
print "--- 1. link FLS02 (model 31) ---\n";
my $m31 = $rdb->execute_query(undef,$CONN,
  'SELECT id,name,nfs_path FROM printing_3d_models WHERE id=31 AND sitename=?',[$SITE]);
my $r31 = ($m31 && @$m31) ? $m31->[0] : undef;
if ($r31 && !$r31->{nfs_path} && -r $FLS02) {
    my $v = $geo->validate_part_link($r31->{name}, $FLS02);
    if ($v->{ok}) {
        my $vol = $geo->parse_stl_volume_cm3($FLS02);
        printf "  model 31 %-34s -> FLS02_.stl  (%.0fmm, vol %.2f)\n",
            substr($r31->{name},0,34), $v->{actual_z}//0, $vol;
        if ($APPLY) {
            $rdb->execute_query(undef,$CONN,
              'UPDATE printing_3d_models SET nfs_path=?, stl_volume_cm3=?, stl_weight_g=?
               WHERE id=31 AND sitename=?',
              [$FLS02, sprintf('%.4f',$vol), sprintf('%.3f',$vol*1.24), $SITE]);
            print "      LINKED\n";
        }
    } else { printf "  BLOCKED: %s\n", $v->{error}//'validation failed' }
} elsif ($r31 && $r31->{nfs_path}) { print "  already linked: $r31->{nfs_path}\n" }
else { print "  (model 31 not found or file unreadable)\n" }

# ------------------------------------------------- 2. wheel kit printed BOM
print "\n--- 2. wheel-kit printed BOM lines (item $KIT) ---\n";
# component items we need on the kit BOM:
#   48 HDRY printed wheels (set of 4) -> 4 halves? actual half model is model 48
#   64 HDRY Wheel tire (Gomma)
#   63 HDRY Wheel support foot
my %KITQTY = (
  48 => 2,   # model 48 is "HDRY printed wheels (set of 4)" -> wheel halves x2 per kit? see note
  64 => 4,   # tires
  63 => 4,   # feet
);
# NOTE: model 48 is named "set of 4" but maps to Wheel.stl (a single half).
# Per user: 1 wheel = 2 halves + 1 tire; 4 wheels = 8 halves + 4 tires.
# So halves = 8. Keep 8 and let the user confirm.
$KITQTY{48} = 8;

for my $mid (sort keys %KITQTY) {
    my $mo = $rdb->execute_query(undef,$CONN,
      'SELECT id,name,item_id FROM printing_3d_models WHERE id=? AND sitename=?',[$mid,$SITE]);
    next unless $mo && @$mo;
    my $m = $mo->[0];
    my $iid = $m->{item_id};
    unless ($iid) { printf "  model %-3d %-34s  NO item_id - cannot add BOM line\n",
                    $mid, substr($m->{name},0,34); next }
    my $ex = $rdb->execute_query(undef,$CONN,
      'SELECT id,quantity FROM inventory_item_bom WHERE parent_item_id=? AND component_item_id=?',
      [$KIT,$iid]);
    if ($ex && @$ex) {
        printf "  model %-3d %-34s  BOM exists (q%s)\n",$mid,substr($m->{name},0,34),$ex->[0]{quantity};
        next;
    }
    printf "  model %-3d %-34s  ADD to kit BOM q%s\n",$mid,substr($m->{name},0,34),$KITQTY{$mid};
    if ($APPLY) {
        my $res = $rdb->execute_query(undef,$CONN,
          q{INSERT INTO inventory_item_bom (parent_item_id, component_item_id, quantity, unit)
            VALUES (?,?,?,'each')}, [$KIT,$iid,$KITQTY{$mid}]);
        my $ok = (ref $res eq 'HASH' && $res->{success}) ? 1:0;
        printf "      %s\n", $ok ? "ADDED" : "FAILED: ".(($res->{error})//'?');
    }
}

# ------------------------------------------- 3. queue printed parts missing
print "\n--- 3. printed base-unit parts with no live job ---\n";
my $missing = $rdb->execute_query(undef,$CONN, q{
  SELECT b.component_item_id, b.quantity AS bom_qty, i.name, i.sku
  FROM inventory_item_bom b
  JOIN inventory_items i ON i.id=b.component_item_id
  WHERE b.parent_item_id=? AND i.item_origin='3d_printed'
    AND NOT EXISTS (
      SELECT 1 FROM printing_3d_jobs j
      WHERE j.sitename='3d' AND j.status IN ('queued','assigned','printing')
        AND (j.source_item_id=b.component_item_id
          OR j.model_id IN (SELECT id FROM printing_3d_models
                            WHERE item_id=b.component_item_id AND sitename='3d')))
  ORDER BY i.name
}, [$BASE]);

my (@q,@blk);
for my $m (@$missing) {
    my $mods = $rdb->execute_query(undef,$CONN,
      'SELECT id,name,nfs_path FROM printing_3d_models
       WHERE item_id=? AND sitename=? AND is_active=1', [$m->{component_item_id},$SITE]);
    unless ($mods && @$mods) { push @blk,[$m->{name},'no model row']; next }
    my $mo=$mods->[0];
    unless ($mo->{nfs_path} && -r $mo->{nfs_path}) {
        push @blk,[$m->{name},'model '.$mo->{id}.' unreadable file']; next }
    push @q, {mid=>$mo->{id}, name=>$m->{name}, qty=>int($m->{bom_qty}//1),
              item=>$m->{component_item_id}};
}
# FLS02 explicitly (model 31, may not be on BOM via item_id)
if ($r31) {
    my $live = $rdb->execute_query(undef,$CONN,
      q{SELECT id FROM printing_3d_jobs WHERE model_id=31 AND sitename='3d'
        AND status IN ('queued','assigned','printing')},[]);
    push @q, {mid=>31,name=>$r31->{name},qty=>1,item=>undef} unless ($live && @$live);
}

for my $t (@q) {
    printf "  queue model %-4d %-42s q%s\n",$t->{mid},substr($t->{name},0,42),$t->{qty};
    if ($APPLY) {
        my $res = $rdb->execute_query(undef,$CONN, q{
          INSERT INTO printing_3d_jobs
            (sitename, model_id, source_item_id, user_id, username, status, quantity,
             item_name, notes, inventory_reserved, created_at)
          VALUES (?,?,?,0,'system','queued',?,?,?,0,NOW())
        }, [$SITE,$t->{mid},$t->{item},$t->{qty},$t->{name},
            'Gap-fill: base unit had no live job for this part']);
        my $ok=(ref $res eq 'HASH' && $res->{success})?1:0;
        printf "      %s\n",$ok?"QUEUED":"FAILED: ".(($res->{error})//'?');
    }
}
for my $b (@blk) { printf "  BLOCKED %-42s %s\n",substr($b->[0],0,42),$b->[1] }

print "\n".("=" x 78)."\n";
printf "queued=%d blocked=%d  %s\n", scalar(@q), scalar(@blk),
  $APPLY?"(WRITTEN)":"(dry run — --apply)";
print "=" x 78 ."\n";
