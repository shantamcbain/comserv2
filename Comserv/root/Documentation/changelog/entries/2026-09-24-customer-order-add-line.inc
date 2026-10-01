<div id="2026-09-24-customer-order-add-line" class="cl-entry">
<h3>2026-09-24 — Place Order form: Add Line / item list was dead JS</h3>
<p class="doc-body"><strong>What.</strong> <code>/CustomerOrder/new</code> could not add a line. Inline script dumped inventory into a JS array with chained TT <code>.replace()</code> (breaks TT2) and declared <code>addLine</code> twice. Items now come from a JSON <code>data-items</code> attribute; line add/remove lives in <code>static/js/CustomerOrder/order-form.js</code> via <code>js_load.tt</code>. Filter box finds SKUs (e.g. HDRY). Empty submits are rejected.</p>
<p class="doc-body"><strong>Why.</strong> Manufacturing traveler needs a real <code>inventory_customer_orders</code> row with an item line. A dead Add Line button produced empty orders.</p>
<p class="doc-body"><strong>Files.</strong> <code>Controller/CustomerOrder.pm</code>, <code>root/CustomerOrder/new.tt</code>, <code>root/static/js/CustomerOrder/order-form.js</code>, <code>root/js_load.tt</code>.</p>
</div>
