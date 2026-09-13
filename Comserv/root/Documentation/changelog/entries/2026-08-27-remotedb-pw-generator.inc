<div id="2026-08-27-remotedb-pw-generator" class="cl-entry">
<h3>2026-08-27 — Generate + reveal password on Change DB password</h3>
<p class="doc-body"><strong>What.</strong> The change_password form now has a "Generate new password" button (configurable 12–64 chars, crypto-strong, no ambiguous chars) and a "Show passwords" checkbox so the value can be read/copied before submit.</p>
<p class="doc-body"><strong>Why.</strong> User needs to read the generated password to paste elsewhere; the old field hid it.</p>
<p class="doc-body"><strong>Files.</strong> <code>root/static/js/remotedb-pw.js</code> (new), <code>root/js_load.tt</code> (loads it on <code>/remotedb/</code>), <code>root/remotedb/change_password.tt</code>.</p>
</div>
