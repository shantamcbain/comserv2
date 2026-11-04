<div id="2026-11-01-git-merge-state-preflight" class="cl-entry">
<h3>2026-11-01 — Git merge-state preflight and idempotent abort</h3>
<p class="doc-body"><strong>What.</strong> Centralized the main-to-worktree merge path through <code>Comserv::Util::Git::merge_branch</code>, added structural checks for an active <code>MERGE_HEAD</code> or unmerged index entries, preserved merge stderr, classified autostash conflicts, and made Merge Abort a safe no-op when no merge is active.</p>
<p class="doc-body"><strong>Why.</strong> The Git audit was receiving generic <code>exit=2 out=</code>, unresolved-merge, and false Merge Abort errors because separate callers invoked Git without the same preflight and treated version-dependent no-op exits as failures. Expected repository preconditions now return actionable warnings instead of error-audit todos.</p>
<p class="doc-body"><strong>Files.</strong> <code>Comserv/lib/Comserv/Util/Git.pm</code>, <code>Comserv/lib/Comserv/Controller/Admin/Git.pm</code>, <code>Comserv/root/Documentation/system/git_worktree_merge_plan.tt</code>.</p>
</div>
