<div id="2026-10-27-proxmox-summary-cards" class="cl-entry">
<h3>2026-10-27 — Proxmox summary cards, one line per server</h3>
<p class="doc-body"><strong>What.</strong> The all-servers Summary is a snapshot card per host: CPU as a percent of the core count, memory and storage as used of total, uptime, load, IO delay, and swap. No time graph on that page. Hour, day, and week history, including guest bursts, is on the server page.</p>
<p class="doc-body"><strong>Why.</strong> Datacenter summary on :8006 is a snapshot, not a time graph. Burst history belongs on the server page.</p>
<p class="doc-body"><strong>Files.</strong> <code>root/proxmox/index.tt</code>, <code>root/static/js/proxmox/fleet-graphs.js</code>, <code>root/static/css/components/proxmox-dashboard.css</code></p>
</div>
