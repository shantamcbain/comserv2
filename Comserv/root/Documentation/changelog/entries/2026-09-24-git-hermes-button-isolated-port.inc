<div id="2026-09-24-git-hermes-button-isolated-port" class="cl-entry">
<h3>2026-09-24 — Git Hermes button starts per-branch dashboard</h3>
<p class="doc-body"><strong>What.</strong> The Develop Servers Hermes button never POSTed <code>branch_server_action</code> because the button had no <code>data-port</code> and JS bailed. It now starts an isolated dashboard in the worktree cwd on that branch's Hermes port (4001→9101, main stays 9119), copies the dashboard command, and polls <code>/tmp/hermes-dash-*.log</code>.</p>
<p class="doc-body"><strong>Why.</strong> Clicking Hermes opened the right URL with nothing listening, copied <code>hermes chat</code>, and left 9119 as the only dashboard — sessions leaked into InventoryAccounting.</p>
<p class="doc-body"><strong>Files.</strong> <code>root/admin/git/index.tt</code>, <code>root/static/js/git-dashboard.js</code>, <code>lib/Comserv/Util/Git.pm</code>, <code>lib/Comserv/Util/BranchServerControl.pm</code>, <code>lib/Comserv/Controller/Admin.pm</code></p>
</div>
