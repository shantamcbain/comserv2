<div id="2026-10-01-inventory-categories" class="cl-entry">
<h3>2026-10-01 — Universal hierarchical inventory categories</h3>
<p class="doc-body"><strong>What.</strong> Built a universal hierarchical category system for inventory items, usable across all product domains (3D printing, woodworking, beekeeping, etc.). Categories form a tree with parent/child relationships; items link to categories via many-to-many junction table, so an item can appear in multiple categories and categories can have sub-categories.</p>
<p class="doc-body"><strong>Why.</strong> The existing `inventory_items.category` column was a flat text field limited to one value. The new system supports the full product catalog: browse filtering, admin model management, and the `/inventory/categories/manage` admin page for bulk CRUD. Works identically on public `/3d/browse` and admin `/3d/models` pages.</p>
<p class="doc-body"><strong>Files.</strong>
<code>Comserv/lib/Comserv/Util/CategoryManager.pm</code> (new — tree, CRUD, item↔category linkage, flatten_names helper),
<code>Comserv/lib/Comserv/Controller/Inventory/Categories.pm</code> (new — JSON API + HTML manage page),
<code>Comserv/lib/Comserv/Model/Schema/Ency/Result/Accounting/InventoryCategory.pm</code> (new — inventory_categories table),
<code>Comserv/lib/Comserv/Model/Schema/Ency/Result/Accounting/InventoryItemCategory.pm</code> (new — junction table),
<code>Comserv/lib/Comserv/Model/Schema/Ency/Result/Accounting/InventoryItem.pm</code> (added many_to_many relationship),
<code>Comserv/lib/Comserv/Controller/3d.pm</code> (browse: category filter + pagination; models: assign_cat + pagination + _flatten_cat_names),
<code>Comserv/root/3d/browse.tt</code> (category dropdown filter + 5-page pagination + thumbnails),
<code>Comserv/root/3d/models.tt</code> (quick-add category form + inline assignment + pagination + thumbnails),
<code>Comserv/root/Inventory/categories.tt</code> (new — admin: add/rename/delete categories, assign items)
</p>
</div>