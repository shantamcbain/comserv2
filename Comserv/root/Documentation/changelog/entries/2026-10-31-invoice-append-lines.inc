<div id="2026-10-31-invoice-append-lines" class="cl-entry">
<h3>2026-10-31 — Chat can add items to an existing draft</h3>
<p class="doc-body"><strong>What.</strong> “Add these items to the last T invoice” appends the listed items to that supplier’s latest draft. It does not create another invoice, and it does not change stock until Post.</p>
<p class="doc-body"><strong>Why.</strong> A missed item had to be typed on the invoice edit page. Chat only knew how to create a new draft, and a repeat invoice number was refused.</p>
<p class="doc-body"><strong>Files.</strong> <code>Model/AI2/InvoiceCreate.pm</code>, <code>static/js/ai-chat/feature-invoice.js</code>, <code>t/model_ai2_invoice_create.t</code></p>
</div>
