<div id="2026-08-24-pull-deploy-name-clash" class="cl-entry">
<h3>2026-08-24 — Pull &amp; Deploy name-clash during long pull</h3>
<p class="doc-body">Pull finished, then <code>docker run --name comserv2-web-prod</code> failed: name already in use. Cause: the SSH snippet only shipped <code>start_prod_container_from_image</code>, so <code>purge_workstation_web_siblings</code> was missing; and the 10-min monitor recreated <code>comserv2-web-prod</code> while the pull was still downloading. Fix: ship the helper functions with the start snippet; move a leftover name to <code>failed-*-nameclash-*</code> before <code>docker run</code>; write <code>/tmp/comserv-deploy.lock</code> for the duration of Pull &amp; Deploy so the monitor does not recreate mid-pull.</p>
</div>
