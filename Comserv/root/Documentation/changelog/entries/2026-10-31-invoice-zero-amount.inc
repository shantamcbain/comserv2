<div id="2026-10-31-invoice-zero-amount" class="cl-entry">
<h3>2026-10-31 — Chat invoice accepts a zero total</h3>
<p class="doc-body"><strong>What.</strong> A supplier invoice whose total is 0.00 is saved as a draft. Free, donated, and food-bank goods are no longer refused. A missing amount is still asked for.</p>
<p class="doc-body"><strong>Why.</strong> The create check required the amount to be greater than zero, so a food-bank invoice of $0.00 was rejected.</p>
<p class="doc-body"><strong>Files.</strong> <code>Model/AI2/InvoiceCreate.pm</code>, <code>t/model_ai2_invoice_create.t</code></p>
</div>
