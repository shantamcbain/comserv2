<div id="2026-10-27-proxmox-pool-graphs" class="cl-entry">
<h3>2026-10-27 — Pool graphs, one line per server</h3>
<p class="doc-body"><strong>What.</strong> The all-servers Summary is one graph per node metric. Each signed-in server is a line. Hour, day, week, month, and year use the same filter as VM status.</p>
<p class="doc-body"><strong>Why.</strong> Comparing the pool means the lines share a graph, not a snapshot card per host.</p>
<p class="doc-body"><strong>Files.</strong> <code>root/proxmox/index.tt</code>, <code>root/static/js/proxmox/fleet-graphs.js</code>, <code>lib/Comserv/Model/Proxmox.pm</code>, <code>lib/Comserv/Controller/Proxmox.pm</code></p>
</div>
