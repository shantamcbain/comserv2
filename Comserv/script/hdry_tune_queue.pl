use strict; use warnings;
use lib '/home/shanta/.comserv/worktrees/3d/Comserv/Comserv/lib';
use Comserv::Model::RemoteDB;
my $r = Comserv::Model::RemoteDB->new;
my $APPLY = grep { $_ eq '--apply' } @ARGV;

# Objective: one base unit, printed as needed, no stocking.
# So every live job quantity must equal BOM qty exactly.
#
# ACTIONS:
#   * Cancel the 6 duplicate gasket jobs (#82-87) - exact dupes of #76-81
#   * Reduce #57 BBL01 q2->1 and #60 BLS01 q2->1  (BOM says 1)
#   * Requeue the 8 printed parts that have no live job at all
#   * Leave purchased parts alone (screws/magnets/bearings - not printed)
#   * Leave the 4 'completed' parts alone (already printed, incl. 3 wrong ones)

print "=" x 78 . "\n";
print "Queue tuning " . ($APPLY ? "[APPLY]" : "[DRY RUN]") . "\n";
print "=" x 78 . "\n\n";

# ---------- 1. cancel duplicate gasket jobs ----------
my @CANCEL = (
  [82,'TPU gasket 215 mm  dup of #76'],
  [83,'TPU gasket 150 mm  dup of #77'],
  [84,'TPU gasket 180 mm  dup of #78'],
  [85,'TPU gasket 358 mm  dup of #79'],
  [86,'TPU gasket 378 mm  dup of #80'],
  [87,'TPU gasket 1582 mm dup of #81'],
);
print "--- CANCEL duplicate gasket jobs ---\n";
for my $c (@CANCEL) {
    my ($id,$why) = @$c;
    my $row = $r->execute_query(undef,'db_production_mysql',
        q{SELECT id,status,item_name,quantity FROM printing_3d_jobs WHERE id=? AND sitename='3d'},[$id]);
    my $j = ($row && @$row) ? $row->[0] : undef;
    unless ($j) { printf "  #%-4s NOT FOUND\n",$id; next }
    if ($j->{status} ne 'queued') { printf "  #%-4s skip (status=%s)\n",$id,$j->{status}; next }
    printf "  #%-4s %-34s q%s  %s\n",$id,substr($j->{item_name}//'?',0,34),$j->{quantity}//'?',$why;
    if ($APPLY) {
        $r->execute_query(undef,'db_production_mysql',
            q{UPDATE printing_3d_jobs SET status='cancelled', completed_at=NOW() WHERE id=? AND sitename='3d'},[$id]);
    }
}

# ---------- 2. reduce over-quantity jobs ----------
print "\n--- REDUCE over-quantity jobs to BOM ---\n";
my @REDUCE = (
  [57, 1, 'BBL01: 2 -> 1 (BOM)'],
  [60, 1, 'BLS01: 2 -> 1 (BOM)'],
);
for my $rd (@REDUCE) {
    my ($id,$newq,$why) = @$rd;
    my $row = $r->execute_query(undef,'db_production_mysql',
        q{SELECT id,status,item_name,quantity FROM printing_3d_jobs WHERE id=? AND sitename='3d'},[$id]);
    my $j = ($row && @$row) ? $row->[0] : undef;
    unless ($j) { printf "  #%-4s NOT FOUND\n",$id; next }
    printf "  #%-4s %-34s q%s -> q%s  %s\n",$id,
        substr($j->{item_name}//'?',0,34), $j->{quantity}//'?', $newq, $why;
    if ($APPLY) {
        $r->execute_query(undef,'db_production_mysql',
            q{UPDATE printing_3d_jobs SET quantity=? WHERE id=? AND sitename='3d'},[$newq,$id]);
    }
}

# ---------- 3. report what still needs queueing ----------
print "\n--- PRINTED parts with NO live job (need queueing separately) ---\n";
my $missing = $r->execute_query(undef,'db_production_mysql', q{
  SELECT b.component_item_id, b.quantity AS bom_qty, i.name, i.sku
  FROM inventory_item_bom b
  JOIN inventory_items i ON i.id=b.component_item_id
  WHERE b.parent_item_id=52 AND i.item_origin='3d_printed'
    AND NOT EXISTS (
      SELECT 1 FROM printing_3d_jobs j
      WHERE j.sitename='3d' AND j.status IN ('queued','assigned','printing')
        AND (j.source_item_id=b.component_item_id
             OR j.model_id IN (SELECT id FROM printing_3d_models
                               WHERE item_id=b.component_item_id AND sitename='3d')))
  ORDER BY i.name
},[]);
for my $m (@$missing) {
    printf "  %-40s bom=%s  %s\n", substr($m->{name},0,40), int($m->{bom_qty}//0), $m->{sku}//'';
}

print "\n" . "=" x 78 . "\n";
print $APPLY ? "(changes WRITTEN)\n" : "(dry run: --apply to write)\n";
print "=" x 78 . "\n";
