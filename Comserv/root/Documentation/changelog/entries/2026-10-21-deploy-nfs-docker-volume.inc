<div id="2026-10-21-deploy-nfs-docker-volume" class="cl-entry">
<h3>2026-10-21 — Deploy monitor no longer fails a false NFS miss</h3>
<p class="doc-body"><strong>What.</strong> Production monitor ticks exited 1 with “NFS is not mounted” even though <code>192.168.1.175:/mnt/data</code> was mounted as the Docker volume <code>comserv2_nfs_data_nfs</code>. That exit happened before self-heal, so a bad container could not be recovered. <code>deploy.sh</code> now treats that Docker NFS mount as production NFS and recycles Starman workers stuck in R for more than 20 minutes.</p>
<p class="doc-body"><strong>Why.</strong> The check only looked for host binds (<code>/home/ubuntu/nfs</code> and friends). The live container’s NFS is the named volume, which the ubuntu user cannot <code>df</code>. Twelve spinning workers had load at ~13 while <code>/health</code> still returned 200.</p>
<p class="doc-body"><strong>Files.</strong> <code>Comserv/script/deploy.sh</code> (also the host copies on production1).</p>
</div>
