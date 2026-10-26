<div id="2026-10-25-proxmox-server-list-links" class="cl-entry">
<h3>2026-10-25 — Proxmox server list Test and Manage VMs go somewhere</h3>
<p class="doc-body"><strong>What.</strong> Manage VMs no longer 404s on <code>/proxmox/<server_id></code>. That path now opens the VM page for that server. Test Connection follows the test-result page when the Bootstrap modal is not available, instead of staying on <code>#</code>.</p>
<p class="doc-body"><strong>Why.</strong> The list linked to a route that did not exist, and the test button cancelled navigation before any result was shown.</p>
<p class="doc-body"><strong>Files.</strong> <code>lib/Comserv/Controller/Proxmox.pm</code>, <code>root/proxmox/servers.tt</code>, <code>lib/Comserv/Util/ProxmoxCredentials.pm</code></p>
</div>
