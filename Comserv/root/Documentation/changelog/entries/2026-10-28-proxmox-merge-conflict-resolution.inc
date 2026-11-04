<div id="2026-10-28-proxmox-merge-conflict-resolution" class="cl-entry">
<h3>2026-10-28 — Proxmox merge conflict cleanup</h3>
<p class="doc-body"><strong>What.</strong> Completed the existing local-<code>main</code>-into-<code>Proxmox</code> merge at <code>4007f21c8</code> by resolving the nested autostash conflict in <code>Comserv/data/ai_trials/kimi_k27_code.state.json</code> and retaining the latest generated trial state.</p>
<p class="doc-body"><strong>Why.</strong> The merge commit already contained <code>main</code>, but reapplying the autostash left conflict markers in the generated state file and made the branch appear blocked. The applied autostash was removed after its two runtime-file changes were verified in the index.</p>
<p class="doc-body"><strong>Files.</strong> <code>Comserv/data/ai_trials/kimi_k27_code.state.json</code>, <code>Comserv/data/ai_rank_jobs/Proxmox.json</code>, <code>.hermes/docs-sync-state.json</code>.</p>
</div>
