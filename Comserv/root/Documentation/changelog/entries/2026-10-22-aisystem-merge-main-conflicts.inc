<div id="2026-10-22-aisystem-merge-main-conflicts" class="cl-entry">
<h3>2026-10-22 — aisystem merge of main: four conflicts resolved</h3>
<p class="doc-body"><strong>What.</strong> Merging main into aisystem stopped on the price cache, the git dashboard commit path, AI2 chat auto-enrich, and the worktree registry. Main also arrived with conflict markers already committed in <code>.gitignore</code>.</p>
<p class="doc-body"><strong>Why.</strong> Secret guard and the reviewer gate both run before a dashboard commit. Auto-enrich keeps the ticked-search fallback and still skips the editor. The registry keeps main's extra branches. The OpenRouter price file stays on disk but leaves git (both sides already ignore it). Encryption keys use one pattern, <code>*_encryption_key</code>, which also matches dotfiles.</p>
<p class="doc-body"><strong>Files.</strong> <code>Comserv/lib/Comserv/Controller/Admin/Git.pm</code>, <code>Comserv/lib/Comserv/Model/AI2/Chat.pm</code>, <code>Comserv/root/config/worktrees.json</code>, <code>Comserv/data/ai_openrouter_prices.json</code>, <code>.gitignore</code></p>
</div>
