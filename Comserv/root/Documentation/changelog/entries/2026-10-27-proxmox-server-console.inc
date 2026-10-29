<div id="2026-10-27-proxmox-server-console" class="cl-entry">
<h3>2026-10-27 — server_id opens the in-app server console</h3>
<p class="doc-body"><strong>What.</strong> <code>/proxmox?server_id=...</code> is the server console: guest tree on the left, summary on the right. The card list stays on <code>/proxmox</code> only.</p>
<p class="doc-body"><strong>Why.</strong> The card link was correct, but that URL still rendered the fleet page, so it looked like the same screen.</p>
<p class="doc-body"><strong>Files.</strong> <code>root/proxmox/index.tt</code>, <code>root/proxmox/_tree.tt</code></p>
</div>
