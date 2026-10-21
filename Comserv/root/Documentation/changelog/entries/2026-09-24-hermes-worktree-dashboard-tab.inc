<div id="2026-09-24-hermes-worktree-dashboard-tab" class="cl-entry">
<h3>2026-09-24 — Git Hermes button opens branch dashboard tab</h3>
<p class="doc-body"><strong>What.</strong> Develop Servers <strong>Hermes</strong> opens <code>/chat</code> in a new tab on the branch Hermes port (main <code>:9119</code>, worktree <code>:9100+(app%100)</code> e.g. InventoryAccounting <code>:9101</code>), then POSTs <code>action=hermes</code> which starts <code>hermes dashboard --isolated</code> from that worktree git root if the port is down. AI editor Detach uses the same port formula. CLI copy still happens; never <code>-w</code>.</p>
<p class="doc-body"><strong>Why.</strong> The iframe is too small; not every branch has AI-editor Detach. Copying <code>hermes chat</code> did not open a browser next to the app. Without <code>--isolated</code>, a second dashboard port is refused while :9119 is up.</p>
<p class="doc-body"><strong>Files.</strong> <code>Util/BranchServerControl.pm</code>, <code>Util/Git.pm</code>, <code>Controller/Admin.pm</code>, <code>admin/git/index.tt</code>, <code>static/js/git-dashboard.js</code>, <code>static/js/ai2editor/hermes-run.js</code></p>
</div>
