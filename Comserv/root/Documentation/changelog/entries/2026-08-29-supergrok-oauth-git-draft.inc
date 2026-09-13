<div id="2026-08-29-supergrok-oauth-git-draft" class="cl-entry">
<h3>2026-08-29 — SuperGrok OAuth: stop stale secrets shadowing Hermes; clean Git draft errors</h3>
<p class="doc-body"><strong>What.</strong> Git dashboard "Suggest commit message" no longer dies on a stale <code>~/.comserv/secrets/supergrok_oauth</code> when Hermes <code>xai-oauth</code> is valid. Prepaid key resolve order is runtime secrets → env → Hermes auth.json → host secrets → DB. OAuth 403s return a short re-auth message instead of raw JSON. Ran <code>script/sync_supergrok_token.pl</code> to refresh the secrets file.</p>
<p class="doc-body"><strong>Why.</strong> Todo #2355 — UI error <code>403 unauthenticated:bad-credentials</code> while Hermes token still validated.</p>
<p class="doc-body"><strong>Files.</strong> <code>lib/Comserv/Model/AI2/Provider/Grok.pm</code>, <code>lib/Comserv/Controller/Admin/Git.pm</code>, <code>script/sync_supergrok_token.pl</code> (ops)</p>
</div>
