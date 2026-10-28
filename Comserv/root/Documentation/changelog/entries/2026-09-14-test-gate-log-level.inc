<div id="2026-09-14-test-gate-log-level" class="cl-entry">
<h3>2026-09-14 — Downgrade test-gate dirty-checkout log level to 'warn'</h3>
<p class="doc-body"><strong>What.</strong> Changed the <code>run_test_gate</code> dirty-checkout guard in <code>Comserv/Util/Git.pm</code> from logging at <code>'error'</code> to <code>'warn'</code>.</p>
<p class="doc-body"><strong>Why.</strong> A merge gate run against a checkout with uncommitted changes is a precondition block (user needs to clean and retry), not an application error. At <code>'error'</code> it triggered the auto-error-audit pipeline, creating a spurious TODO every time a user tried to merge a branch whose worktree had uncommitted WIP. Consistent with the same downgrade already applied in <code>merge_branch</code> (lines 1839–1847).</p>
<p class="doc-body"><strong>Files.</strong> <code>Comserv/lib/Comserv/Util/Git.pm</code> (line 1931: <code>'error'</code> → <code>'warn'</code>)</p>
</div>
