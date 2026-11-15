<div id="2026-10-31-invoice-location-popup" class="cl-entry">
<h3>2026-10-31 — Invoice page can add a location in a popup</h3>
<p class="doc-body"><strong>What.</strong> New and edit supplier-invoice pages have an “Add New Location” button beside the item popup. It opens the location form in a window. When that window closes, the line location lists refresh. A new location is selected on a line that had none.</p>
<p class="doc-body"><strong>Why.</strong> The invoice page could add an item without leaving the page, but not a location. Stock could not be named unless it already existed.</p>
<p class="doc-body"><strong>Files.</strong> <code>Controller/Inventory.pm</code>, <code>root/Inventory/locations/add.tt</code>, <code>root/Inventory/invoice/edit.tt</code>, <code>root/Inventory/invoice/new.tt</code></p>
</div>
