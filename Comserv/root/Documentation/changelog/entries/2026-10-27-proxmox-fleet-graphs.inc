<div id="2026-10-27-proxmox-fleet-graphs" class="cl-entry">
<h3>2026-10-27 — Proxmox fleet cards open a server, and activity is graphed</h3>
<p class="doc-body"><strong>What.</strong> A server card opens that server's dashboard. Each card has an Edit link, and the page has an Add server button. The panel under the cards is hour/day/week graphs of every server and every guest. A row is marked when CPU, memory, load, network, or disk spikes.</p>
<p class="doc-body"><strong>Why.</strong> The detail list did not show which host an admin was about to change, or whether a guest had just spiked.</p>
<p class="doc-body"><strong>Files.</strong> <code>root/proxmox/index.tt</code>, <code>root/static/js/proxmox/fleet-graphs.js</code>, <code>root/static/css/components/proxmox-dashboard.css</code>, <code>lib/Comserv/Controller/Proxmox.pm</code>, <code>lib/Comserv/Model/Proxmox.pm</code></p>
</div>
