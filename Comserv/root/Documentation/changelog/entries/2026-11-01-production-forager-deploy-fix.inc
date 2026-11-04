<div id="2026-11-01-production-forager-deploy-fix" class="cl-entry">
<h3>2026-11-01 — Production Forager deploy configuration</h3>
<p class="doc-body"><strong>What.</strong> The production image-start path now derives the <code>production_forager</code> connection from the verified <code>production_server</code> connection, preserving credentials and the <code>192.168.1.20:3307</code> endpoint while selecting the <code>shanta_forager</code> database.</p>
<p class="doc-body"><strong>Why.</strong> Pull-deploy reused stale host-side secret files whose Forager entry pointed at the retired <code>192.168.1.198:3306</code> candidate. The new production readiness check correctly refused to start when that candidate failed, although the primary ENCY connection remained healthy.</p>
<p class="doc-body"><strong>Files.</strong> <code>Comserv/script/deploy.sh</code>; <code>.hermes/plans/2026-11-01-production-forager-deploy-fix.md</code>.</p>
</div>
