<div id="2026-08-24-prod1-no-workstation-siblings" class="cl-entry">
<h3>2026-08-24 — Stop workstation web/dev/staging from coming back on production1</h3>
<p class="doc-body">The live site on .126 was being served by <code>comserv2-web</code> (port 5000), not <code>comserv2-web-prod</code>. The extras (<code>comserv2-web</code>, <code>comserv-web-dev</code>, <code>comserv-web-staging</code>) share the prod image and are recreated by a bare <code>docker compose up -d</code> on the merged compose files. Removing them by hand never stuck: the next compose/monitor/git-sync brought them back, and the production1 Docker page has no Delete on a <em>running</em> container.</p>
<p class="doc-body"><strong>Prevention (not another one-off delete):</strong></p>
<ul>
    <li><code>deploy.sh</code> <code>purge_workstation_web_siblings</code> runs on production hosts only (every monitor tick + before starting web-prod). Stops/rms those three names, never redis/config-db/web-prod, then restarts web-prod so it can bind :5000.</li>
    <li>Overlay profiles <code>workstation-only</code> remain the first gate; the purge is the backstop when a <code>git pull</code> of main still lacks the overlay, or someone compose-ups the project.</li>
    <li>Docker page: running siblings show <strong>Remove from prod</strong>. Server refuses delete of web-prod/redis/config-db. Remote delete uses <code>docker rm -f</code>.</li>
</ul>
<p class="doc-body">An image rebuild alone does not fix this. The host monitor must run the new <code>deploy.sh</code>.</p>
</div>
