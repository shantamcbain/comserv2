<div id="2026-10-29-healthkitchen-worktree-project-id" class="cl-entry">
<h3>2026-10-29 — HealthKitchen sort could not find its project</h3>
<p class="doc-body"><strong>What.</strong> <code>branches.healthkitchen</code> in <code>root/config/worktrees.json</code> now has <code>project_id</code> 296 (HEALTHKITCHEN). The decision-rank script reads only that field. Without it, Resort died with “cannot resolve a root project” before scoring.</p>
<p class="doc-body"><strong>Why.</strong> The Focus Queue sort on :4015 could not scope the branch. Sibling branches that sort (aisystem, 3d, schema) already carry <code>project_id</code>.</p>
<p class="doc-body"><strong>Files.</strong> <code>Comserv/root/config/worktrees.json</code>, <code>Comserv/root/Documentation/changelog/entries/2026-10-29-healthkitchen-worktree-project-id.inc</code></p>
</div>
