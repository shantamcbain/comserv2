<div id="2026-10-31-invoice-number-per-supplier" class="cl-entry">
<h3>2026-10-31 — Invoice number is unique per supplier</h3>
<p class="doc-body"><strong>What.</strong> Chat no longer treats an invoice number as the same bill across suppliers. A one-letter supplier name is no longer saved with the word “for” attached.</p>
<p class="doc-body"><strong>Why.</strong> Invoice number 1 on Caroline’s draft 124 blocked a new $0 invoice for supplier T. The name parser also saved that supplier as “T for”.</p>
<p class="doc-body"><strong>Files.</strong> <code>Model/AI2/InvoiceCreate.pm</code>, <code>t/model_ai2_invoice_create.t</code></p>
</div>
