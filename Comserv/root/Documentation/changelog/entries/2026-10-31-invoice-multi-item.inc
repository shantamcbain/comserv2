<div id="2026-10-31-invoice-multi-item" class="cl-entry">
<h3>2026-10-31 — Chat invoice keeps every item</h3>
<p class="doc-body"><strong>What.</strong> A chat invoice with several Item labels now saves a line for each item. A quantity no longer swallows a created date that follows it.</p>
<p class="doc-body"><strong>Why.</strong> Draft 125 kept only Beef stew, and stored its quantity as 1.172 because the date “may 17 2024” was treated as more digits.</p>
<p class="doc-body"><strong>Files.</strong> <code>Model/AI2/InvoiceCreate.pm</code>, <code>t/model_ai2_invoice_create.t</code></p>
</div>
