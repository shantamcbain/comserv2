<div id="2026-09-10-inventory-items-cards" class="cl-entry">
<h3>2026-09-10 — Inventory Items: Category-based Cards with Color Coding</h3>
<p class="doc-body"><strong>What.</strong> Redesigned the Inventory Items list page (/Inventory/items) to display items grouped by category in separate, normally-closed cards. Each category gets a distinct color via CSS variables.</p>
<p class="doc-body"><strong>Why.</strong> The previous single-table view was hard to navigate with many items. Grouping by category with visual color coding makes it much easier to scan and find items.</p>
<p class="doc-body"><strong>Files.</strong> <code>lib/Comserv/Controller/Inventory.pm</code> (items action), <code>root/Inventory/items/list.tt</code></p>
<p class="doc-body"><strong>Details.</strong>
<ul>
<li>Controller now groups items by category into <code>items_by_category</code> hashref</li>
<li>Added <code>sorted_categories</code> array for consistent ordering</li>
<li>Added <code>category_colors</code> hash mapping category names to CSS variables (e.g., <code>--cat-3d-filament</code>, <code>--cat-3d-supply</code>, <code>--cat-3d-printed</code>)</li>
<li>Template renders each category as a separate card with colored header bar</li>
<li>Uses CSS variables for theming compatibility (var(--cat-*), var(--card-bg), var(--border-color), etc.)</li>
<li>Low-stock items highlighted in red within each category</li>
</ul>
</p>
</div>