<div id="2026-10-27-proxmox-app-dashboard-link" class="cl-entry">
<h3>2026-10-27 — Server card opens this app's dashboard, not :8006</h3>
<p class="doc-body"><strong>What.</strong> Clicking a Proxmox server card stays in this application and opens that server's dashboard: the host and each guest, with activity graphs. It does not open the Proxmox web UI.</p>
<p class="doc-body"><strong>Why.</strong> The card was sending the admin to :8006. That is not this application's dashboard for the server.</p>
<p class="doc-body"><strong>Files.</strong> <code>root/proxmox/index.tt</code>, <code>root/static/js/proxmox/fleet-graphs.js</code>, <code>root/proxmox/edit_server.tt</code></p>
</div>
