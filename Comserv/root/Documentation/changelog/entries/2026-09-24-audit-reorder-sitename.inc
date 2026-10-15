<div id="2026-09-24-audit-reorder-sitename" class="cl-entry">
<h3>2026-09-24 — Qualify InventoryItem.status in reorder prefetch</h3>
<p class="doc-body"><strong>What.</strong> <code>stock_reorder_list</code> prefetches <code>item_suppliers.supplier</code> (also has <code>sitename</code>/<code>status</code>). Unqualified <code>status =&gt; 'active'</code> made MariaDB reject the query as ambiguous (#2479).</p>
<p class="doc-body"><strong>Why.</strong> JOIN + bare column name.</p>
<p class="doc-body"><strong>Files.</strong> <code>Comserv/lib/Comserv/Util/Inventory/Purchasing.pm</code></p>
</div>
