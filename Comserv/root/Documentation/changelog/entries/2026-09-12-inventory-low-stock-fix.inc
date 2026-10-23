<div id="2026-09-12-inventory-low-stock-fix" class="cl-entry">
<h3>2026-09-12 — Fix false-positive low stock count</h3>
<p class="doc-body"><strong>What.</strong> Fixed a bug where items with reorder_point=0 (the default) were counted as "low stock" on the Inventory and Accounting dashboards. The <code>defined $item->reorder_point</code> check passes for the numeric value 0, causing every item with zero or negative stock to appear low — inflating the low-stock count.</p>
<p class="doc-body"><strong>Why.</strong> The InventoryItem Result class sets <code>reorder_point</code> default to 0 (not NULL), so <code>defined</code> always returns true. The dashboard index lacked a <code>&gt; 0</code> guard, and the Accounting dashboard used <code>&lt;=</code> instead of <code>&lt;</code> for the reorder comparison. This caused "34 low stock" when stock was actually fine.</p>
<p class="doc-body"><strong>Files.</strong> <code>lib/Comserv/Controller/Inventory.pm</code> (line 100 — added reorder_point &gt; 0 guard), <code>lib/Comserv/Controller/Accounting.pm</code> (line 150 — changed &lt;= to &lt;).</p>
</div>
