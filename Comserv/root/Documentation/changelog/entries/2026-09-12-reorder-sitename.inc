<h3>2026-09-12 — Reorder list query disambiguated ambiguous <code>sitename</code> column</h3>
<ul>
    <li><strong>Fix:</strong> <code>Purchasing::stock_reorder_list</code> crashed with <code>Column 'sitename' in WHERE is ambiguous</code> because the search condition referenced bare <code>sitename</code> while the query JOINs <code>inventory_suppliers</code> (also has <code>sitename</code>). Prefixed with <code>me.sitename</code> to target the InventoryItem table.</li>
</ul>