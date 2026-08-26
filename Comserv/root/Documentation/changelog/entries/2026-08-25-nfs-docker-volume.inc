<div id="2026-08-25-nfs-docker-volume" class="cl-entry">
<h3>2026-08-25 — Portable Docker NFS volume; print-queue STL downloads</h3>
<p class="doc-body"><strong>Symptom.</strong> Print-queue Download reported
<code>File not found on server: /data/nfs/hdry_parts/.../BBL01.stl</code>.
The file existed on the NFS export (3,166 STL files). Production1’s
<code>comserv2_nfs_data</code> had been created as a <em>local ext4</em> Docker
volume (options <code>null</code>), so the container’s <code>/data/nfs</code>
was empty. Workstation Docker had the same empty local volume.</p>
<p class="doc-body"><strong>Architecture (portable, no host-path bind).</strong>
Shared files stay a Docker-managed NFS volume pointed at
<code>192.168.1.175:/mnt/data</code> (nfsvers=3). That works on any node.
Docker volume options are immutable, so the broken physical
<code>comserv2_nfs_data</code> is left unused. Live containers use
<code>comserv2_nfs_data_nfs</code>.</p>
<p class="doc-body"><strong>Deploy gate.</strong> <code>ensure_nfs_volume</code>
creates the NFS volume if missing, checks driver options, mounts it in a
throwaway container, and requires at least one <code>.stl</code> to be
visible before production is renamed. Pull &amp; Deploy no longer starts
web-prod on an empty local volume.</p>
<p class="doc-body"><strong>Download.</strong> <code>/3d/model_download</code>
resolves through <code>Comserv::Util::NfsPath</code> and logs when the shared
tree does not contain the stored path. Production1 and workstation Docker
were recreated onto <code>comserv2_nfs_data_nfs</code>. Host <code>:3001</code>
was not restarted.</p>
</div>
