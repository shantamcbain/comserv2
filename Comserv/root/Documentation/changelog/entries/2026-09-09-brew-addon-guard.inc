<div id="2026-09-09-brew-addon-guard" class="cl-entry">
<h3>2026-09-09 — Guard brew addon for sites that actually have it enabled</h3>
<p class="doc-body"><strong>What.</strong> Added check in Root.pm to verify the target site has 'brew' module enabled in SiteModule table before showing brew menu and seed links.</p>
<p class="doc-body"><strong>Why.</strong> The 3d site was showing 'Re-run Brew Seed' and brew menu even though it doesn't have the brew addon enabled. This happened because the original code only checked if hosting account had requested_addons, but not if the site actually had the brew module enabled in the SiteModule table.</p>
<p class="doc-body"><strong>Files.</strong> <code>lib/Comserv/Controller/Root.pm</code></p>
</div>
