<div id="2026-10-27-proxmox-server-cards" class="cl-entry">
<h3>2026-10-27 — Proxmox index shows a card per managed server</h3>
<p class="doc-body"><strong>What.</strong> <code>/proxmox</code> lists each configured Proxmox server as a status card: name, id, host, node, web UI, API user, and whether a token is stored. The server being managed is marked. The token value is not shown.</p>
<p class="doc-body"><strong>Why.</strong> The old pill switcher did not say which host an admin was about to change. The cards use the same status-panel shape as the :8006 summary, with theme variables only.</p>
<p class="doc-body"><strong>Files.</strong> <code>root/proxmox/index.tt</code>, <code>root/static/css/components/proxmox-dashboard.css</code></p>
</div>
