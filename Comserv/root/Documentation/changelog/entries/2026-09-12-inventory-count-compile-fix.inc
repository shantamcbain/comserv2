<div id="2026-09-12-inventory-count-compile-fix" class="cl-entry">
<h3>2026-09-12 — Fix: /Inventory/count 404 (controller compile error)</h3>
<p class="doc-body"><strong>What.</strong> The Inventory controller had a syntax error — a missing <code>}</code> closing the stock_level hashref inside <code>_count_persist</code> (the <code>create({ ... )</code> should have been <code>create({ ... })</code>). This broke the entire controller, so every Inventory route (including the new /Inventory/count) returned 404. Also fixed a bare <code>$self-&gt;_now</code> method call lacking parentheses in the same block.</p>
<p class="doc-body"><strong>Why.</strong> User reported "The page you requested could not be found: /Inventory/count." Root cause was the whole controller failing to compile, not a missing route. Fixed and verified <code>perl -c</code> clean; all Inventory modules load.</p>
<p class="doc-body"><strong>Files.</strong> <code>Controller/Inventory.pm</code> (close the create hashref with <code>});</code>; <code>$self-&gt;_now()</code>).</p>
</div>
