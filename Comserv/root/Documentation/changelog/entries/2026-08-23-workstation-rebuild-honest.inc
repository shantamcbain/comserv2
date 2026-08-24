<div id="2026-08-23-workstation-rebuild-honest" class="cl-entry">
<h3>2026-08-23 — Workstation Rebuild is local-only; logs and the volume list tell the truth</h3>
<div class="container">
    <div class="row">
        <div class="col-100">
            <p class="doc-body"><strong>What broke.</strong> After the morning pull-only hardening, the workstation Rebuild button still called <code>deploy.sh --deploy-to-node workstation</code> over an SSH hop to itself. It built and pushed, then failed or recreated only the local container, then printed <code>Multi-node deploy complete</code>. Production1 was not pulled (image date stayed 2026-08-15). The UI showed no stream because output was captured with backticks and the poller ignored docker <code>\\r</code> progress. Status polls returned NetworkError when :3001's worker died. The Volumes panel listed ~20 names because it suffix-matched old <code>comserv_comserv2_*</code> copies.</p>

            <p class="doc-body"><strong>What the buttons do now.</strong></p>
            <ul>
                <li>Rebuild, target workstation → <code>deploy.sh --local-rebuild</code>: local build + replace local <code>comserv2-web-prod</code>. No push. No production1. Log says Production was NOT updated.</li>
                <li>Build &amp; Push → image only. Does not start or replace a container.</li>
                <li>Pull &amp; Deploy / Rebuild with target Production 1 → the only paths that update .126.</li>
            </ul>

            <p class="doc-body"><strong>Streaming.</strong> The child runs under <code>script -q -f -a -e</code> into <code>/tmp/comserv_deploy.log</code>. Builds use <code>BUILDKIT_PROGRESS=plain</code>. The Docker page paints the whole log every 1.5s. Hard-refresh the page so that JS loads.</p>

            <p class="doc-body"><strong>Health.</strong> <code>Root.pm</code> skips <code>auto</code>/<code>begin</code> on <code>^/?health</code> (Catalyst path has no leading slash). Compose <code>start_period</code> is 60s again (the morning commit had dropped it to 10s).</p>

            <p class="doc-body"><strong>Volumes.</strong> Live set is the 12 <code>comserv2_*</code> names (cache, config_db, cpan, logs, nfs_data, redis, sessions, temp, theme_config, theme_css, themes, whisper_venv). Prefixed leftovers removed on workstation and production1. The panel lists exact names only. Stopped staging/web-dev were removed so their duplicate volumes could go; starting them again will create fresh volumes.</p>

            <p class="doc-body">Authoritative procedure: <a href="&#91;% c.uri_for('/Documentation/DEPLOY_WORKFLOW') %&#93;">/Documentation/DEPLOY_WORKFLOW</a>.</p>
        </div>
    </div>
</div>
</div>
