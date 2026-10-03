<div id="2026-09-24-bom-unreserve" class="cl-entry">
<h3>2026-09-24 — BOM unreserve + traveler cancel</h3>
<p class="doc-body"><strong>What.</strong> <code>Purchasing::unreserve_bom</code> reverses <code>RSV-{parent}-x{qty}</code> into <code>quantity_reserved</code>. <code>POST /Inventory/api/stock/unreserve</code>. Traveler <strong>Release reserve</strong> button. Manufacturing cancel calls unreserve (no GL).</p>
<p class="doc-body"><strong>Why.</strong> Todo #2399 leftover: reserve had no reverse path.</p>
<p class="doc-body"><strong>Files.</strong> <code>Util/Inventory/Purchasing.pm</code>, <code>Controller/Inventory/PurchaseOrder.pm</code>, <code>Controller/Api.pm</code>, <code>Controller/Accounting/Manufacturing.pm</code>, <code>traveler_view.tt</code></p>
</div>
