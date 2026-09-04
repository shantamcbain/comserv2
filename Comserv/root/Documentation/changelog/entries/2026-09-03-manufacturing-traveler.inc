<div id="2026-09-03-manufacturing-traveler" class="cl-entry">
<h3>2026-09-03 — Manufacturing traveler (print farm pick/print form) + STL download kink</h3>
<p class="doc-body"><strong>What.</strong> Shipped the Accounting manufacturing traveler for print-farm staff: customer/open-order index, tablet traveler with full BOM explode, colour print sheet, queue-from-traveler, pick-box receive, clean labour timer, and file download/integrity on traveler + <code>/3d/queue</code>.</p>
<p class="doc-body"><strong>Why.</strong> Staff needed an accurate pick/print picture for customer and in-house orders (HDRY INT-HDRY-001 = item 51 as the first full-system test). Mis-mapped STLs will keep happening — finished and queued rows must expose the linked file for visual check before reprint.</p>
<p class="doc-body"><strong>UI / behaviour.</strong></p>
<ul class="doc-body">
<li><strong>Routes:</strong> <code>/Accounting/manufacturing</code>, <code>…/view/&lt;order_id&gt;</code>, <code>…/view/item/51</code>, <code>…/print/…</code> (standalone <code>no_wrapper</code> colour sheet + Print Traveler).</li>
<li><strong>Row colours:</strong> green = in pick box; blue = printed not boxed; red = in print queue; purple = need print not queued (+ Add to Print Queue); amber = buy hardware.</li>
<li><strong>APIs:</strong> <code>POST /Inventory/api/stock/receive_qty</code>, <code>…/print_queue/add</code>, <code>…/labour/clean</code>, <code>…/item/update</code>.</li>
<li><strong>Clean labour:</strong> per-part timer → AppTime duration → add <code>unit_cost</code> + PointSystem credit (default $60/hr). Queue job total_cost roll-up still #2390.</li>
<li><strong>File column:</strong> download by <code>model_id</code>; smart match (<code>Traveler-&gt;_stl_matches_part_code</code>) — rollers/gaskets/L1 *03 OK; true cross-code (SBR03→SBR01.stl) hard-blocks queue.</li>
</ul>
<p class="doc-body"><strong>HDRY / SBR data (same day).</strong> Created INT-HDRY-SBR01 + correct STL; <strong>kept SBR03 on BOM</strong> (user: do not remove) with <code>SBR03_Reinforcement_small.stl</code>; moved mis-attributed stock to SBR01; roller models → SRC01/SRL01/SRR01 named copies. Never delete a still-needed print line to “fix” a bad file — fix the link.</p>
<p class="doc-body"><strong>Files.</strong>
<code>Controller/Accounting/Manufacturing.pm</code>,
<code>Controller/Accounting.pm</code>,
<code>Util/Manufacturing/Traveler.pm</code>,
<code>Controller/Inventory.pm</code> (APIs),
<code>root/Accounting/Manufacturing/*.tt</code>,
<code>root/3d/queue.tt</code>,
<code>Documentation/3dPrintingPlan.tt</code> §6 traveler,
<code>Documentation/DryerProjectPlan.tt</code> Now block.</p>
<p class="doc-body"><strong>Tracking.</strong> Todo <strong>#2399</strong> (traveler — ready to stop after operator confirm). Labour remainder <strong>#2390</strong>. Project #272 DRYER-INT / #206 3DPRINT.</p>
</div>
