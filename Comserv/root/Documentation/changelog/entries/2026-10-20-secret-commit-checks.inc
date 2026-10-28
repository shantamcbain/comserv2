<div id="2026-10-20-secret-commit-checks" class="cl-entry">
<h3>2026-10-20 — Secret commit checks fail closed</h3>
<p class="doc-body"><strong>What.</strong> Commit, merge, and push scans now refuse a gitleaks crash instead of treating it as a pass. Gitleaks flags credential literals in Perl, conf, YAML, and <code>.env</code> files, and a DSN with an embedded password. The GitHub <code>secret-scan</code> job installs gitleaks into the runner temp dir and fails if the binary is missing. <code>.env.example</code> stays allow-listed; the tracked encryption keys are no longer allow-listed.</p>
<p class="doc-body"><strong>Why.</strong> Further commits must not add exposed credentials. The already-tracked <code>.env</code> files and encryption keys are a separate cleanup and are not untracked by this change.</p>
<p class="doc-body"><strong>Files.</strong> <code>.gitleaks.toml</code>, <code>.secret-guard-allow</code>, <code>Comserv/script/git/secret_guard.sh</code>, <code>.github/workflows/secret-scan.yml</code></p>
</div>
