<div id="2026-08-26-inventory-view-api" class="cl-entry">
<h3>2026-08-26 — Inventory view API (BOM + stock aliases)</h3>
<p class="doc-body"><strong>What.</strong> Ported the 3d worktree Inventory LAN/API helpers into InventoryAccounting so agents can list items, stock, and BOM without mysql. Added GET <code>/Inventory/api/bom</code> (and <code>/api/inventory/bom</code>) that delegates to Inventory <code>_list_bom_lines</code>. Same surface copied onto the 3d checkout to avoid merge collisions.</p>
<p class="doc-body"><strong>Why.</strong> A dryer order needs BOM vs on-hand. POST bom/add existed on 3d only (uncommitted); GET bom did not exist anywhere.</p>
<p class="doc-body"><strong>Files.</strong> <code>Controller/Inventory.pm</code>, <code>Controller/Api.pm</code> (this branch and 3d). #2310 started: Result <code>InventoryPurchaseOrder</code> + Line, <code>Util::Inventory::Purchasing</code>, <code>Controller::Inventory::PurchaseOrder</code> (GET need, POST po/create). Tables apply via schema-compare.</p>
</div>
