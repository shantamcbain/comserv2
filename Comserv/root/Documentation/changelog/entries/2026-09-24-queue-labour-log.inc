<div id="2026-09-24-queue-labour-log" class="cl-entry">
<h3>2026-09-24 — Log labour on the print queue</h3>
<p class="doc-body"><strong>What.</strong> Added admin POST <code>/3d/labour/log</code> (thin <code>Controller::Printing3dLabour</code>) and a compact form on <code>/3d/queue</code> active + completed rows. Minutes + category (clean/pick/pack/qc/other) call existing <code>Traveler-&gt;record_clean_labour</code> against the model’s inventory item, then stamp <code>admin_notes</code> on the job. Did not grow <code>Controller::3d</code>.</p>
<p class="doc-body"><strong>Why.</strong> Todo #2390 phase 2 — machine time was already on Complete; human clean/pick/pack/QC was missing from the queue.</p>
<p class="doc-body"><strong>Files.</strong> <code>lib/Comserv/Controller/Printing3dLabour.pm</code>, <code>root/3d/_labour_log_form.tt</code>, <code>root/3d/queue.tt</code>, <code>lib/Comserv/Util/Manufacturing/Traveler.pm</code></p>
</div>
