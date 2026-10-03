<div id="2026-09-12-inventory-missing-stock" class="cl-entry">
<h3>2026-09-12 — Show missing-stock (never received) items as low/missing</h3>
<p class="doc-body"><strong>What.</strong> Items that exist but have never been received (no inventory_stock_levels row, so total on hand = 0) were invisible in the "Low stock only" filter and the Purchase/PO flow because the default reorder_point is 0. They now appear flagged "⚠ Missing (not received)" in Stock Levels, Items list, Print Report, and the supplier purchase needs list.</p>
<p class="doc-body"><strong>Why.</strong> A genuine blind spot: an unstocked catalog item is short stock but the low-stock logic required reorder_point &gt; 0 or a stock_level row. The fix treats "never received" as missing stock in low-only views and purchasing.</p>
<p class="doc-body"><strong>Files.</strong> <code>Controller/Inventory.pm</code> (stock_levels + print_stock_report: add is_missing), <code>Util/Inventory/Purchasing.pm</code> (stock_reorder_list: drop reorder_point&gt;0 filter, include missing), <code>root/Inventory/stock/levels.tt</code>, <code>root/Inventory/items/list.tt</code>, <code>root/Inventory/print/stock_report.tt</code>.</p>
</div>
