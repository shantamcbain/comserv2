<div id="2026-10-17-mail-invoice-stock" class="cl-entry">
<h3>2026-10-17 — Supplier invoice mail updates stock per site</h3>
<p class="doc-body"><strong>What.</strong> Applying classified mail now routes by the mailbox that received the invoice (To), matches the supplier From address to that site's supplier record, writes invoice lines, and receives on-hand stock only when every line matches an existing item. Unmatched invoices stay drafts. Posting a draft skips a line that was already received.</p>
<p class="doc-body"><strong>Why.</strong> The watch list was compared to the supplier From address, so real invoices were skipped, and drafts had no lines so stock never moved. Each SiteName needs its own supplier invoices to bring on-hand current.</p>
<p class="doc-body"><strong>Files.</strong> <code>lib/Comserv/Util/Inventory/MailInvoiceStock.pm</code>, <code>lib/Comserv/Util/MailInvoiceClassifier.pm</code>, <code>lib/Comserv/Controller/Inventory/PurchaseOrder.pm</code>, <code>lib/Comserv/Controller/Inventory.pm</code>, <code>root/Inventory/email/setup.tt</code></p>
</div>
