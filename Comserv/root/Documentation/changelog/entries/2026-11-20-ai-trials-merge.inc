<div id="2026-11-20-ai-trials-merge" class="cl-entry">
<h3>2026-11-20 — Trial state files no longer block merges</h3>
<p class="doc-body"><strong>What.</strong> <code>data/ai_trials/*.state.json</code> and <code>*.tasks.jsonl</code> are runtime snapshots. They stayed tracked, so every timestamp rewrite conflicted on merge. The junk pattern <code>*_state.json</code> did not match <code>particle_1.state.json</code>. The Git page now untracks that class instead of <code>git add -f</code>, and a merge whose only conflicts are those files drops them (disk copy kept) instead of stopping.</p>
<p class="doc-body"><strong>Why.</strong> Ignore rules do nothing while the file is tracked. Select-all commits were writing the live trial file back into git.</p>
<p class="doc-body"><strong>Files.</strong> <code>.commit-junk-patterns</code>, <code>Comserv/lib/Comserv/Util/Git.pm</code>, <code>Comserv/lib/Comserv/Controller/Admin/Git.pm</code>, <code>Comserv/root/Documentation/AISYSTEMPlan.tt</code></p>
</div>
