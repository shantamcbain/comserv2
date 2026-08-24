<div id="2026-08-23-deploy-pull-only-image-css" class="cl-entry">
<h3>2026-08-23 — Production deploy is now pull-only; CSS lives in the image</h3>
<div class="container">
    <div class="row">
        <div class="col-100">
            <p class="doc-body"><strong>What broke.</strong> A bare <code>docker compose up -d</code> on production1 (192.168.1.126) started FOUR web containers from the same image (<code>comserv2-web-prod</code>, <code>comserv2-web</code>, <code>comserv-web-dev</code>, <code>comserv-web-staging</code>). The generic <code>web</code> service grabbed port 5000, so the real prod container crash-looped 974 times with no network and could not bind. Healthchecks had no timeout, so ~9,000 hung curl processes drove load to 190 on a 2-core box.</p>

            <p class="doc-body"><strong>Changes (uncommitted in working tree).</strong></p>
            <ul>
                <li><code>docker-compose.prod.yml</code>: web / web-dev / web-staging are gated behind a <code>workstation-only</code> compose profile — a bare <code>up -d</code> on the merged files can never start them on production again.</li>
                <li><code>script/deploy.sh</code> — canonical_deploy split by role:
                    <ul>
                        <li><em>Workstation only:</em> build + push (refuses to build if it detects it is running ON a production host).</li>
                        <li><em>Production only:</em> rename live container &rarr; <code>bk-&lt;name&gt;-&lt;ts&gt;</code>, <code>docker pull</code>, stop backup, <code>docker run</code> the pulled image (NO compose, NO host source tree, NO /opt/comserv/Comserv cd), health-gate, then on failure restart the backup and notify admin via POST /api/todo/create with mail fallback.</li>
                    </ul>
                </li>
                <li>New mode flags: <code>--pull-deploy</code> (pull+run on target only), <code>--build-push</code> (workstation build+push, running container not started). Later the same day: <code>--local-rebuild</code> for workstation Rebuild (no push, no prod).</li>
                <li>CSS: all static assets come from the image. Only two override volumes (<code>comserv2_theme_css</code>, <code>comserv2_theme_config</code>) overlay mutable subdirs, and they are seeded from the image when empty so they can never shadow baked CSS. No host bind over <code>/root/static</code>.</li>
            </ul>

            <p class="doc-body"><strong>Recurring failure classes this closes:</strong> extra workstation containers landing on prod; port-5000 theft between sibling services; CSS wiped by an empty host bind; "Pull &amp; Deploy" secretly rebuilding; prod building from a source tree that does not exist there.</p>
        </div>
    </div>
</div>
</div>
