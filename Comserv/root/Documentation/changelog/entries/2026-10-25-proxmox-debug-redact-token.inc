<div id="2026-10-25-proxmox-debug-redact-token" class="cl-entry">
<h3>2026-10-25 — Proxmox debug no longer prints the API token</h3>
<p class="doc-body"><strong>What.</strong> The VM dashboard debug block now shows whether the token is set, not the token itself.</p>
<p class="doc-body"><strong>Why.</strong> The page was rendering the stored token in the debug JSON.</p>
<p class="doc-body"><strong>Files.</strong> <code>lib/Comserv/Controller/Proxmox.pm</code></p>
</div>
