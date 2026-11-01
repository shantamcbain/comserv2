<div id="2026-10-31-shared-worktrees-registry" class="cl-entry">
<h3>2026-10-31 — Shared worktree registry</h3>
<p class="doc-body"><strong>What.</strong> Repaired the canonical worktree registry by removing committed merge markers, preserving the registered development-server metadata, and making every linked branch checkout resolve <code>root/config/worktrees.json</code> through the primary main checkout.</p>
<p class="doc-body"><strong>Why.</strong> Invalid JSON caused the Git dashboard registry loader to fall back to an empty branch map, so only the hardcoded main server appeared. Independent per-branch copies also allowed the registry to drift and conflict.</p>
<p class="doc-body"><strong>Files.</strong> <code>Comserv/root/config/worktrees.json</code>; linked worktree paths under <code>~/.comserv/worktrees/*/Comserv/Comserv/root/config/worktrees.json</code>; backups of replaced copies are under <code>/home/shanta/.hermes/cache/scratch/worktrees-json-before-main-symlink/</code>.</p>
</div>
