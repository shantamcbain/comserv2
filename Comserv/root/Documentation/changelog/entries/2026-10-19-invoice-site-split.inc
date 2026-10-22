<div id="2026-10-19-invoice-site-split" class="cl-entry">
<h3>2026-10-19 — Separate bank-address invoices by supplier</h3>
<p class="doc-body"><strong>What.</strong> Mail to shanta@forager.com is no longer treated as one site. The supplier row chooses CSC or Shanta. Unknown invoice lines have a screen to link, create, or skip the item. Invoice lists link to the supplier.</p>
<p class="doc-body"><strong>Why.</strong> The bank uses that address for every purchase and bank notice. The address is not a site.</p>
<p class="doc-body"><strong>Files.</strong> <code>Util/Inventory/MailInvoiceStock.pm</code>, <code>Controller/Inventory/UnknownLine.pm</code>, <code>root/Inventory/invoice/unknown_lines.tt</code>, <code>root/Inventory/invoice/list.tt</code>, <code>root/Inventory/invoice/view.tt</code></p>
</div>
