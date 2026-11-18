package Comserv::Util::Inventory::StockTxn;

# One stock movement: stock level + inventory_transactions row (+ the optional
# GL entry the API path has always posted for items with accounts).
#
# Moved verbatim out of Controller::Inventory::api_transaction (2026-11-16) so the
# phone/web scan flow (Comserv::Util::Inventory::PhotoRead::scan_apply) writes
# stock through the SAME code instead of a second copy. Call it inside the
# caller's txn_do.
#
# post($schema, %p)
#   item_id, type, qty (>0), location_id, sitename, unit_cost, reference_number,
#   notes, user_id, username, now, today
#   direction      +1 / -1   override the type rule (receive|adjust_up|produce|
#                            harvest|return add; everything else subtracts)
#   store_quantity           value stored in transactions.quantity (default qty;
#                            count_adjust stores the signed difference)
#   no_gl          1         skip the GL entry (moves and counts are not value
#                            changes; the scan flow never posts GL)
# -> ($txn_id, $gl_entry_id)

use strict;
use warnings;

sub post {
    my ($class, $schema, %p) = @_;
    my $item_id  = $p{item_id};
    my $type     = $p{type};
    my $qty      = $p{qty};
    my $loc_id   = $p{location_id};
    my $sitename = $p{sitename};
    my $now      = $p{now};
    my $today    = $p{today} || substr($now // '', 0, 10);
    my $gl_entry_id;

    my $stock = $schema->resultset('Accounting::InventoryStockLevel')->find_or_create(
        { item_id => $item_id, location_id => ($loc_id || \'NULL') },
        { default => { quantity_on_hand => 0, quantity_reserved => 0, quantity_on_order => 0 } }
    ) if $loc_id;

    my $adds = defined $p{direction}
        ? ($p{direction} > 0 ? 1 : 0)
        : ($type =~ /^(receive|adjust_up|produce|harvest|return)$/ ? 1 : 0);

    if ($loc_id) {
        my $new_qty = $stock->quantity_on_hand;
        if ($adds) {
            $new_qty += $qty;
        } else {
            $new_qty -= $qty;
        }
        $stock->update({ quantity_on_hand => $new_qty, updated_at => $now });
    }

    my $item_rec = $schema->resultset('Accounting::InventoryItem')->find($item_id);
    if (!$p{no_gl} && $item_rec && ($item_rec->inventory_accno_id || $item_rec->expense_accno_id)) {
        my $unit_cost = $p{unit_cost} || $item_rec->unit_cost || 0;
        my $value     = $qty * $unit_cost;
        my $ref       = 'API-TXN-' . $item_id . '-' . time();
        my $gl = $schema->resultset('Accounting::GlEntry')->create({
            reference   => $ref,
            description => ucfirst($type) . ' (API): ' . ($item_rec->name || "Item $item_id") . " x$qty",
            entry_type  => 'inventory',
            post_date   => $today,
            approved    => 1,
            currency    => 'CAD',
            sitename    => $sitename,
            entered_by  => $p{user_id} || undef,
        });
        $gl_entry_id = $gl->id;

        if ($value != 0) {
            my ($dr_acct, $cr_acct);
            if ($type =~ /^(receive|adjust_up|produce|harvest)$/) {
                $dr_acct = $item_rec->inventory_accno_id;
                $cr_acct = $item_rec->expense_accno_id || $item_rec->inventory_accno_id;
            } else {
                $dr_acct = $item_rec->expense_accno_id || $item_rec->inventory_accno_id;
                $cr_acct = $item_rec->inventory_accno_id;
            }
            if ($dr_acct) {
                $schema->resultset('Accounting::GlEntryLine')->create({
                    gl_entry_id => $gl_entry_id,
                    account_id  => $dr_acct,
                    amount      => $value,
                    memo        => ucfirst($type) . " $qty units (API)",
                    sort_order  => 1,
                });
            }
            if ($cr_acct && $cr_acct != ($dr_acct || 0)) {
                $schema->resultset('Accounting::GlEntryLine')->create({
                    gl_entry_id => $gl_entry_id,
                    account_id  => $cr_acct,
                    amount      => -$value,
                    memo        => ucfirst($type) . " $qty units (API)",
                    sort_order  => 2,
                });
            }
        }
    }

    # inventory_transactions has no gl_entry_id column in the Result class; the
    # old inline code passed one anyway, which DBIC rejects. Only send it when
    # the column exists.
    my $src = $schema->source('Accounting::InventoryTransaction');
    my $txn = $schema->resultset('Accounting::InventoryTransaction')->create({
        item_id          => $item_id,
        location_id      => $loc_id || undef,
        transaction_type => $type,
        quantity         => (defined $p{store_quantity} ? $p{store_quantity} : $qty),
        unit_cost        => $p{unit_cost} || undef,
        reference_number => $p{reference_number} || undef,
        ($src->has_column('gl_entry_id') ? (gl_entry_id => $gl_entry_id || undef) : ()),
        sitename         => $sitename,
        notes            => $p{notes} || undef,
        performed_by     => $p{username} || 'api',
        transaction_date => $now,
        created_at       => $now,
    });
    return ($txn->id, $gl_entry_id);
}

1;
