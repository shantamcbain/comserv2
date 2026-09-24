<div id="2026-09-24-apptime-inventory-acct" class="cl-entry">
<h3>2026-09-24 — Inventory/Accounting timestamps via AppTime UTC</h3>
<p class="doc-body"><strong>What.</strong> Replaced remaining <code>localtime</code>/<code>strftime</code>/<code>DateTime-&gt;now</code> store stamps in Accounting, Cart, Traveler, Manufacturing cancel, and Inventory invoice/log helpers with <code>Comserv::Util::AppTime</code> (<code>now_utc</code> / <code>today_utc_ymd</code>).</p>
<p class="doc-body"><strong>Why.</strong> Todo #2382: one time authority; naive localtime is how fake durations happen.</p>
<p class="doc-body"><strong>Files.</strong> <code>Controller/Accounting.pm</code>, <code>Controller/Cart.pm</code>, <code>Util/Manufacturing/Traveler.pm</code>, <code>Controller/Accounting/Manufacturing.pm</code>, <code>Controller/Inventory.pm</code>, <code>Controller/Shop.pm</code>, <code>Controller/Marketplace.pm</code>, <code>Controller/CustomerOrder.pm</code></p>
</div>
