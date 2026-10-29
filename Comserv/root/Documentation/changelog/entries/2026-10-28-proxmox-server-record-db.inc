<div id="2026-10-28-proxmox-server-record-db" class="cl-entry">
<h3>2026-10-28 — Proxmox server record comes from the database</h3>
<p class="doc-body"><strong>What.</strong> The dashboard no longer requires <code>config/proxmox_credentials.json</code>. The non-secret server record is stored in <code>app_secrets</code> as <code>proxmox_server:&lt;id&gt;</code>. The API token stays in <code>proxmox_token:&lt;id&gt;</code>. A missing local file is ignored.</p>
<p class="doc-body"><strong>Why.</strong> Port 4000 is the Docker test container. That image does not contain the gitignored credentials file, so <code>check_connection</code> stopped with “No valid API URL” before it read the token that was already in the database.</p>
<p class="doc-body"><strong>Files.</strong> <code>lib/Comserv/Util/ProxmoxCredentials.pm</code></p>
</div>
