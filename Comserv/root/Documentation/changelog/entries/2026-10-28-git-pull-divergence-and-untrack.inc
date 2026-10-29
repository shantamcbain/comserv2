<div id="2026-10-28-git-pull-divergence-and-untrack" class="cl-entry">
<h3>2026-10-28 — Git pull refusal was divergence, not damage</h3>
<p class="doc-body"><strong>What.</strong> <code>/admin/git_pull</code> on main exited 128. Local main was 29 commits ahead of <code>origin/main</code> and 11 behind. Git refused a bare pull because <code>pull.rebase</code> is unset. The page hid the hint (stderr). The remote tip was the git-dev line and had not deleted local work. Those histories were merged and pushed. SQLite sidecars and <code>ai_rank_jobs/git.json</code> were untracked. The pull command was not changed.</p>
<p class="doc-body"><strong>Why.</strong> A failed pull with an empty message looked like damage. It was two real histories plus a page that only prints stdout. Untracking the runtime files keeps the next push from carrying them at the tip.</p>
<p class="doc-body"><strong>Files.</strong> <code>.gitignore</code>, <code>Comserv/root/Documentation/system/git_worktree_merge_plan.tt</code>, <code>Comserv/root/Documentation/admin/git_pull_guide.tt</code>. Code still calls <code>git pull origin</code> with no strategy flag in <code>lib/Comserv/Util/Git.pm</code>.</p>
</div>
