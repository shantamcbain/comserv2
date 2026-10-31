<div id="2026-10-30-commit-review-reason" class="cl-entry">
<h3>2026-10-30 — Commit review block shows the finding</h3>
<p class="doc-body"><strong>What.</strong> The Git dashboard commit block now prints the reviewer's sentence, not only the file and line.</p>
<p class="doc-body"><strong>Why.</strong> The reviewer stores the text in <code>reason</code>. The dashboard looked only at <code>issue</code>, <code>message</code>, and <code>text</code>, so every block looked like a bare file:line list.</p>
<p class="doc-body"><strong>Files.</strong> <code>lib/Comserv/Util/AI/CodeReviewer.pm</code>, <code>t/ai_paid_block_and_gates.t</code></p>
</div>
