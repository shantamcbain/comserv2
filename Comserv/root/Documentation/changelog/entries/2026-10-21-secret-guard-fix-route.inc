<div id="2026-10-21-secret-guard-fix-route" class="cl-entry">
<h3>2026-10-21 — Secret guard refusal names the file and offers a fix route</h3>
<p class="doc-body"><strong>What.</strong> A secret-guard block on commit or merge now lists the flagged path and line, an AI-editor link, and a copyable prompt. Key files are not opened in the editor. The prompt states that the env holds only the primary DB key; other keys belong in the database.</p>
<p class="doc-body"><strong>Why.</strong> The guard refused the commit with a warning and no path to the file, so a key that landed in git could not be fixed from the block.</p>
<p class="doc-body"><strong>Files.</strong> <code>Comserv/lib/Comserv/Util/GitGuardReport.pm</code>, <code>Comserv/lib/Comserv/Util/Git.pm</code>, <code>Comserv/lib/Comserv/Controller/Admin/Git.pm</code>, <code>Comserv/script/git/secret_guard.sh</code>, <code>Comserv/root/admin/git/index.tt</code>, <code>Comserv/root/static/js/git-dashboard.js</code>, <code>Comserv/root/static/js/ai2editor/chat.js</code></p>
</div>
