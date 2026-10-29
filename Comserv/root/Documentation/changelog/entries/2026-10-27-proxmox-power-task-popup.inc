<div id="2026-10-27-proxmox-power-task-popup" class="cl-entry">
<h3>2026-10-27 — Proxmox power popup shows the task, not just the accept</h3>
<p class="doc-body"><strong>What.</strong> Reboot/start/shutdown on the Proxmox dashboard opens a popup that polls the Proxmox task log, VM status, and pending versus live memory. A Task log button opens the last power task without sending a new action.</p>
<p class="doc-body"><strong>Why.</strong> The old alert said the reboot was started as soon as Proxmox accepted the UPID. VM 110's qmreboot then failed: guest agent guest-ping timed out, so pending 32 GB never replaced the running 4 GB QEMU allocation. The GUI showed a reboot that had failed.</p>
<p class="doc-body"><strong>Files.</strong> <code>lib/Comserv/Model/Proxmox.pm</code>, <code>lib/Comserv/Controller/Proxmox.pm</code>, <code>root/static/js/proxmox/vm-power.js</code>, <code>root/js_load.tt</code>, <code>root/proxmox/index.tt</code>, <code>root/proxmox/vm_detail.tt</code></p>
</div>
