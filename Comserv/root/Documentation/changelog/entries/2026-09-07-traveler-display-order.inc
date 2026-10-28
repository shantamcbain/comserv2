<div id="2026-09-07-traveler-display-order" class="cl-entry">
<h3>2026-09-07 — Manufacturing traveler display order fix</h3>

<p class="doc-body"><strong>What.</strong> Fixed the manufacturing traveler part display priority order on both the tablet live view and print sheets. Parts now appear in the requested visual order.</p>

<p class="doc-body"><strong>Why.</strong> The previous state priority logic in <code>Traveler.pm</code> evaluated conditions in an order that did not match the user-specified visual requirement: parts needing pickup first, then queue status, then stock. The states needed to render as: need_print (purple) → in_queue (red) → in_box (green).</p>

<p class="doc-body"><strong>Files.</strong> <code>Comserv/lib/Comserv/Util/Manufacturing/Traveler.pm</code> — modified the <code>_parts_from_leaves</code> state-assignment block (lines 511–549) to enforce the correct priority: <br>
1. <code>need_print</code> (purple) — shortfall, nothing queued yet <br>
2. <code>in_queue</code> (red) — already on print farm queue <br>
3. <code>in_box</code> (green) — in pick box / in stock</p>

<p class="doc-body">Template files <code>root/CSC/HelpDesk/traveler_view.tt</code> and <code>root/Accounting/Manufacturing/traveler_view.tt</code> and <code>traveler_print.tt</code> automatically reflect the new state colors since they map <code>row_state</code> CSS classes to visual colors.</p>
</div>