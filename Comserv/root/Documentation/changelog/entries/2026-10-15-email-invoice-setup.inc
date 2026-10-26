<div id="2026-10-15-email-invoice-setup" class="cl-entry">
<h3>2026-10-15 — Invoice email address setup page</h3>
<p class="doc-body"><strong>What.</strong> Restored Inventory helpers broken by a package-level <code>$c</code> edit (<code>_now</code>, <code>_create_item</code>, <code>_schema</code> via <code>$c->model('DBEncy')</code>). Added <code>/Inventory/email-config</code> so an admin can set the mailbox addresses a SiteName watches, saved to <code>root/config/email_invoice_monitor.json</code> and read by <code>MailInvoiceClassifier</code>. Declared <code>Mail::IMAPClient</code> in the cpanfile.</p>
<p class="doc-body"><strong>Why.</strong> <code>/Inventory/invoice/new</code> died on a missing <code>_schema</code>/<code>get_model</code>, and there was no page or nav link to set the invoice email addresses.</p>
<p class="doc-body"><strong>Files.</strong> <code>lib/Comserv/Controller/Inventory.pm</code>, <code>lib/Comserv/Util/MailInvoiceClassifier.pm</code>, <code>root/Inventory/email/setup.tt</code>, <code>root/config/email_invoice_monitor.json</code>, <code>root/Accounting/_acct_inv_nav.tt</code>, <code>cpanfile</code></p>
</div>
