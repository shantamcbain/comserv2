<div id="2026-09-12-mail-invoice-classifier" class="cl-entry">
<h3>2026-09-12 — Mail Invoice Classifier</h3>
<p class="doc-body"><strong>What.</strong> Added mail invoice classification system that scans incoming mail (Maildir/IMAP) and automatically sorts invoices into categories: Personal (Shanta), CSC Internet, Hosting, Domain Names, 3D Filament, Hardware, and Other.</p>
<p class="doc-body"><strong>Why.</strong> Accounting staff need invoices automatically categorized and sorted by site before creating accounting records. Previously all mail was manually reviewed. The system produces a JSON file that feeds the invoice/receipt creation UI.</p>
<p class="doc-body"><strong>Files.</strong> <code>Comserv/lib/Comserv/Util/MailInvoiceClassifier.pm</code> — new classifier module. <code>script/mail_invoice_classify.pl</code> — runner script. <code>Comserv/lib/Comserv/Controller/Mail.pm</code> — added classify_invoices, invoice_api, invoice_sort actions. <code>Comserv/root/CSC/mail/</code> — three new TT templates (invoice_view, classify_results, invoice_sort).</p>
</div>
