<div id="2026-09-24-traveler-reserve-stock" class="cl-entry">
<h3>2026-09-24 — Traveler tablet Reserve on-hand</h3>
<p class="doc-body"><strong>What.</strong> Tablet traveler has a <code>Reserve on-hand</code> button that POSTs <code>/Accounting/manufacturing/api/reserve</code>, which calls <code>Purchasing::reserve_bom</code>. GET traveler does not mutate stock. Idempotent via existing <code>RSV-{parent}-x{qty}</code> (already-reserved is success). LAN bypass on manufacturing API paths.</p>
<p class="doc-body"><strong>Why.</strong> Todo #2399: explode→reserve existed as an inventory API but the traveler never invoked it.</p>
<p class="doc-body"><strong>Files.</strong> <code>Controller/Accounting/Manufacturing.pm</code>, <code>Controller/Accounting.pm</code>, <code>root/Accounting/Manufacturing/traveler_view.tt</code></p>
</div>
