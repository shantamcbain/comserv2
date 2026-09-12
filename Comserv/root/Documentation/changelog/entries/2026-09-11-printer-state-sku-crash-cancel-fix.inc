<div id="2026-09-11-printer-state-sku-crash-cancel-fix" class="cl-entry">
<h3>2026-09-11 — Fixed crash on queue load after cancelling print jobs</h3>
<p class="doc-body"><strong>What.</strong> $pr->sku was called directly on Printing3dPrinter rows (which have no sku column — sku lives on the linked inventory_item). This blew up the state JSON writing eval in the queue controller, causing "Queue load error" every time a job was cancelled (page reload triggered the write for LAN printers).</p>
<p class="doc-body"><strong>Why.</strong> Extended state writing to all printers exposed the unsafe accessor. Cancelling jobs reloads the queue view.</p>
<p class="doc-body"><strong>Files.</strong> <code>Comserv/lib/Comserv/Controller/3d.pm</code> (two places in queue sub state writing)</p>
</div>