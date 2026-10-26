<div id="2026-10-23-invoice-queue-accept" class="cl-entry">
<h3>2026-10-23 — Invoice queue accept creates the item and receives stock</h3>
<p class="doc-body"><strong>What.</strong> On <code>/mail/invoice/sort</code>, Correct line saves the name, quantity, and cost without moving stock. Accept into stock creates a missing purchased item for 3d, CSC, or Shanta, sets cost from that line, and adds the quantity to on-hand. A second accept does not add the same quantity again. Minimum on hand is 1, or 2 for cumin and cinnamon. No general-ledger post.</p>
<p class="doc-body"><strong>Why.</strong> The queue could sort an invoice to a site, but a line with no item never became stock. That is the current input path for the three core sites.</p>
<p class="doc-body"><strong>Files.</strong> <code>lib/Comserv/Util/Inventory/MailInvoiceStock.pm</code>, <code>lib/Comserv/Controller/Mail.pm</code>, <code>root/mail/mail.invoice_sort.tt</code></p>
</div>
