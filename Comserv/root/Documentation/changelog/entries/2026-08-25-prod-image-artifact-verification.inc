<div id="2026-08-25-prod-image-artifact-verification" class="cl-entry">
<h3>2026-08-25 — Production image build/push/pull now verifies one exact artifact</h3>
<p class="doc-body"><strong>Root cause:</strong> the workstation built a fresh local <code>shantamcsbain/comserv-web-prod:latest</code> (image ID <code>be5d…</code>), but Docker Hub still served manifest <code>1784…</code> / config image <code>5d0b…</code> from 2026-08-23. Production correctly pulled that registry image, so Pull &amp; Deploy could report success while installing yesterday’s code. The production compose build also omitted <code>target: production</code>, causing Docker to tag the Dockerfile’s final <code>development</code> stage as the production image; <code>version.json</code> was not regenerated and still showed 2026-08-16.</p>
<ul>
  <li><code>docker-compose.prod.yml</code>: <code>web-prod.build.target: production</code>.</li>
  <li><code>deploy.sh</code>: regenerates <code>version.json</code> before build, pushes the exact <code>$IMAGE</code>, and compares Docker Hub’s manifest config digest to the local image ID. A mismatch is now a hard failure, never “Pushed”.</li>
  <li>Pull &amp; Deploy resolves the registry config digest first and verifies production1’s pulled image ID before stopping the backup or starting the new container.</li>
  <li>Production Starman default increased from 4 to 8 workers; <code>--max-requests 1000</code> recycles workers.</li>
  <li><code>AI2::Router::get_available_models</code> no longer probes or advertises workstation Ollama on production1. That catalog call ran during ordinary page rendering and pinned each worker for ~29 seconds under crawler traffic.</li>
  <li>Production <code>/data/nfs</code> now uses a Docker-managed NFS volume backed by <code>192.168.1.175:/mnt/data</code>, portable to every node. The existing physical <code>comserv2_nfs_data</code> on production1 had been created incorrectly as an empty local ext4 volume (Docker volume options are immutable), so the migration volume is <code>comserv2_nfs_data_nfs</code>. Pull &amp; Deploy verifies its NFS options and proves an STL is visible before replacing production.</li>
  <li><code>/3d/model_download</code> now resolves files through <code>Comserv::Util::NfsPath</code> and logs a real error if the shared NFS tree does not contain the stored path.</li>
</ul>
</div>
