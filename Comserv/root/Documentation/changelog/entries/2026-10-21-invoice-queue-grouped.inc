<div id="2026-10-21-invoice-queue-grouped" class="cl-entry">
<h3>2026-10-21 — Invoice queue grouped by invoice</h3>
<p class="doc-body"><strong>What.</strong> <code>/mail/invoice/sort</code> lists invoices, with each invoice's items under it. The header can change that invoice's SiteName and supplier. Clicking an item can change that item's SiteName and barcode. The move is the SiteName column only.</p>
<p class="doc-body"><strong>Why.</strong> A flat item list could not be sorted to the right site when one mailbox receives invoices for more than one SiteName.</p>
<p class="doc-body"><strong>Files.</strong> <code>lib/Comserv/Controller/Mail.pm</code>, <code>lib/Comserv/Util/Inventory/MailInvoiceStock.pm</code>, <code>root/mail/mail.invoice_sort.tt</code></p>
</div>
