<div id="2026-10-21-scanner-comment-self-block" class="cl-entry">
<h3>2026-10-21 — Credential scanner comments no longer trip their own rules</h3>
<p class="doc-body"><strong>What.</strong> The header comments in the credential-literal scanner no longer contain a quoted example of the mysql client flag or the DBI connect third argument.</p>
<p class="doc-body"><strong>Why.</strong> Those examples matched <code>mysql-cli-password-flag</code> and <code>dbi-connect-positional-password</code>. The quoted placeholder was seven characters with entropy just over 2.5, so gitleaks treated the scanner's own documentation as a password and blocked the commit. The detection code is unchanged.</p>
<p class="doc-body"><strong>Files.</strong> <code>Comserv/script/git/scan_credential_literals.pl</code></p>
</div>
