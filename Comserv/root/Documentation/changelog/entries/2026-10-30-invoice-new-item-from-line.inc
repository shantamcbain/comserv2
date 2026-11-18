<div id="2026-10-30-invoice-new-item-from-line" class="cl-entry">
<h3>2026-10-30 — Draft invoice line can create a new item</h3>
<p class="doc-body"><strong>What.</strong> Each draft invoice line has a “New item from this line” button. It creates an inventory item from that line’s description and unit cost, links it to the invoice supplier, and replaces the selected item. The previous item and stock are not changed.</p>
<p class="doc-body"><strong>Why.</strong> The edit page only offered existing items. The popup did not use the invoice line, so a wrong co-op match could not be replaced from the draft.</p>
<p class="doc-body"><strong>Files.</strong> <code>root/Inventory/invoice/edit.tt</code>, <code>Controller/Inventory.pm</code></p>
</div>
