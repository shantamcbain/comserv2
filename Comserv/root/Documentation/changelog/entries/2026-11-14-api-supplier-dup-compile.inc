<div id="2026-11-14-api-supplier-dup-compile" class="cl-entry">
<h3>2026-11-14 — Api.pm compile failure: duplicate supplier actions</h3>
<p class="doc-body"><strong>What.</strong> <code>codeguard</code> on <code>:4014</code> would not start. <code>perl -c</code> on <code>Api.pm</code> died at the stray <code>$c->detach()</code> / extra <code>}</code> after a second copy of <code>api_inventory_suppliers</code> and <code>api_inventory_supplier_create</code> pasted after the barcode lookup.</p>
<p class="doc-body"><strong>Why.</strong> Those two actions already exist and delegate to <code>Inventory</code> with the inventory auth gate. The paste redefined them, skipped that gate, and left two statements outside any sub, so Catalyst never finished compiling.</p>
<p class="doc-body"><strong>Files.</strong> <code>Comserv/lib/Comserv/Controller/Api.pm</code></p>
</div>
