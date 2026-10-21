<div id="2026-09-14-model-detail-breadcrumb-download-fix" class="cl-entry">
<h3>2026-09-14 — Model detail page: breadcrumb nav, download fix, Inventory/BOM link</h3>
<p class="doc-body"><strong>What.</strong> Reworked the 3D model detail page (<code>/3d/model/&lt;id&gt;</code>): added breadcrumb navigation (3D Printing &rsaquo; Browse Models &rsaquo; {name}); download button now shows for any logged-in user (was admin-only) and displays "⚠ No STL linked" when <code>nfs_path</code> is empty instead of silently hiding; added a "📦 View in Inventory / BOM" button that links to the inventory item BOM page for all logged-in users.</p>
<p class="doc-body"><strong>Why.</strong> Models with no uploaded file were a dead-end — no download button, no explanation. Inventory/BOM access was admin-only despite the model being the same item a non-admin user created. No breadcrumbs forced users to rely on browser back.</p>
<p class="doc-body"><strong>Files.</strong> <code>Comserv/root/3d/model_detail.tt</code> (breadcrumb, conditional download/STL-missing display, Inventory/BOM link).</p>
</div>
