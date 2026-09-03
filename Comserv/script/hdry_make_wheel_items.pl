#!/usr/bin/env perl
#
# Build a correct wheel-kit BOM.
#
# Problem found 2026-09-02: model 48 ("HDRY printed wheels (set of 4)") is
# linked to item_id 99 — and item 99 IS the wheel kit (HW-WHEEL-KIT). Adding a
# BOM line 99 -> 99 would make the kit a component of itself (circular BOM).
#
# The kit BOM also listed hardware ONLY (washer/bolt/spacer), which is why the
# printed support structure never appeared in the queue.
#
# Fix:
#   1. Create 3 inventory items: wheel half, wheel foot, wheel tire.
#   2. Repoint model 48 from item 99 -> the new wheel-half item.
#   3. Add printed BOM lines to kit 99: half x8, foot x4, tire x4
#      (user: 1 wheel = 2 halves + 1 tire; 4 wheels; foot = 1 per wheel).
#
# Idempotent. Dry-run by default.
#
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Comserv::Model::RemoteDB;
use Comserv::Controller::Inventory;

my $APPLY = grep { $_ eq '--apply' } @ARGV;
my $CONN  = 'db_production_mysql';
my $SITE  = '3d';
my $KIT   = 99;

my $rdb = Comserv::Model::RemoteDB->new;

# sku => [ name, model_id, kit_qty ]
my %NEW = (
  'INT-HDRY-WHEEL-HALF' => [ 'HDRY Wheel half (printed)',         48, 8 ],
  'INT-HDRY-WHEEL-FOOT' => [ 'HDRY Wheel support foot (printed)', 63, 4 ],
  'INT-HDRY-WHEEL-TIRE' => [ 'HDRY Wheel tire / Gomma (printed)', 64, 4 ],
);

print "=" x 78 . "\n";
print "Build correct wheel-kit BOM" . ($APPLY ? "  [APPLY]" : "  [DRY RUN]") . "\n";
print "=" x 78 . "\n\n";

# helper: find item id by sku
sub item_by_sku {
    my ($sku) = @_;
    my $r = $rdb->execute_query(undef,$CONN,
        'SELECT id,name FROM inventory_items WHERE sku=? AND sitename=?',[$sku,$SITE]);
    return ($r && @$r) ? $r->[0]{id} : undef;
}

# ---------------------------------------------------- 1. create the 3 items
print "--- 1. create inventory items ---\n";
for my $sku (sort keys %NEW) {
    my ($name,$mid,$qty) = @{$NEW{$sku}};
    my $iid = item_by_sku($sku);
    if ($iid) { printf "  %-24s exists (item %s)\n",$sku,$iid }
    else {
        printf "  %-24s CREATE  %s\n",$sku,$name;
        if ($APPLY) {
            # _create_item() needs a live Catalyst context ($c->model), which a
            # CLI script does not have. Mirror the exact columns it writes.
            # NOTE: no is_active column on this table (schema drift vs the
            # Result class) — active-ness is the `status` column, default 'active'.
            # hide_stock_count / show_in_shop are NOT NULL with no default and
            # must be supplied explicitly.
            my $res = $rdb->execute_query(undef,$CONN, q{
                INSERT INTO inventory_items
                  (sitename, sku, name, item_origin, status, created_by, created_at,
                   hide_stock_count, show_in_shop, is_assemblable)
                VALUES (?,?,?,'3d_printed','active','system',NOW(),0,0,0)
            }, [$SITE,$sku,$name]);
            my $ok = (ref $res eq 'HASH' && $res->{success}) ? 1 : 0;
            printf "      %s\n", $ok ? "created (id ".(($rdb->execute_query(undef,$CONN,
                'SELECT LAST_INSERT_ID() AS id')->[0]{id}) // '?').")"
                : "FAILED: ".(($res->{error})//'?');
        }
    }
}

# ------------------------------------------- 2. repoint models at new items
print "\n--- 2. link models to their items ---\n";
for my $sku (sort keys %NEW) {
    my ($name,$mid,$qty) = @{$NEW{$sku}};
    my $iid = item_by_sku($sku);
    unless ($iid) { printf "  model %-3d %-34s (item not available yet)\n",$mid,substr($name,0,34); next }
    my $mo = $rdb->execute_query(undef,$CONN,
      'SELECT id,name,item_id FROM printing_3d_models WHERE id=? AND sitename=?',[$mid,$SITE]);
    next unless $mo && @$mo;
    my $cur = $mo->[0]{item_id};
    if ($cur && $cur == $iid) { printf "  model %-3d already -> item %s\n",$mid,$iid; next }
    printf "  model %-3d %-34s item %s -> %s%s\n",$mid,substr($mo->[0]{name},0,34),
        $cur//'-', $iid, ($cur && $cur==$KIT) ? "   (was the KIT - circular!)" : "";
    if ($APPLY) {
        $rdb->execute_query(undef,$CONN,
          'UPDATE printing_3d_models SET item_id=? WHERE id=? AND sitename=?',[$iid,$mid,$SITE]);
        print "      RELINKED\n";
    }
}

# ----------------------------------------------------- 3. add kit BOM lines
print "\n--- 3. add printed lines to kit BOM (item $KIT) ---\n";
for my $sku (sort keys %NEW) {
    my ($name,$mid,$qty) = @{$NEW{$sku}};
    my $iid = item_by_sku($sku);
    unless ($iid) { printf "  %-24s no item\n",$sku; next }
    if ($iid == $KIT) { printf "  %-24s SKIP (would be circular)\n",$sku; next }
    my $ex = $rdb->execute_query(undef,$CONN,
      'SELECT id,quantity FROM inventory_item_bom WHERE parent_item_id=? AND component_item_id=?',
      [$KIT,$iid]);
    if ($ex && @$ex) { printf "  %-24s BOM exists (q%s)\n",$sku,int($ex->[0]{quantity}); next }
    printf "  %-24s ADD q%s\n",$sku,$qty;
    if ($APPLY) {
        my $res = $rdb->execute_query(undef,$CONN,
          q{INSERT INTO inventory_item_bom (parent_item_id,component_item_id,quantity,unit)
            VALUES (?,?,?,'each')},[$KIT,$iid,$qty]);
        my $ok=(ref $res eq 'HASH' && $res->{success})?1:0;
        printf "      %s\n",$ok?"ADDED":"FAILED: ".(($res->{error})//'?');
    }
}

print "\n" . "=" x 78 . "\n";
print $APPLY ? "(WRITTEN)\n" : "(dry run — --apply to write)\n";
print "=" x 78 . "\n";
