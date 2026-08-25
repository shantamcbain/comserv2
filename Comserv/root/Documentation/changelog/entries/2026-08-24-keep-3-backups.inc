<div id="2026-08-24-keep-3-backups" class="cl-entry">
<h3>2026-08-24 — Keep only 3 Docker backups</h3>
<p class="doc-body"><code>deploy.sh</code> numbered rotation is now backup-1..3 (was 1..5). Monitor and every rename-to-backup path prune dated <code>bk-*</code> containers and images down to 3 newest. <code>DockerDeploy._prune_backups</code> default is 3. <code>Model::Docker::create_dated_backup</code> also drops older than 3.</p>
</div>
