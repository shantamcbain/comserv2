<div id="2026-11-01-commit-gate-data-entry" class="cl-entry">
<h3>2026-11-01 — Commit gate skips data-entry churn</h3>
<p class="doc-body"><strong>What.</strong> The Git dashboard commit gate no longer holds the first commit for low reviewer notes on trial state files the app rewrites (<code>data/ai_trials/*.state.json</code> and <code>*.tasks.jsonl</code>). Those files are checked locally and are not sent to the reviewer.</p>
<p class="doc-body"><strong>Why.</strong> A spend or timestamp update was treated as a review finding, so every commit of that file asked for a second click. Conflict markers, invalid JSON, the secret guard, and any finding on another file still stop the commit.</p>
<p class="doc-body"><strong>Files.</strong> <code>Comserv/lib/Comserv/Util/Git.pm</code>, <code>Comserv/lib/Comserv/Controller/Admin/Git.pm</code>, <code>Comserv/t/util_git_data_entry_commit.t</code>.</p>
</div>
