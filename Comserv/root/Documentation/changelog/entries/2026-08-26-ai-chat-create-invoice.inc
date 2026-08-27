<div id="2026-08-26-ai-chat-create-invoice" class="cl-entry">
<h3>2026-08-26 — Chat-with-AI can enter draft invoices into accounting</h3>
<p class="doc-body"><strong>What.</strong> Pasting or describing an invoice in Chat-with-AI now creates a <em>draft</em> on the existing Inventory tables (supplier AP at <code>/Inventory/invoice</code>, sales AR at <code>/Inventory/sales</code>) for the current SiteName. Chat never posts the GL — accounting still reviews and Posts. Missing supplier/amount asks instead of inventing rows.</p>
<p class="doc-body"><strong>Why.</strong> The model previously could not write invoices. Natural-language intercept (same as todo-create) so free models cannot invent a fake form. No new tables — aisystem reuses Inventory/Accounting.</p>
<p class="doc-body"><strong>Files.</strong> <code>Comserv/lib/Comserv/Model/AI2/InvoiceCreate.pm</code> <code>Comserv/lib/Comserv/Model/AI2/Actions.pm</code> <code>Comserv/lib/Comserv/Model/AI2/Chat.pm</code> <code>Comserv/lib/Comserv/Controller/AI2.pm</code> <code>Comserv/t/model_ai2_invoice_create.t</code></p>
</div>
