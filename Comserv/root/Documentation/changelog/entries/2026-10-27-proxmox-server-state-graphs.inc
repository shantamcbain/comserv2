<div id="2026-10-27-proxmox-server-state-graphs" class="cl-entry">
<h3>2026-10-27 — Proxmox page graphs every tracked server stat</h3>
<p class="doc-body"><strong>What.</strong> The Proxmox page signs in to every configured server and graphs each numeric stat Proxmox records for that host: CPU, IO wait, load, memory, swap, root disk, and network. A host with no passcode is shown as not signed in. CPU temperature is graphed when the host reports it.</p>
<p class="doc-body"><strong>Why.</strong> Four hand-picked series did not show the state Proxmox actually tracks.</p>
<p class="doc-body"><strong>Files.</strong> <code>lib/Comserv/Model/Proxmox.pm</code>, <code>root/static/js/proxmox/fleet-graphs.js</code>, <code>root/proxmox/index.tt</code></p>
</div>
