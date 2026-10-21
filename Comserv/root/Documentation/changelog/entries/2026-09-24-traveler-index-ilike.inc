<div id="2026-09-24-traveler-index-ilike" class="cl-entry">
<h3>2026-09-24 — Manufacturing index: MariaDB ILIKE crash hid all travelers</h3>
<p class="doc-body"><strong>What.</strong> <code>/Accounting/manufacturing</code> called <code>get_customers_with_open_orders</code>, which used DBIC <code>-ilike</code> on <code>customer_name</code>. MariaDB rejected <code>ILIKE</code>; the whole method died inside eval; the page rendered empty (no customers, no In-House synthetic, no traveler to open).</p>
<p class="doc-body"><strong>Why.</strong> A traveler is keyed to an <code>inventory_customer_orders</code> row (or the In-House synthetic when none exists). The index never reached that logic. Cart checkout still writes invoices only — that remains a separate order-recording gap.</p>
<p class="doc-body"><strong>Files.</strong> <code>Comserv/lib/Comserv/Util/Manufacturing/Traveler.pm</code> (two <code>-ilike</code> → exact <code>In-House</code>).</p>
</div>
