<div id="2026-10-20-invoice-queue" class="cl-entry">
<h3>2026-10-20 — Invoice queue lists site and supplier per line</h3>
<p class="doc-body"><strong>What.</strong> <code>/mail/invoice/sort</code> lists invoice lines with the SiteName and supplier the system assigned. Mail lines use the supplier row, not the mailbox. Filed lines for 3d, CSC, and Shanta are included so the queue is not empty when classification has no invoices.</p>
<p class="doc-body"><strong>Why.</strong> One mailbox can receive invoices for more than one site. The line has to be sorted to the site that owns the supplier.</p>
<p class="doc-body"><strong>Files.</strong> <code>Util/Inventory/MailInvoiceStock.pm</code>, <code>Controller/Mail.pm</code>, <code>root/mail/mail.invoice_sort.tt</code>, <code>root/Accounting/_acct_inv_nav.tt</code>, <code>root/Inventory/email/setup.tt</code></p>
</div>
