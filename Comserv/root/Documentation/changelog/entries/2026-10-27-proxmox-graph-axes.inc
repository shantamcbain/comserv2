<div id="2026-10-27-proxmox-graph-axes" class="cl-entry">
<h3>2026-10-27 — Proxmox summary charts show axes, scale, and server colors</h3>
<p class="doc-body"><strong>What.</strong> Each Summary chart on <code>/proxmox</code> uses the page width. The left axis is the value and its scale. The bottom axis is the time for the selected Hour/Day/Week/Month/Year window. The color key under the chart names the signed-in server for each line.</p>
<p class="doc-body"><strong>Why.</strong> A line drawn at about 1% of a 0–100 scale sat on the axis and looked like no graph. The chart is now scaled to the data so the history is visible, and the number under the chart is still the real reading.</p>
<p class="doc-body"><strong>Files.</strong> <code>root/static/js/proxmox/fleet-graphs.js</code>, <code>root/static/css/components/proxmox-dashboard.css</code>, <code>root/proxmox/index.tt</code>, <code>root/js_load.tt</code></p>
</div>
