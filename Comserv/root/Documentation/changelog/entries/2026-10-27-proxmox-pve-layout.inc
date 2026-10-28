<div id="2026-10-27-proxmox-pve-layout" class="cl-entry">
<h3>2026-10-27 — Proxmox dashboard uses the :8006 tree layout</h3>
<p class="doc-body"><strong>What.</strong> The Proxmox dashboard is a left guest tree, toolbar, and Summary / Hardware / Backup tabs, with a bottom log strip. The power popup no longer throws when the progress call returns HTML.</p>
<p class="doc-body"><strong>Why.</strong> The old page was a button table. :8006 is a tree plus a content pane. The popup's JSON.parse error was that call returning the HTML page, because the running :4016 process does not have the new progress action yet.</p>
<p class="doc-body"><strong>Files.</strong> <code>root/proxmox/index.tt</code>, <code>root/proxmox/vm_detail.tt</code>, <code>root/proxmox/_tree.tt</code>, <code>root/static/css/components/proxmox-dashboard.css</code>, <code>root/static/js/proxmox/vm-power.js</code></p>
</div>
