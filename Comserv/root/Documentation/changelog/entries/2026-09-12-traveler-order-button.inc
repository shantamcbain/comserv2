<div id="2026-09-12-traveler-order-button" class="cl-entry">
<h3>2026-09-12 — Add Order button to traveler need_buy parts</h3>
<p class="doc-body"><strong>What.</strong> The manufacturing traveler's buy parts (row_state=need_buy) previously only had a dead-end "🛒 Order" link to the item view. Replaced with a real <strong>Order</strong> button that POSTs to a new <code>/Inventory/po/order_item</code> endpoint, which resolves the item's preferred supplier and creates a draft purchase order immediately (qty = reorder_quantity or 1), then redirects to the PO. If no supplier is linked, it sends the user to the item edit page to add one.</p>
<p class="doc-body"><strong>Why.</strong> Buy parts in a traveler are a real need triggered by a sale/BOM; staff need a one-click path to order, same as "Add to Print Queue" for print parts. The link was a manual detour.</p>
<p class="doc-body"><strong>Files.</strong> <code>Controller/Inventory.pm</code> (new <code>po_order_item</code> action), <code>root/Accounting/Manufacturing/traveler_view.tt</code> (Order button + <code>.btn-order</code> style).</p>
</div>
