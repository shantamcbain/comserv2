<div id="2026-09-24-po-receive-apptime-mail-draft" class="cl-entry">
<h3>2026-09-24 — PO receive, AppTime, mail draft AP</h3>
<p class="doc-body"><strong>What.</strong> Purchase orders can be received into stock (<code>POST /Inventory/api/po/receive</code> and the PO view form). Mark-sent bumps <code>quantity_on_order</code>. Inventory timestamps go through <code>AppTime</code>. Classified mail can create <em>draft</em> supplier invoices (no GL) when the From address matches a supplier.</p>
<p class="doc-body"><strong>Why.</strong> Todos #2310 receive-from-PO, #2382 AppTime, #2311 draft invoices. Recurring AP (#2190) still needs schema columns.</p>
<p class="doc-body"><strong>Files.</strong> <code>Util/Inventory/Purchasing.pm</code>, <code>Controller/Inventory/PurchaseOrder.pm</code>, <code>Controller/Inventory.pm</code>, <code>Controller/Api.pm</code>, <code>Util/MailInvoiceClassifier.pm</code>, <code>root/Inventory/po/view.tt</code></p>
</div>
