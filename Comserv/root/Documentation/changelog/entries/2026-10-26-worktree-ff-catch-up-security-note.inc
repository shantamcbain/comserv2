<div id="2026-10-26-worktree-ff-catch-up-security-note" class="cl-entry">
<h3>2026-10-26 — Security Note for Worktree Fast-Forward Catch-Up</h3>
<p class="doc-body"><strong>What.</strong> The worktree catch-up feature must never interfere with the password security system or expose credentials that would need to be fixed again. The fast-forward operation only moves branch pointers and does not create commits, preserving security boundaries.</p>
<p class="doc-body"><strong>Why.</strong> Automatic fast-forward operations could potentially bypass security checks if not properly implemented. The implementation ensures that only clean worktrees with no local commits are updated, and any worktree with ongoing merges or uncommitted changes is skipped.</p>
<p class="doc-body"><strong>Files.</strong> <code>lib/Comserv/Util/Git.pm</code> (<code>catch_up_registered_worktrees</code>), <code>lib/Comserv/Controller/Admin/Git.pm</code>.</p>
</div>