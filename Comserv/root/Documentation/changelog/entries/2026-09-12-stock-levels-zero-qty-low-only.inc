<div id="2026-09-12-stock-levels-zero-qty-low-only" class="cl-entry">
<h3>2026-09-12 — Fix low-stock view dropping zero-stock items with a reorder point</h3>
<p class="doc-body"><strong>What.</strong> The "Stock Levels / Low stock only" view (Inventory/stock/levels) reported "No items are below their reorder point" even though several items had a reorder point set and zero on-hand quantity. Items that were never received into stock (no InventoryStockLevel row) were silently excluded from the low-stock list.</p>
<p class="doc-body"><strong>Why.</strong> In Inventory.pm stock_levels(), the no-stock-row branch did <code>next if $low_only;</code>, discarding any item without a stock row. An item with a reorder point and no stock is by definition below reorder (qty 0 &le; reorder), so it must appear.</p>
<p class="doc-body"><strong>Files.</strong> <code>Comserv/lib/Comserv/Controller/Inventory.pm</code> (stock_levels action, no-stock branch). Template Inventory/stock/levels.tt already handled <code>sl => undef</code> correctly, so no template change was needed.</p>
</div>
