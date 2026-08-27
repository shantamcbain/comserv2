<div id="2026-08-27-scrub-db-config-backup-passwords" class="cl-entry">
<h3>2026-08-27 — Scrub live DB passwords out of tracked db_config backups</h3>
<p class="doc-body"><strong>What.</strong> Blanked every <code>password</code> field in the six tracked <code>Comserv/db_config.json.backup.*</code> templates (todo #2305). Live <code>db_config.json</code> is unchanged and remains gitignored. New timestamped dumps are gitignored so they cannot be re-added.</p>
<p class="doc-body"><strong>Why.</strong> Those backups still held the live production/forager password. Gitleaks default rules and the Aikido pre-commit hook (the only hook that actually runs under <code>core.hooksPath</code>) did not catch a generic JSON password already in history.</p>
<p class="doc-body"><strong>Files.</strong> <code>Comserv/db_config.json.backup.*</code>, <code>Comserv/.gitignore</code>.</p>
</div>
