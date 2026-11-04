<div id="2026-10-29-branch-dashboard-startup" class="cl-entry">
<h3>2026-10-29 — Reliable branch dashboard startup</h3>
<p class="doc-body"><strong>What.</strong> Branch and isolated Hermes dashboard launch actions now wait for the target port to accept connections before opening the dashboard page.</p>
<p class="doc-body"><strong>Why.</strong> The previous flow opened the browser before the background server was ready and treated process spawn as success, producing intermittent connection failures and duplicate starts.</p>
<p class="doc-body"><strong>Files.</strong> <code>lib/Comserv/Util/BranchServerControl.pm</code>, <code>root/static/js/git-dashboard.js</code>, <code>root/static/js/planning/daily-plan-utils.js</code></p>
</div>
