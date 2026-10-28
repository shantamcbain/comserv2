<div id="2026-10-22-untrack-reviewer-runtime" class="cl-entry">
<h3>2026-10-22 — stop tracking reviewer runtime JSON</h3>
<p class="doc-body"><strong>What.</strong> The commit gate, review scores, and reviewer spend files are no longer tracked. Copies stay on disk.</p>
<p class="doc-body"><strong>Why.</strong> They are rewritten on every review, so they kept showing up as commit noise. The app treats a missing file as empty. Tests write their own temp spend file.</p>
<p class="doc-body"><strong>Files.</strong> <code>.gitignore</code>, <code>Comserv/data/ai_commit_gate.json</code>, <code>Comserv/data/ai_review_scores.json</code>, <code>Comserv/data/ai_reviewer_spend.json</code></p>
</div>
