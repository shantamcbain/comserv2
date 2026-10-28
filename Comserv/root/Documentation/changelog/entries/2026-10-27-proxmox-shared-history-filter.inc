<div id="2026-10-27-proxmox-shared-history-filter" class="cl-entry">
<h3>2026-10-27 — Shared Proxmox history filter</h3>
<p class="doc-body"><strong>What.</strong> Server history and VM status share one timeframe filter: hour, day, week, month, and year. Each resource graph follows that filter.</p>
<p class="doc-body"><strong>Why.</strong> Proxmox stores node and guest usage history. The filter should not be copied per page.</p>
<p class="doc-body"><strong>Files.</strong> <code>root/static/js/proxmox/history-filter.js</code>, <code>root/static/js/proxmox/vm-history.js</code>, <code>root/static/js/proxmox/fleet-graphs.js</code>, <code>root/proxmox/index.tt</code>, <code>root/proxmox/vm_detail.tt</code></p>
</div>
