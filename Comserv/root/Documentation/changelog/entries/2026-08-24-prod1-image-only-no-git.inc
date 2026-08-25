<div id="2026-08-24-prod1-image-only-no-git" class="cl-entry">
<h3>2026-08-24 — Production1 is image-only: no git, no build, no workstation containers</h3>
<p class="doc-body">Rule (user, non-negotiable): there is <strong>no application source on production1 that may be used</strong>.
Workstation builds and pushes. Production only pulls/runs <code>comserv2-web-prod</code>.
Git pull on .126 is what kept overwriting compose/deploy and putting <code>web</code> / <code>web-dev</code> / <code>web-staging</code> back.</p>
<ul>
    <li><code>deploy.sh</code> on a production host: skips all <code>git fetch/pull</code>; refuses <code>sync_host_app_lib</code> (no host <code>lib/</code> into the container); emergency path recreates from the image, never host Starman.</li>
    <li>Host: origin remote removed from <code>/opt/comserv/Comserv</code>. Build scripts moved to <code>/opt/comserv/REMOVED-DO-NOT-RUN/</code> (<code>deploy-to-node.sh</code>, <code>deploy-to-production1.sh</code>, <code>comserv-docker-start.sh</code>, extra <code>deploy.sh</code>).</li>
    <li>Monitor still purges workstation siblings every 10 min and never compose-ups them.</li>
    <li>web-prod recreated with <code>-p 5000:5000</code> after siblings had left it with empty ports. Only web-prod + redis + config-db should run.</li>
</ul>
</div>
