<div id="2026-08-30-merge-failure-diagnostics" class="cl-entry">
<h3>2026-08-30 — Git merge failures report why (main dirty / worktree)</h3>
<p class="doc-body"><strong>What.</strong> Dashboard merge into main no longer shows a bare
<code>Merge of 'branch' failed</code>. Failures classify reason (uncommitted on main,
conflict, worktree collision, missing ref, merge in progress), list dirty/conflict
files, include a browser <code>fix_hint</code> (e.g. open :3001 and commit on main),
and log full detail via <code>log_with_details</code> (<code>git_merge</code>).</p>
<p class="doc-body"><strong>Why.</strong> Git merge errors go to stderr; the util only
read stdout, so the UI lost the real message. Main WIP and worktree checkout
collisions are user-fixable and need explicit guidance.</p>
<p class="doc-body"><strong>Files.</strong>
<code>Comserv/lib/Comserv/Util/Git.pm</code>,
<code>Comserv/lib/Comserv/Controller/Admin/Git.pm</code>,
<code>Comserv/root/static/js/git-dashboard.js</code></p>
</div>
