<div id="2026-10-27-proxmox-card-edit-passcode" class="cl-entry">
<h3>2026-10-27 — Server card opens that host's dashboard; passcode stays in the database</h3>
<p class="doc-body"><strong>What.</strong> Clicking a Proxmox server card opens that server's own dashboard (its web UI). Edit opens the form for the card fields plus the passcode. The passcode is saved encrypted in <code>app_secrets</code> and is not written to the credentials file.</p>
<p class="doc-body"><strong>Why.</strong> The card was opening this app's guest tree. Edit also rejected a server that had an API URL but no stored host.</p>
<p class="doc-body"><strong>Files.</strong> <code>root/proxmox/index.tt</code>, <code>root/proxmox/edit_server.tt</code>, <code>lib/Comserv/Controller/ProxmoxServers.pm</code>, <code>lib/Comserv/Util/ProxmoxCredentials.pm</code></p>
</div>
