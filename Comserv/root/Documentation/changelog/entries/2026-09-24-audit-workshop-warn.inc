<div id="2026-09-24-audit-workshop-warn" class="cl-entry">
<h3>2026-09-24 — Missing workshop ID is warn, not ERROR</h3>
<p class="doc-body"><strong>What.</strong> Crawler probes to <code>/workshop/details?id=...</code> logged ERROR and flooded Application Error Audit (#2428, #1600). Missing rows with no exception now log at warn; real <code>find()</code> exceptions stay ERROR.</p>
<p class="doc-body"><strong>Why.</strong> 404-equivalent lookups are not application faults.</p>
<p class="doc-body"><strong>Files.</strong> <code>Comserv/lib/Comserv/Controller/WorkShop.pm</code></p>
</div>
