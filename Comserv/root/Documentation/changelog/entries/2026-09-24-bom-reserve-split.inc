<div id="2026-09-24-bom-reserve-split" class="cl-entry">
<h3>2026-09-24 — BOM reserve + buy/print shortfall</h3>
<p class="doc-body"><strong>What.</strong> <code>Purchasing::reserve_bom</code> explodes a parent BOM, reserves available on-hand into <code>quantity_reserved</code>, and returns remaining shortfall split buy vs print. <code>POST /Inventory/api/stock/reserve</code> (and <code>/api/inventory/stock/reserve</code>). <code>dry_run=1</code> computes without writing. Idempotent via transaction ref <code>RSV-{parent}-x{qty}</code>. No GL post.</p>
<p class="doc-body"><strong>Why.</strong> Todo #2399 missing explode→reserve→split; traveler already displayed shortfall but never reserved stock.</p>
<p class="doc-body"><strong>Files.</strong> <code>Util/Inventory/Purchasing.pm</code>, <code>Controller/Inventory/PurchaseOrder.pm</code>, <code>Controller/Api.pm</code></p>
</div>
